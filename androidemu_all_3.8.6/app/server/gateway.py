#!/usr/bin/env python3
"""
androidemu 3.5.1 gateway service（飞牛统一网关入口）

对外与 2.x 的 gw_socket.sh + gw_relay.py 行为一致：为飞牛统一网关提供 Unix socket 入口，
免端口访问云手机画面；并用应用管理员账号做服务端会话，令「走网关打开」与「直连打开」完全一致。

3.0.3 相对 3.0.2 的修复（全部来自 2.0.88/2.1.1 在真机上逐项验证过的实现）：
  ① 服务端会话自动登录 + 注入 localStorage（auth_token/auth_user/auth_role/auth_devices）
     —— 3.0.2 缺失，会重现「0 台设备 / 未授权」「走网关要多登录一次」。
  ② 强制换页 302（页面请求不带 gwv= 时 302 到带版本号的同一地址），杜绝旧页面/旧 chunk 缓存。
  ③ WebSocket 握手注入服务端 token；被上游 401 时改用服务端会话重试一次（手机 APP 常见）。
  ④ 外网访问自动切 WebSocket 投屏 + 提示条（穿透/反代只有 443/TCP，WebRTC 的 TURN/UDP 过不去）。
  ⑤ 运行时前缀拦截器（fetch/XHR/WebSocket/setAttribute/MutationObserver）+ HTML/CSS 文本改写
     + 资源 ?v= 版本号，从机制上消除「绝对路径打到飞牛 www」导致的白屏。
  ⑥ 会话 401 自愈：上游拒绝服务端会话时清缓存重登并重试一次；前端侧兜底跳应用登录页。

3.0.3 相对 2.1.1 的结构改进：
  · 单进程 Python：不再有 bash 守护 + python 代理两个进程，杜绝「上一版守护每 20 秒杀掉新代理」
    那类 PID 互杀（ARM 实测过的真实故障）。
  · start/stop/supervise 全部内置：只按 PID 文件 + /proc/<pid>/cmdline 身份校验，不 pkill；
    并会清理本应用「上一版」遗留的守护/代理（含 2.x 的 gw_socket.sh/gw_relay.py），
    但绝不触碰同机上本应用的另一个隔离实例。
  · VAR_DIR 被删除或替换（卸载/重装）时守护自动退出，不与新实例抢 socket。
  · 依赖只有 python3 标准库，不需要 curl/socat/pkill。

3.0.4 相对 3.0.3 的修复（均为 ARM 真机实测暴露的问题）：
  · our_pids 只匹配"常驻角色"（serve/supervise，以及 2.x 的 gw_socket.sh supervise 与
    gw_relay.py），不再把刚调用它的 `gateway.py start` 这类一次性 CLI 一起杀掉
    （原先会打印 "Terminated"，让安装/启动回调误判失败）。
  · 身份校验同时接受真实路径与飞牛兼容软链路径（/var/apps/<名>/target）：实测从薄壳
    gw_socket.sh 启动时 TRIM_APPDEST 为空，实例跑在软链路径下；只比对一种写法会让
    status 误报"代理 not running"，更严重的是 stop 会漏杀子进程、留下孤儿进程。
  · 守护顺带看住音频守护：容器重建或音频守护异常退出后自动补起（最多每 60 秒尝试一次）。

用法：gateway.py {serve|start|stop|restart|status|supervise|probe}
  serve      前台运行代理（内部使用；由 supervise 拉起）
  start      确保守护+代理在跑（已健康则不重启，避免掐断在线会话）
  stop       停止守护+代理并清理 socket
  restart    stop + start
  status     打印守护/代理/socket/版本/上游
  supervise  守护循环（内部使用）
  probe      通过 socket 探活一次
"""
import os
import re
import ssl
import sys
import json
import time
import socket
import signal
import threading
import subprocess

VERSION = "3.8.3"

APP_DEST = os.environ.get("TRIM_APPDEST", "/var/apps/androidemu/target")
VAR_DIR = os.environ.get("TRIM_PKGVAR", "/var/apps/androidemu/var")
SOCK_PATH = os.path.join(APP_DEST, "app.sock")
PREFIX = "/app/androidemu"
PB = PREFIX.encode()
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = 8443
USE_TLS = True
INTERVAL = int(os.environ.get("GW_CHECK_INTERVAL", "20") or 20)
try:
    WS_PING = int(os.environ.get("GW_WS_PING", "10") or 10)
except Exception:
    WS_PING = 10

PID_FILE = os.path.join(VAR_DIR, "gateway.pid")         # 守护进程
CHILD_PID = os.path.join(VAR_DIR, "gateway_child.pid")  # 代理进程
VER_FILE = os.path.join(VAR_DIR, "gateway.ver")
LOCK_FILE = os.path.join(VAR_DIR, "gateway.lock")
LOG_FILE = os.path.join(VAR_DIR, "gateway.log")
STATUS_FILE = os.path.join(VAR_DIR, "gw_status")
ADMIN_CONF = os.path.join(VAR_DIR, "gw_admin.conf")

SELF = os.path.abspath(__file__)

try:
    os.makedirs(VAR_DIR, exist_ok=True)
except Exception:
    pass


# ---------------------------------------------------------------- 基础工具

def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write("[%s] %s\n" % (time.strftime("%F %T"), msg))
    except Exception:
        pass


def gw_status(ok, msg):
    """网关状态落盘：面板/诊断据此显示自动登录结果（2.1.1 的 gw_status 等价物）。"""
    try:
        with open(STATUS_FILE, "w") as f:
            f.write("OK=%s\nMSG=%s\nTS=%d\n" % ("1" if ok else "0", msg, int(time.time())))
    except Exception:
        pass


def pid_cmdline(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            return f.read().replace(b"\0", b" ").decode("utf-8", "replace")
    except Exception:
        return ""


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def pid_uid(pid):
    try:
        return os.stat("/proc/%d" % pid).st_uid
    except Exception:
        return None


def is_mine(pid):
    return pid_uid(pid) == os.getuid()


def read_pid(path):
    try:
        with open(path) as f:
            pid = int(f.read().strip())
        return pid if pid_alive(pid) else None
    except Exception:
        return None



def kill_pid(pid, wait=1.5):
    if not pid:
        return True
    if not is_mine(pid):
        log("跳过非本用户进程 pid=%d（无权限结束）" % pid)
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except Exception:
        return True
    deadline = time.time() + wait
    while time.time() < deadline:
        if not pid_alive(pid):
            return True
        time.sleep(0.1)
    try:
        os.kill(pid, signal.SIGKILL)
    except Exception:
        pass
    return True


def self_prefixes():
    """本实例的"可接受路径写法"：真实路径 + 飞牛兼容软链路径（旧版可能从软链启动）。"""
    name = os.path.basename(APP_DEST.rstrip("/"))
    if name == "target":
        name = os.path.basename(os.path.dirname(APP_DEST.rstrip("/")))
    out = [APP_DEST, VAR_DIR, "/var/apps/%s/target" % name, "/var/apps/%s/var" % name]
    for p in (APP_DEST, VAR_DIR):
        try:
            rp = os.path.realpath(p)
            if rp and rp not in out:
                out.append(rp)
        except Exception:
            pass
    uniq = []
    for p in out:
        if p and p not in uniq:
            uniq.append(p)
    return uniq


SELF_PREFIXES = self_prefixes()


def our_pids():
    """列出本应用、本用户的"常驻"网关进程（含上一版遗留），不含自己。

    只匹配常驻角色：3.0.x 的 `gateway.py serve|supervise`、2.x 的 `gw_socket.sh supervise`
    与 `gw_relay.py`。**不匹配 start/stop/status/probe 这类一次性 CLI 调用** —— 实测教训：
    若按"命令行含 server/gateway.py"匹配，守护会把刚调用它的 `gateway.py start` 进程
    一并杀掉，表现为打印 "Terminated"、回调误判失败。
    """
    out = []
    me = os.getpid()
    try:
        entries = os.listdir("/proc")
    except Exception:
        return out
    for e in entries:
        if not e.isdigit():
            continue
        pid = int(e)
        if pid == me:
            continue
        cmd = pid_cmdline(pid)
        if not cmd:
            continue
        if not any(p and p in cmd for p in SELF_PREFIXES):
            continue
        toks = cmd.split()
        role = False
        if "gw_relay.py" in cmd:
            role = True                       # 2.x 的代理本体（无子命令）
        elif toks and toks[-1] in ("serve", "supervise"):
            role = True                       # 显式子命令
        elif toks and toks[-1].endswith("gateway.py"):
            role = True                       # 无参数默认 serve 模式（易被漏匹配）                 # 3.0.x 的两种常驻角色
        elif "gw_socket.sh" in cmd and "supervise" in toks:
            role = True                       # 2.x 的 bash 守护
        if role and is_mine(pid):
            out.append(pid)
    return out


def gateway_cmd_ok(cmd):
    """命令行是否是本应用的网关程序。

    关键：必须同时接受**真实路径**与**飞牛兼容软链路径**（/var/apps/<名>/target）。
    实测教训：从薄壳 gw_socket.sh 启动时 TRIM_APPDEST 通常为空，实例会以软链路径运行；
    若只用一种写法比对，status 会误报"代理 not running"，stop 还会漏杀子进程（留下孤儿）。
    """
    if "server/gateway.py" not in cmd:
        return False
    return any(p and (p + "/server/gateway.py") in cmd for p in SELF_PREFIXES)


def role_pid(pidfile, role):
    """PID 文件 + 命令行身份（含路径形式与角色）校验；不匹配返回 None。"""
    pid = read_pid(pidfile)
    if not pid or not is_mine(pid):
        return None
    cmd = pid_cmdline(pid)
    if not gateway_cmd_ok(cmd):
        return None
    toks = cmd.split()
    return pid if toks and toks[-1] == role else None


def daemon_pid():
    return role_pid(PID_FILE, "supervise")



def sweep(keep=()):
    """结束本应用上一版/重复的网关进程；keep 中的 pid 保留。"""
    killed = []
    for pid in our_pids():
        if pid in keep:
            continue
        if kill_pid(pid):
            killed.append(pid)
    if killed:
        log("已清理本应用网关残留进程：%s" % " ".join(str(p) for p in killed))
    return killed


# ---------------------------------------------------------------- 上游参数

def load_conf():
    global UPSTREAM_PORT, USE_TLS
    try:
        with open(os.path.join(VAR_DIR, "ports.conf")) as f:
            m = re.search(r"^WEB_PORT=(\d+)", f.read(), re.M)
        if m:
            UPSTREAM_PORT = int(m.group(1))
    except Exception:
        pass
    try:
        with open(os.path.join(APP_DEST, "docker", "docker-compose.yaml"), "rb") as f:
            _dc = f.read()
            if b"USE_TLS=false" in _dc or b"USE_TLS:" in _dc and b"false" in _dc:
                USE_TLS = False
    except Exception:
        pass


def admin_creds():
    user = os.environ.get("GW_ADMIN_USER", "admin")
    pwd = os.environ.get("GW_ADMIN_PASS", "admin123")
    try:
        with open(ADMIN_CONF) as f:
            line = f.readline().strip()
        if ":" in line:
            u, _, p = line.partition(":")
            if u:
                user = u
            if p:
                pwd = p
    except Exception:
        pass
    return user, pwd


ADMIN_USER, ADMIN_PASS = admin_creds()


def open_upstream():
    raw = socket.create_connection((UPSTREAM_HOST, UPSTREAM_PORT), timeout=20)
    if not USE_TLS:
        return raw
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx.wrap_socket(raw, server_hostname="localhost")


def read_headers(f):
    out = []
    while True:
        line = f.readline()
        if not line or line in (b"\r\n", b"\n"):
            break
        out.append(line)
        if len(out) > 200:
            break
    return out


def hmap(headers):
    m = {}
    for h in headers:
        k, _, v = h.partition(b":")
        m[k.strip().lower()] = v.strip()
    return m


def strip_hop(headers):
    out = []
    for h in headers:
        k = h.split(b":")[0].strip().lower()
        if k in (b"connection", b"keep-alive", b"proxy-connection", b"transfer-encoding"):
            continue
        # 2.0.64：剥掉飞牛统一网关注入的身份头，避免上游据飞牛账号建立"普通用户"会话
        if k.startswith(b"x-trim-"):
            continue
        out.append(h)
    return out


def dechunk(f):
    out = bytearray()
    while True:
        line = f.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            n = int(line.split(b";")[0], 16)
        except Exception:
            break
        if n == 0:
            try:
                f.readline()
            except Exception:
                pass
            break
        out += f.read(n)
        f.read(2)
    return bytes(out)


def read_body(f, headers):
    if b"chunked" in headers.get(b"transfer-encoding", b"").lower():
        return dechunk(f)
    try:
        n = int(headers.get(b"content-length", b"0") or 0)
    except Exception:
        n = 0
    return f.read(n) if n > 0 else b""


def send_err(conn, code, text, extra=None):
    try:
        body = (text + "\n").encode("utf-8")
        resp = [b"HTTP/1.1 %d %s\r\n" % (code, text.encode("ascii", "replace")[:32]),
                b"Content-Type: text/plain; charset=utf-8\r\n",
                b"Content-Length: %d\r\n" % len(body),
                b"Connection: close\r\n\r\n"]
        if extra:
            resp[3:3] = extra
        conn.sendall(b"".join(resp) + body)
    except Exception:
        pass


# ---------------------------------------------------------------- 会话与注入

SESSION = {"js": b"", "ts": 0.0, "token": ""}

# 2.0.64：两类地址都要补前缀：A) 字符串常量绝对路径；B) location.host 拼出来的绝对地址。
# 2.0.80：不再对 javascript 做文本改写（新版前端是 ES module，盲目替换会破坏动态 import），
#         运行期由 RUNTIME_SHIM 劫持 fetch/XHR/WebSocket/setAttribute 自动补前缀。
STATIC_EXT = ('.js', '.mjs', '.css', '.map', '.json', '.woff', '.woff2', '.ttf', '.png', '.jpg', '.jpeg', '.gif', '.svg', '.ico', '.wasm')

_STR_PATHS = [b"/assets/", b"/api/", b"/connect_client", b"/ws/",
              b"/snapshot", b"/files/", b"/devices", b"/terminal"]

# 2.0.71：资源地址统一追加 ?v=应用版本（三种形式都要覆盖），配合 HTML no-store 杜绝旧 chunk 缓存。
ASSET_RE = re.compile(rb'(["\'])((?:/app/androidemu)?/?assets/[A-Za-z0-9_\.\-]+\.(?:js|css|woff2|woff|ttf|png|jpe?g|gif|svg|json|map))(?![?])')


_ROUTE_RE = re.compile(rb'href="/(?!/)(dashboard|files|terminal|admin|settings|devices|deploy|login|audit|share|monitor|logs)([^"]*)"')


def version_assets(body):
    try:
        return ASSET_RE.sub(lambda m: m.group(1) + m.group(2) + b"?v=" + VERSION.encode(), body)
    except Exception:
        return body


# 2.0.71：运行时前缀拦截（关键修复）。真机日志实证：仅靠文本改写覆盖不全，
# 运行期拼接的地址（/devices、/connect_client）与懒加载 chunk 仍会以无前缀绝对路径发出，
# 在飞牛网关上被飞牛自己的 www 接走（404/401），表现为「0 台设备 + 未授权」。
RUNTIME_SHIM = (
    b'(function(){try{'
    b'var PB="/app/androidemu";'
    b'if(location.pathname.indexOf(PB)!==0)return;'
    b'function fix(u){try{'
    b'if(typeof u!=="string"||!u)return u;'
    b'if(u.indexOf("//")===0)return u;'
    b'if(u.charAt(0)==="/"){if(u===PB||u.indexOf(PB+"/")===0)return u;return PB+u;}'
    b'var i=u.indexOf("://");'
    b'if(i>0){var rest=u.slice(i+3),j=rest.indexOf("/");var host=j<0?rest:rest.slice(0,j);'
    b'if(host!==location.host)return u;var pp=j<0?"/":rest.slice(j);'
    b'if(pp===PB||pp.indexOf(PB+"/")===0)return u;return u.slice(0,i+3)+host+PB+pp;}'
    b'return u;}catch(e){return u;}}'
    b'window.__gwFix=fix;'
    b'var _f=window.fetch;if(_f){window.fetch=function(input,init){try{'
    b'if(typeof input==="string"){input=fix(input);}'
    b'else if(input&&input.url){var nu=fix(input.url);if(nu!==input.url){input=new Request(nu,input);}}}catch(e){}'
    b'return _f.call(this,input,init);};}'
    b'try{var _o=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){try{arguments[1]=fix(u);}catch(e){}return _o.apply(this,arguments);};}catch(e){}'
    b'try{var _W=window.WebSocket;if(_W){var _gwReconDelay=1000;var _NW=function(url,proto){try{if(typeof url==="string"&&(url.indexOf("ws://")===0||url.indexOf("wss://")===0)){var _p=url.indexOf("://")+3;var _rest=url.slice(_p);var _sl=_rest.indexOf("/");var _path=_sl<0?"/":_rest.slice(_sl);url=_path;}url=fix(url);}catch(e){}'
    b'var _ws=proto===undefined?new _W(url):new _W(url,proto);var _url=url;var _proto=proto;var _self=this;var _closedByUser=false;var _heartbeat=null;var _reconTimer=null;'
    b'_ws.addEventListener("open",function(){_gwReconDelay=1000;try{if(_heartbeat)clearInterval(_heartbeat);_heartbeat=setInterval(function(){try{if(_ws.readyState===1)_ws.send("ping");}catch(e){}},25000);}catch(e){}});'
    b'_ws.addEventListener("close",function(ev){try{if(_heartbeat)clearInterval(_heartbeat);console.log("[gw] ws closed code="+(ev?ev.code:"?")+" recon="+(!_closedByUser));}catch(e){}'
    b'if(!_closedByUser&&_gwReconDelay<30000){_reconTimer=setTimeout(function(){try{var _nw=proto===undefined?new _W(_url):new _W(_url,_proto);for(var k in _ws){if(typeof _ws[k]!=="function")_nw[k]=_ws[k];}_ws=_nw;}catch(e){console.log("[gw] reconnect failed",e);}},_gwReconDelay);_gwReconDelay=Math.min(_gwReconDelay*2,30000);}});'
    b'var _origClose=_ws.close.bind(_ws);_ws.close=function(){_closedByUser=true;if(_reconTimer)clearTimeout(_reconTimer);if(_heartbeat)clearInterval(_heartbeat);_origClose();};'
    b'return _ws;};_NW.prototype=_W.prototype;'
    b'_NW.CONNECTING=_W.CONNECTING;_NW.OPEN=_W.OPEN;_NW.CLOSING=_W.CLOSING;_NW.CLOSED=_W.CLOSED;window.WebSocket=_NW;}}catch(e){}'
    b'try{var _sa=Element.prototype.setAttribute;Element.prototype.setAttribute=function(n,v){'
    b'try{if(typeof v==="string"){var ln=String(n).toLowerCase();if(ln==="src"||ln==="href"||ln==="data-src"){v=fix(v);}}}catch(e){}'
    b'return _sa.call(this,n,v);};}catch(e){}'
    b'function patchProp(proto,prop){try{var d=Object.getOwnPropertyDescriptor(proto,prop);if(!d||!d.set||!d.get)return;'
    b'Object.defineProperty(proto,prop,{configurable:true,enumerable:d.enumerable,'
    b'get:function(){return d.get.call(this);},set:function(v){return d.set.call(this,fix(v));}});}catch(e){}}'
    b'patchProp(HTMLScriptElement.prototype,"src");'
    b'patchProp(HTMLLinkElement.prototype,"href");'
    b'patchProp(HTMLImageElement.prototype,"src");'
    b'patchProp(HTMLIFrameElement.prototype,"src");'
    b'try{var mo=new MutationObserver(function(l){for(var i=0;i<l.length;i++){var ns=l[i].addedNodes||[];'
    b'for(var j=0;j<ns.length;j++){var el=ns[j];if(!el||!el.tagName)continue;var tg=el.tagName.toLowerCase();'
    b'if(tg==="script"||tg==="link"||tg==="iframe"||tg==="img"){try{'
    b'var s=el.getAttribute("src");if(s){var n1=fix(s);if(n1!==s)el.setAttribute("src",n1);}'
    b'var h=el.getAttribute("href");if(h&&h.charAt(0)==="/"){var n2=fix(h);if(n2!==h)el.setAttribute("href",n2);}}catch(e){}}}}});'
    b'mo.observe(document.documentElement||document,{childList:true,subtree:true});}catch(e){}'
    b'try{var all=document.querySelectorAll("script[src],link[href]");for(var k=0;k<all.length;k++){var el2=all[k];'
    b'var s2=el2.getAttribute("src");if(s2){var m1=fix(s2);if(m1!==s2)el2.setAttribute("src",m1);}'
    b'var h2=el2.getAttribute("href");if(h2&&h2.charAt(0)==="/"){var m2=fix(h2);if(m2!==h2)el2.setAttribute("href",m2);}}'
    b'}catch(e){}'
    b'try{window.print=function(){console.log("[gw] print blocked");};}catch(e){}'
    b''  # 3.7.3：移除音频强制禁用，允许用户开启音频
    b''  # 3.7.3：移除WebSocket音频拦截，允许用户开启音频
    # b'try{var _os=WebSocket.prototype.send;WebSocket.prototype.send=function(d){try{if(typeof d===\'string\'&&d.indexOf(\'scrcpy_options\')>=0){d=d.split(\'"audio":true\').join(\'"audio":false\');d=d.split(\'"audio": true\').join(\'"audio": false\');}}catch(e){}return _os.call(this,d);};}catch(e){}'
    b'try{var _gwStyle=document.createElement("style");_gwStyle.textContent='
    b'"@media(max-width:768px){body,html{overflow-x:auto!important;-webkit-overflow-scrolling:touch!important;}'
    b'div[style*=\'position:fixed\'][style*=\'bottom\'],div[class*=\'bottom-panel\'],div[class*=\'terminal-panel\'],div[class*=\'tool-panel\'],div[class*=\'drawer\']{max-width:100vw!important;overflow-x:auto!important;overflow-y:hidden!important;}'
    b'div[class*=\'window\'],div[class*=\'modal\'],div[class*=\'dialog\']{max-width:100vw!important;left:0!important;right:auto!important;}'
    b'button[class*=\'close\'],button[aria-label*=\'close\'],button[title*=\'\xe5\x85\xb3\xe9\x97\xad\']{position:sticky!important;left:0!important;z-index:9999!important;}'
    b'.web-fullscreen .share-header,.web-fullscreen .conn-meta,.web-fullscreen .top-bar,.web-fullscreen .header{display:none!important;}'
    b'.web-fullscreen .share-main,.web-fullscreen .main{height:100vh!important;margin:0!important;padding:0!important;}'
    b'.web-fullscreen .share-page-container,.web-fullscreen .page-container{background:#000!important;margin:0!important;padding:0!important;}'
    b'.web-fullscreen .share-aside,.web-fullscreen .share-sidebar,.web-fullscreen .side-control,.web-fullscreen .control-bar,.web-fullscreen .action-bar,.web-fullscreen .tool-bar,.web-fullscreen .right-panel,.web-fullscreen .left-panel,.web-fullscreen .panel{display:none!important;}'
    b'.web-fullscreen .video-container,.web-fullscreen .screen-container,.web-fullscreen .player-container,.web-fullscreen .video-wrap,.web-fullscreen .screen-wrap,.web-fullscreen .player-wrap,.web-fullscreen .display-container{width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;max-width:100vw!important;max-height:100vh!important;}'
    b'.web-fullscreen .share-content,.web-fullscreen .main-content,.web-fullscreen .content-wrap,.web-fullscreen .content{width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;}'
    b'.web-fullscreen{margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;}'
    b'@media(min-width:768px){.web-fullscreen video,.web-fullscreen canvas,.web-fullscreen img{object-fit:contain!important;width:100%!important;height:100%!important;max-width:100vw!important;max-height:100vh!important;}}'
    b'@media(max-width:767px){.web-fullscreen video,.web-fullscreen canvas,.web-fullscreen img{object-fit:cover!important;width:100vw!important;height:100vh!important;}}'
    b'.gw-fs-active ._gw_hidden{display:none!important;}'
    b'.gw-fs-active body{margin:0!important;padding:0!important;overflow:hidden!important;}'
    b'";'
    b'document.head.appendChild(_gwStyle);}catch(e){}'
    b'var _gwFsHidden=[];function _gwIsMediaEl(e){return e.tagName&&(e.tagName==="VIDEO"||e.tagName==="CANVAS"||e.tagName==="IMG");}'
    b'function _gwHasMediaDescendant(e){if(_gwIsMediaEl(e))return true;for(var i=0;i<e.children.length;i++){if(_gwHasMediaDescendant(e.children[i]))return true;}return false;}'
    b'function _gwEnterFs(){_gwFsHidden=[];var all=document.querySelectorAll("body *");for(var i=0;i<all.length;i++){var el=all[i];var cs=getComputedStyle(el);if((cs.position==="fixed"||cs.position==="sticky")&&!_gwHasMediaDescendant(el)){el.classList.add("_gw_hidden");_gwFsHidden.push(el);}}document.documentElement.classList.add("gw-fs-active");}'
    b'function _gwExitFs(){for(var i=0;i<_gwFsHidden.length;i++){_gwFsHidden[i].classList.remove("_gw_hidden");}_gwFsHidden=[];document.documentElement.classList.remove("gw-fs-active");}'
    b'document.addEventListener("fullscreenchange",function(){if(document.fullscreenElement){_gwEnterFs();}else{_gwExitFs();}});'
    b'document.addEventListener("webkitfullscreenchange",function(){if(document.webkitFullscreenElement){_gwEnterFs();}else{_gwExitFs();}});'
    b'}catch(e){}})();'
)

# 2.0.79：自动登录不可用时的兜底自愈 —— 收到 401 就清坏 token 并跳应用登录页，
# 让用户至少看到可用的登录页，而不是半残的「0 台设备 + 未授权」。
FALLBACK_HEAL_JS = (
    '(function(){try{if(location.pathname.indexOf("/app/androidemu")!==0)return;'
    'if(sessionStorage.getItem("gw_logout")==="1")return;'
    'if(sessionStorage.getItem("gw_heal")==="1")return;'
    'fetch("/app/androidemu/api/me",{headers:{Authorization:"Bearer "+(localStorage.getItem("auth_token")||"")},cache:"no-store"})'
    '.then(function(r){if(r&&r.status===401){sessionStorage.setItem("gw_heal","1");'
    'try{["auth_token","auth_user","auth_role","auth_devices"].forEach(function(k){localStorage.removeItem(k)})}catch(e){}'
    'location.replace("/app/androidemu/login?gwv="+(Date.now()));}}).catch(function(){});}catch(e){}})();')

# 前端 logout() 走的是绝对路径 /login，挂在网关上会跳到飞牛登录页 → 捕获阶段接管。
GW_LOGOUT_JS = (
    'document.addEventListener("click",function(ev){var el=ev.target;'
    'while(el&&el!==document){if(el.classList&&el.classList.contains("logout-nav-item")){'
    'ev.preventDefault();ev.stopPropagation();ev.stopImmediatePropagation();'
    'var t="";try{t=localStorage.getItem("auth_token")||""}catch(e){}'
    'var done=function(){try{["auth_token","auth_user","auth_role","auth_devices"].forEach(function(k){localStorage.removeItem(k)})}catch(e){}'
    'try{sessionStorage.setItem("gw_logout","1")}catch(e){}'
    'location.replace("/app/androidemu/login")};'
    'try{fetch("/app/androidemu/api/logout",{method:"POST",headers:{Authorization:"Bearer "+t}}).then(done,done)}catch(e){done()}'
    'return}el=el.parentNode}},true);')

# 3.6.7：外网访问三层防护 —— 增强按钮查找 + 强制WS模式 + MJPEG降级
# 穿云投屏版本更新后按钮文本可能变化，故增加属性/class匹配；
# 找不到按钮时尝试localStorage强制设置；仍失败则提供MJPEG降级链接。
EXTERNAL_HELPER_JS = (
    "(function(){try{"
    "if(location.pathname.indexOf('/app/androidemu')!==0)return;"
    "function findToggle(){"
    "  var all=document.getElementsByTagName('*');"
    "  for(var i=0;i<all.length;i++){"
    "    var el=all[i];"
    "    try{ if(el.children&&el.children.length>2) continue; }catch(e){}"
    "    var t=(el.textContent||'').trim();"
    "    if(!t||t.length>50) continue;"
    "    if(t.indexOf('改用 WebSocket')>=0||t.indexOf('WS 投屏')>=0||t.indexOf('WS投屏')>=0"
    "       ||t.indexOf('WebSocket 投屏')>=0||(t.indexOf('WebSocket')>=0&&t.indexOf('投屏')>=0)"
    "       ||t.indexOf('切换到WS')>=0||t.indexOf('切换到 WS')>=0) return el;"
    "  }"
    "  try{"
    "    var btns=document.querySelectorAll('button,[role=button],.btn,[class*=toggle],[class*=switch],[class*=mode],[data-mode],[class*=cast]');"
    "    for(var j=0;j<btns.length;j++){"
    "      var b=btns[j];"
    "      var bt=(b.textContent||'').trim();"
    "      var cls=(b.className||'').toString();"
    "      var aria=(b.getAttribute&&b.getAttribute('aria-label'))||'';"
    "      var data=(b.getAttribute&&b.getAttribute('data-mode'))||'';"
    "      if((bt&&(bt.indexOf('WebSocket')>=0||bt.indexOf('WS')>=0||bt.indexOf('投屏')>=0))"
    "         ||(cls&&(cls.toLowerCase().indexOf('websocket')>=0||cls.toLowerCase().indexOf('ws-')>=0))"
    "         ||(aria&&(aria.indexOf('WebSocket')>=0||aria.indexOf('WS')>=0))"
    "         ||(data&&(data.toLowerCase().indexOf('websocket')>=0||data.toLowerCase().indexOf('ws')>=0))) return b;"
    "    }"
    "  }catch(e){}"
    "  return null;"
    "}"
    "function forceWsMode(){"
    "  try{"
    "    var keys=['scrcpy_settings','default_settings','settings','cast_mode','stream_mode','transport_mode','player_settings'];"
    "    for(var i=0;i<keys.length;i++){"
    "      try{"
    "        var v=localStorage.getItem(keys[i]);"
    "        if(v){"
    "          var o=JSON.parse(v);"
    "          if(o&&typeof o==='object'){"
    "            o.mode='websocket';o.transport='websocket';o.useWs=true;o.wsCast=true;o.castMode='websocket';"
    "            localStorage.setItem(keys[i],JSON.stringify(o));"
    "          }"
    "        }"
    "      }catch(e){}"
    "    }"
    "    localStorage.setItem('gw_force_ws','1');"
    "  }catch(e){}"
    "}"
    "function showMjpegFallback(){"
    "  try{"
    "    var d=document.getElementById('__gw_ext_note');"
    "    if(!d){"
    "      d=document.createElement('div');d.id='__gw_ext_note';"
    "      d.setAttribute('style','position:fixed;right:12px;top:70px;z-index:2147483000;max-width:300px;background:rgba(15,23,42,.95);color:#e2e8f0;border:1px solid rgba(56,189,248,.55);border-radius:10px;padding:10px 12px;font:13px/1.7 system-ui,sans-serif;box-shadow:0 8px 22px rgba(0,0,0,.45)');"
    "      (document.body||document.documentElement).appendChild(d);"
    "    }"
    "    d.innerHTML='';"
    "    var h=document.createElement('div');h.textContent='外网访问';h.setAttribute('style','color:#38bdf8;font-weight:700');d.appendChild(h);"
    "    var b1=document.createElement('div');b1.textContent='WebSocket投屏正在连接，如长时间无画面请用降级查看。';d.appendChild(b1);"
    "    var a=document.createElement('a');a.href='/app/androidemu/stream.mjpg';a.target='_blank';a.textContent='-> 降级查看画面（MJPEG低帧率）';a.setAttribute('style','color:#38bdf8;display:block;margin-top:6px;text-decoration:underline;');d.appendChild(a);"
    "    var a2=document.createElement('a');a2.href='javascript:void(0)';a2.textContent='知道了';a2.setAttribute('style','color:#94a3b8;display:block;margin-top:4px;');"
    "    a2.onclick=function(){try{d.remove()}catch(e){}};d.appendChild(a2);"
    "  }catch(e){}"
    "}"
    "var clicked=false,tries=0;"
    "var iv=setInterval(function(){"
    "  if(clicked||++tries>40){clearInterval(iv);"
    "    if(!clicked){forceWsMode();showMjpegFallback();}"
    "    return;"
    "  }"
    "  var b=findToggle();"
    "  if(b){try{b.click();clicked=true;clearInterval(iv);"
    "    var n=document.getElementById('__gw_ext_note');"
    "    if(n){n.innerHTML='<div style=\'color:#38bdf8;font-weight:700\'>外网访问</div><div>已自动切到 WebSocket 投屏（画面走飞牛网关 443）。</div>';}"
    "  }catch(e){}}"
    "},1500);"
    "function mk(){try{"
    "  var d=document.createElement('div');d.id='__gw_ext_note';"
    "  d.setAttribute('style','position:fixed;right:12px;top:70px;z-index:2147483000;max-width:280px;background:rgba(15,23,42,.95);color:#e2e8f0;border:1px solid rgba(56,189,248,.55);border-radius:10px;padding:10px 12px;font:13px/1.7 system-ui,sans-serif;box-shadow:0 8px 22px rgba(0,0,0,.45)');"
    "  var h=document.createElement('div');h.textContent='外网访问';h.setAttribute('style','color:#38bdf8;font-weight:700');d.appendChild(h);"
    "  var b1=document.createElement('div');b1.textContent='正在自动适配外网访问...';d.appendChild(b1);"
    "  var b2=document.createElement('div');b2.textContent='局域网内访问可获得 60fps 流畅体验。';b2.setAttribute('style','color:#94a3b8');d.appendChild(b2);"
    "  (document.body||document.documentElement).appendChild(d);"
    "}catch(e){}}"
    "if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',mk);}else{mk();}"
    "}catch(e){}})();")


def is_external_host(host_b):
    """本次请求是否来自外网（非局域网/本机地址）。"""
    try:
        h = host_b.decode("latin1").strip().lower()
        if not h:
            return False
        if h.startswith("["):
            h = h[1:].split("]")[0]
        elif ":" in h:
            h = h.split(":")[0]
        if h in ("localhost", "127.0.0.1", "::1") or h.endswith(".local"):
            return False
        if h.startswith("10.") or h.startswith("192.168.") or h.startswith("127."):
            return False
        if h.startswith("172."):
            try:
                if 16 <= int(h.split(".")[1]) <= 31:
                    return False
            except Exception:
                pass
        return True
    except Exception:
        return False


def sub_token(path, tok):
    if "token=" in path:
        return re.sub(r"token=[^&]*", "token=" + tok, path, count=1)
    return path + ("&" if "?" in path else "?") + "token=" + tok


def _login_upstream():
    """用应用管理员账号向上游换取会话，返回注入页面用的 JS（bytes）。"""
    body = json.dumps({"username": ADMIN_USER, "password": ADMIN_PASS}).encode()
    u = open_upstream()
    try:
        u.settimeout(15)
        u.sendall(b"POST /api/login HTTP/1.1\r\nHost: localhost\r\n"
                  b"Content-Type: application/json\r\n"
                  b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
        f = u.makefile("rb")
        hs = read_headers(f)
        if not hs:
            return None
        try:
            code = int(hs[0].split()[1])
        except Exception:
            code = 0
        raw = f.read(int(hmap(hs).get(b"content-length", b"0") or 0))
    finally:
        try:
            u.close()
        except Exception:
            pass
    if code != 200:
        log("网关自动登录失败：上游返回 %d" % code)
        gw_status(False, "自动登录失败：上游 /api/login 返回 %d（若已修改画面服务密码，请在应用数据目录写入 gw_admin.conf，格式 用户名:密码，然后重开页面）" % code)
        return None
    try:
        d = json.loads(raw.decode("utf-8", "replace"))
    except Exception as e:
        log("自动登录响应解析失败：%r" % (e,))
        gw_status(False, "自动登录响应解析失败：%r" % (e,))
        return None
    tok = d.get("token") or ""
    if not tok:
        gw_status(False, "自动登录未取到 token（上游登录接口响应异常）")
        return None
    # 2.0.73：以服务端会话为准 + 401 自愈（前端收到一次 401 会清掉本地 token，
    # 之后所有请求都变成 13 字节 Unauthorized → 「0 台设备/未授权」）。
    js = ('(function(){try{if(location.pathname.indexOf("/app/androidemu")!==0)return;'
          'if(sessionStorage.getItem("gw_logout")==="1")return;'
          'var T=%s;'
          'if(localStorage.getItem("auth_token")!==T||localStorage.getItem("auth_role")!=="admin"){'
          'localStorage.setItem("auth_token",T);localStorage.setItem("auth_user",%s);'
          'localStorage.setItem("auth_role",%s);localStorage.setItem("auth_devices",%s);}'
          'if(!sessionStorage.getItem("gw_heal")){'
          'fetch("/app/androidemu/api/me",{headers:{Authorization:"Bearer "+(localStorage.getItem("auth_token")||"")},cache:"no-store"})'
          '.then(function(r){if(r&&r.status===401){sessionStorage.setItem("gw_heal","1");'
          'try{["auth_token","auth_user","auth_role","auth_devices"].forEach(function(k){localStorage.removeItem(k)})}catch(e){}'
          'location.reload();}}).catch(function(){});}'
          '}catch(e){}})();') % (json.dumps(tok), json.dumps(d.get("username") or ADMIN_USER),
                                 json.dumps(d.get("role") or "admin"),
                                 json.dumps(json.dumps(d.get("assigned_devices") or ["*"])))
    SESSION["token"] = tok
    gw_status(True, "自动登录成功（用户 %s）" % (d.get("username") or ADMIN_USER))
    log("网关自动登录成功：用户=%s 角色=%s" % (d.get("username"), d.get("role")))
    return js.encode()


def ensure_session():
    now = time.time()
    # 2.0.82：会话缓存 30 分钟（上游穿云会话通常 30~60 分钟过期，缓存过久会用旧 token 得 401）
    if not SESSION["js"] or (now - SESSION["ts"]) > 1800:
        try:
            new = _login_upstream()
        except Exception as e:
            log("网关自动登录异常：%r" % (e,))
            new = None
        if new:
            SESSION["js"] = new
            SESSION["ts"] = now
    return SESSION.get("token") or ""


NAV_FIX_JS = (
    "document.addEventListener('click',function(ev){try{"
    "var PB='/app/androidemu';var el=ev.target;"
    "while(el&&el.tagName!=='A')el=el.parentNode;"
    "if(!el||!el.getAttribute)return;"
    "var h=el.getAttribute('href')||'';"
    "if(h.charAt(0)!=='/'||h.indexOf('//')===0)return;"
    "if(h===PB||h.indexOf(PB+'/')===0)return;"
    "ev.preventDefault();history.pushState(null,'',PB+h);"
    "window.dispatchEvent(new PopStateEvent('popstate'));"
    "}catch(e){}},true);"
)

def helper_html(external=False):
    ensure_session()
    js = RUNTIME_SHIM + (SESSION["js"] or FALLBACK_HEAL_JS.encode()) + GW_LOGOUT_JS.encode() + NAV_FIX_JS.encode()
    if external:
        js = js + EXTERNAL_HELPER_JS.encode("utf-8")
    return b'<base href="' + PB + b'/">' + b"<script>" + js + b"</script>"


def rewrite_body(body, external=False):
    if b"<head" in body and b"gw_logout" not in body:
        body = re.sub(rb"(<head[^>]*>)", lambda m: m.group(1) + helper_html(external), body, count=1)
    for p in _STR_PATHS:
        body = re.sub(rb'(?<!androidemu)(["\'])' + re.escape(p), lambda m: m.group(1) + PB + p, body)
    body = re.sub(rb'//\$\{location\.host\}(?!' + re.escape(PB) + rb')', b'//${location.host}' + PB, body)
    body = _ROUTE_RE.sub(lambda m: b'href="' + PB + b'/' + m.group(1) + m.group(2) + b'"', body)
    body = version_assets(body)
    return body


# ---------------------------------------------------------------- WebSocket

def ws_ping_frame(masked):
    """2.0.73：双向保活。只给浏览器发 Ping 时，连接仍会在 60 秒被上游/nginx 断开，
    因为「客户端→上游」方向的空闲同样有 60 秒超时，而真实心跳间隔恰好也是 60 秒。"""
    pl = b"gwke"
    if not masked:
        return b"\x89\x04" + pl
    k = os.urandom(4)
    return b"\x89\x84" + k + bytes(b ^ k[i % 4] for i, b in enumerate(pl))


def ws_keepalive(client, upstream, lock):
    cf = ws_ping_frame(False)
    uf = ws_ping_frame(True)
    while True:
        time.sleep(WS_PING)
        try:
            with lock:
                client.sendall(cf)
                upstream.sendall(uf)
        except Exception:
            return


def tunnel(a, b, lock=None):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            if lock is None:
                b.sendall(d)
            else:
                with lock:
                    b.sendall(d)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                s.close()
            except Exception:
                pass


def handle_ws(conn, method, path, req_lines):
    u = open_upstream()
    u.settimeout(None)
    log("WS 升级: %s" % path)
    tok = ensure_session()
    ws_path = sub_token(path, tok) if tok else path
    out = [b"%s %s HTTP/1.1\r\n" % (method, ws_path.encode("latin1"))]
    # 2.0.87：握手必须保留 Connection: Upgrade（不能用 strip_hop，它会过滤 connection 头）
    for h in req_lines[1:]:
        k = h.split(b":")[0].strip().lower()
        if k.startswith(b"x-trim-") or k in (b"keep-alive", b"proxy-connection", b"transfer-encoding"):
            continue
        out.append(h)
    out.append(b"\r\n")
    u.sendall(b"".join(out))
    uf = u.makefile("rb")
    resp = read_headers(uf)
    try:
        code = int(resp[0].split()[1]) if resp else 0
    except Exception:
        code = 0
    # 2.0.74：被上游拒绝时改用服务端会话重试一次（手机 APP 的 WS 常在网关这层被 401）
    if code != 101 and tok and path.split("?")[0].startswith("/connect_client"):
        log("WS 被拒（上游 %d），改用服务端会话重试：%s" % (code, path))
        try:
            u.close()
        except Exception:
            pass
        try:
            u = open_upstream()
            u.settimeout(None)
            SESSION["js"] = b""
            SESSION["token"] = ""
            SESSION["ts"] = 0.0
            tok2 = ensure_session()
            np = sub_token(path, tok2) if tok2 else path
            hdrs = []
            for h in req_lines[1:]:
                k = h.split(b":")[0].strip().lower()
                if k.startswith(b"x-trim-") or k in (b"keep-alive", b"proxy-connection", b"transfer-encoding"):
                    continue
                hdrs.append(h)
            u.sendall(b"".join([b"%s %s HTTP/1.1\r\n" % (method, np.encode("latin1"))] + hdrs + [b"\r\n"]))
            uf = u.makefile("rb")
            resp = read_headers(uf)
        except Exception as e:
            log("WS 重试异常：%r" % (e,))
            resp = []
        try:
            code = int(resp[0].split()[1]) if resp else 0
        except Exception:
            code = 0
        log("WS 重试结果：上游 %d" % code)
    if resp:
        conn.sendall(b"".join(resp) + b"\r\n")
    if code != 101:
        log("WS 未升级（上游 %d）：%s" % (code, path))
        try:
            u.close()
        except Exception:
            pass
        return
    t0 = time.time()
    lock = threading.Lock()
    threading.Thread(target=ws_keepalive, args=(conn, u, lock), daemon=True).start()
    threading.Thread(target=tunnel, args=(conn, u, lock), daemon=True).start()
    tunnel(u, conn, lock)
    log("WS 结束: %s（持续 %.1f 秒）" % (path, time.time() - t0))


# ---------------------------------------------------------------- 附加接口

def check_tcp_port(host, port, timeout=2):
    """检测TCP端口是否在监听"""
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        s.close()
        return True
    except Exception:
        return False

def check_udp_port(port):
    """检测UDP端口是否在监听（通过ss命令）"""
    try:
        r = subprocess.run(["ss", "-lun"], capture_output=True, timeout=5)
        if r.returncode == 0:
            out = r.stdout.decode("utf-8", "replace")
            return ":%d " % port in out or ":%d\n" % port in out
    except Exception:
        pass
    return False

def status_page_html(error_msg=""):
    """3.7.0：上游不可用时返回友好的状态页，而不是纯文本 Bad Gateway。
    显示容器状态、常见问题、日志路径，帮助用户自助排查。"""
    # 快速检测容器状态
    containers = {}
    try:
        r = subprocess.run(["docker", "ps", "-a", "--filter", "name=androidemu",
                           "--format", "{{.Names}}|{{.Status}}"], capture_output=True, timeout=5)
        if r.returncode == 0:
            for line in r.stdout.decode("utf-8", "replace").strip().split("\n"):
                if "|" in line:
                    name, status = line.split("|", 1)
                    containers[name] = status
    except Exception:
        pass

    boot = False
    if "androidemu-android" in containers and "Up" in containers.get("androidemu-android", ""):
        try:
            r2 = subprocess.run(["docker", "exec", "androidemu-android", "getprop", "sys.boot_completed"],
                               capture_output=True, timeout=5)
            boot = r2.stdout.decode("utf-8", "replace").strip() == "1"
        except Exception:
            pass

    # 判断当前状态
    if not containers:
        stage = "installing"
        stage_title = "正在安装中"
        stage_desc = "应用正在后台拉取安卓镜像（约 2GB）并启动容器，请耐心等待 1-5 分钟后刷新页面。"
    elif "androidemu-android" not in containers:
        stage = "no_container"
        stage_title = "安卓容器未创建"
        stage_desc = "安卓容器尚未创建，可能安装未完成或被手动删除。请尝试在应用中心停用后重新启用。"
    elif "Exited" in containers.get("androidemu-android", ""):
        stage = "container_exited"
        stage_title = "安卓容器已停止"
        stage_desc = "安卓容器已退出。请在应用中心点击「停用」后再「启用」，或查看日志排查原因。"
    elif not boot:
        stage = "booting"
        stage_title = "安卓系统正在启动"
        stage_desc = "容器已运行，但安卓系统尚未完成启动。首次启动可能需要 1-3 分钟，请刷新页面重试。"
    else:
        stage = "upstream_down"
        stage_title = "画面服务未响应"
        stage_desc = "安卓系统已启动，但穿云投屏画面服务暂时无响应。请刷新页面，或在应用中心停用后重新启用。"

    container_rows = ""
    for name, status in containers.items():
        container_rows += "<tr><td>%s</td><td>%s</td></tr>" % (name, status)
    if not container_rows:
        container_rows = "<tr><td colspan='2'>暂无容器（首次安装正在拉取镜像）</td></tr>"

    html = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>androidemu - 状态</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#f5f7fa;margin:0;padding:40px 20px;color:#333}
.card{max-width:600px;margin:0 auto;background:#fff;border-radius:12px;box-shadow:0 2px 12px rgba(0,0,0,0.08);padding:32px}
h1{font-size:22px;margin:0 0 8px;color:#1a1a1a}
.stage{display:inline-block;padding:4px 12px;border-radius:20px;font-size:13px;font-weight:500;margin-bottom:16px}
.stage-installing{background:#fff3cd;color:#856404}
.stage-booting{background:#d1ecf1;color:#0c5460}
.stage-error{background:#f8d7da;color:#721c24}
.stage-ok{background:#d4edda;color:#155724}
p{line-height:1.6;color:#555;margin:8px 0}
table{width:100%;border-collapse:collapse;margin:16px 0;font-size:14px}
th,td{text-align:left;padding:8px 12px;border-bottom:1px solid #eee}
th{background:#f8f9fa;font-weight:600}
.tips{background:#f8f9fa;border-radius:8px;padding:16px;margin-top:20px}
.tips h3{font-size:15px;margin:0 0 8px;color:#333}
.tips ul{margin:0;padding-left:20px;color:#666;font-size:13px;line-height:1.8}
code{background:#e9ecef;padding:2px 6px;border-radius:4px;font-size:13px}
.btn{display:inline-block;margin-top:16px;padding:10px 24px;background:#4a90d9;color:#fff;text-decoration:none;border-radius:6px;font-size:14px}
.btn:hover{background:#357abd}
.error{background:#f8d7da;color:#721c24;padding:12px;border-radius:6px;margin:12px 0;font-size:13px}
</style>
</head>
<body>
<div class="card">
<h1>androidemu 安卓模拟器</h1>
<div class="stage stage-%s">%s</div>
<p>%s</p>
%s
<h3 style="font-size:15px;margin:20px 0 8px">容器状态</h3>
<table>
<tr><th>容器名</th><th>状态</th></tr>
%s
</table>
<h3 style="font-size:15px;margin:20px 0 8px">健康状态</h3>
<div id="health-status" class="tips" style="margin-top:0">
<p style="margin:0">正在检测...</p>
</div>
<div id="health-actions" style="margin-top:12px;display:none">
<button onclick="fixAction('fix_gpu')" style="padding:8px 16px;margin-right:8px;border:1px solid #4a90d9;background:#fff;color:#4a90d9;border-radius:6px;cursor:pointer">修复GPU/画面</button>
<button onclick="fixAction('restart_container')" style="padding:8px 16px;margin-right:8px;border:1px solid #f0ad4e;background:#fff;color:#f0ad4e;border-radius:6px;cursor:pointer">重启安卓容器</button>
<button onclick="fixAction('restart_surfaceflinger')" style="padding:8px 16px;border:1px solid #999;background:#fff;color:#666;border-radius:6px;cursor:pointer">重启画面服务</button>
</div>
<script>
function fixAction(a){
  if(!confirm("确定执行"+a+"？"))return;
  fetch("/app/androidemu/api/health_fix?action="+a).then(r=>r.json()).then(d=>{
    alert(d.message);
    if(d.ok)setTimeout(()=>location.reload(),3000);
  });
}
fetch("/app/androidemu/api/status").then(r=>r.json()).then(d=>{
  var h=d.health||{};
  var el=document.getElementById("health-status");
  var actions=document.getElementById("health-actions");
  var statusMap={
    "healthy":["运行正常","#d4edda","#155724"],
    "booting":["启动中","#d1ecf1","#0c5460"],
    "boot_timeout":["启动超时","#fff3cd","#856404"],
    "oom_killed":["内存不足被杀死","#f8d7da","#721c24"],
    "surfaceflinger_dead":["画面服务异常","#f8d7da","#721c24"],
    "not_running":["容器未运行","#f8d7da","#721c24"],
    "unknown":["未知","#eee","#666"]
  };
  var s=statusMap[h.status]||statusMap["unknown"];
  var uptime=h.uptime_seconds?Math.floor(h.uptime_seconds/60)+"分钟":"";
  el.innerHTML="<p style=\"margin:0\"><b>状态：</b><span style=\"color:"+s[2]+"\">"+s[0]+"</span></p>"
    +"<p style=\"margin:4px 0\"><b>详情：</b>"+(h.detail||"")+"</p>"
    +"<p style=\"margin:4px 0\"><b>运行时长：</b>"+(uptime||"未知")+" | <b>boot完成：</b>"+(h.boot_completed?"是":"否")
    +" | <b>OOM：</b>"+(h.oom_killed?"是":"否")+" | <b>画面服务：</b>"+(h.surfaceflinger_running?"运行中":"未运行")+"</p>";
  if(h.status!=="healthy"&&h.status!=="booting"&&h.status!=="not_running"){
    actions.style.display="block";
  }
});
</script>
<div class="tips">
<h3>常见问题排查</h3>
<ul>
<li><b>首次安装慢</b>：需拉取约 2GB 镜像，取决于网速，通常 1-5 分钟。</li>
<li><b>X86 设备</b>：必须先在应用中心安装「binder_linux」驱动，否则安卓容器无法启动。</li>
<li><b>内存不足</b>：建议 2GB 以上可用内存，低于 1GB 容器会被系统杀死。</li>
<li><b>查看日志</b>：SSH 登录 NAS 执行 <code>cat /var/apps/androidemu/var/install.log</code></li>
<li><b>仍无法解决</b>：在应用中心「停用」→ 等待 10 秒 →「启用」，或在飞牛论坛反馈。</li>
</ul>
</div>
<a href="javascript:location.reload()" class="btn">刷新页面</a>
</div>
</body>
</html>""" % (stage, stage_title, stage_desc,
              ("<div class='error'>%s</div>" % error_msg) if error_msg else "",
              container_rows)
    return html.encode("utf-8")


def check_container_health():
    """3.7.0：容器健康检查，检测启动时间、OOM、surfaceflinger、agent状态。"""
    def run(cmd, timeout=8):
        try:
            return subprocess.run(cmd, capture_output=True, timeout=timeout)
        except Exception:
            return None
    health = {"status": "unknown", "boot_completed": False, "uptime_seconds": 0,
              "oom_killed": False, "surfaceflinger_running": False,
              "agent_running": False, "detail": ""}
    # 容器是否在运行
    r = run(["docker", "ps", "--filter", "name=androidemu-android", "--format", "{{.Status}}|{{.RunningFor}}"])
    if not r or r.returncode != 0 or not r.stdout.strip():
        health["status"] = "not_running"
        health["detail"] = "安卓容器未运行"
        return health
    status_line = r.stdout.decode("utf-8", "replace").strip()
    health["container_status"] = status_line.split("|")[0] if "|" in status_line else status_line
    # boot_completed
    r2 = run(["docker", "exec", "androidemu-android", "getprop", "sys.boot_completed"])
    if r2 and r2.returncode == 0:
        health["boot_completed"] = r2.stdout.decode("utf-8", "replace").strip() == "1"
    # 启动时间
    r3 = run(["docker", "inspect", "-f", "{{.State.StartedAt}}", "androidemu-android"])
    if r3 and r3.returncode == 0:
        started = r3.stdout.decode("utf-8", "replace").strip()
        try:
            from datetime import datetime, timezone
            start_time = datetime.fromisoformat(started.replace("Z", "+00:00"))
            health["uptime_seconds"] = int((datetime.now(timezone.utc) - start_time).total_seconds())
        except Exception:
            pass
    # OOM检查
    r4 = run(["docker", "inspect", "-f", "{{.State.OOMKilled}}", "androidemu-android"])
    if r4 and r4.returncode == 0:
        health["oom_killed"] = r4.stdout.decode("utf-8", "replace").strip() == "true"
    # surfaceflinger
    r5 = run(["docker", "exec", "androidemu-android", "ps", "-A"])
    if r5 and r5.returncode == 0:
        procs = r5.stdout.decode("utf-8", "replace")
        health["surfaceflinger_running"] = "surfaceflinger" in procs
        health["agent_running"] = "agent" in procs.lower() or "scrcpy" in procs.lower()
    # 综合判断
    if health["oom_killed"]:
        health["status"] = "oom_killed"
        health["detail"] = "容器因内存不足被系统杀死（OOM），请增加可用内存或关闭其他应用"
    elif not health["boot_completed"] and health["uptime_seconds"] > 300:
        health["status"] = "boot_timeout"
        health["detail"] = "安卓系统启动超过5分钟仍未完成，可能是binder/GPU/内存问题"
    elif health["boot_completed"] and not health["surfaceflinger_running"]:
        health["status"] = "surfaceflinger_dead"
        health["detail"] = "安卓已启动但surfaceflinger未运行，画面服务异常"
    elif health["boot_completed"]:
        health["status"] = "healthy"
        health["detail"] = "安卓系统运行正常"
    else:
        health["status"] = "booting"
        health["detail"] = "安卓系统正在启动中"
    return health


def api_status():
    def run(cmd):
        try:
            return subprocess.run(cmd, capture_output=True, timeout=10)
        except Exception:
            return None
    containers = {}
    r = run(["docker", "ps", "--filter", "name=androidemu", "--format", "{{.Names}}|{{.Status}}"])
    if r and r.returncode == 0:
        for line in r.stdout.decode("utf-8", "replace").strip().split("\n"):
            if "|" in line:
                name, status = line.split("|", 1)
                containers[name] = status
    boot = False
    if "androidemu-android" in containers:
        r2 = run(["docker", "exec", "androidemu-android", "getprop", "sys.boot_completed"])
        if r2:
            boot = r2.stdout.decode("utf-8", "replace").strip() == "1"
    ports = {
        "8443_tcp": {"name": "Web界面/信令", "listening": check_tcp_port("127.0.0.1", 8443)},
        "3478_tcp": {"name": "TURN中继(TCP)", "listening": check_tcp_port("127.0.0.1", 3478)},
        "3478_udp": {"name": "TURN中继(UDP)", "listening": check_udp_port(3478)},
        "5556_tcp": {"name": "ADB调试", "listening": check_tcp_port("127.0.0.1", 5556)},
    }
    health = check_container_health()
    return json.dumps({"containers": containers, "boot_completed": boot,
                       "version": VERSION, "prefix": PREFIX,
                       "ports": ports, "health": health}).encode()


def api_health_fix(action):
    """3.7.0：容器健康修复API，支持restart_container、fix_gpu、restart_surfaceflinger。"""
    result = {"ok": False, "action": action, "message": ""}
    try:
        if action == "restart_container":
            r = subprocess.run(["docker", "restart", "androidemu-android"],
                              capture_output=True, timeout=30)
            result["ok"] = r.returncode == 0
            result["message"] = "容器重启命令已发送，等待1-2分钟后刷新页面" if r.returncode == 0 else r.stderr.decode("utf-8", "replace")
        elif action == "fix_gpu":
            # GPU修复：chmod /dev/dri + 重启surfaceflinger
            cmds = [
                ["docker", "exec", "-u", "0", "androidemu-android", "chmod", "0666", "/dev/dri/renderD128"],
                ["docker", "exec", "-u", "0", "androidemu-android", "chmod", "0666", "/dev/dri/card0"],
                ["docker", "exec", "-u", "0", "androidemu-android", "setprop", "ctl.restart", "surfaceflinger"],
            ]
            for c in cmds:
                subprocess.run(c, capture_output=True, timeout=10)
            result["ok"] = True
            result["message"] = "GPU修复已执行（/dev/dri放权 + 重启surfaceflinger），等待30秒后刷新页面"
        elif action == "restart_surfaceflinger":
            r = subprocess.run(["docker", "exec", "-u", "0", "androidemu-android", "setprop", "ctl.restart", "surfaceflinger"],
                              capture_output=True, timeout=10)
            result["ok"] = r.returncode == 0
            result["message"] = "surfaceflinger重启命令已发送" if r.returncode == 0 else r.stderr.decode("utf-8", "replace")
        else:
            result["message"] = "未知操作，支持: restart_container, fix_gpu, restart_surfaceflinger"
    except Exception as e:
        result["message"] = "执行失败: %s" % e
    return json.dumps(result).encode()




def stream_mjpg(conn):
    """MJPEG 流：通过 docker exec screencap 持续截图，供外网低帧率查看。
    走 HTTP，可通过飞牛网关访问；WebRTC 走不了网关时用这个看画面。"""
    boundary = b"--frame"
    try:
        conn.sendall(b"HTTP/1.1 200 OK\r\n"
                     b"Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
                     b"Cache-Control: no-store\r\n"
                     b"Connection: close\r\n\r\n")
    except Exception as e:
        log("MJPEG 发送响应头失败: %s" % e)
        try:
            conn.close()
        except Exception:
            pass
        return
    frames = 0
    errors = 0
    try:
        while True:
            try:
                # 用完整路径 + check_output，避免 capture_output 兼容性问题
                img = subprocess.check_output(
                    ["/usr/bin/docker", "exec", "androidemu-android", "screencap", "-p"],
                    stderr=subprocess.DEVNULL, timeout=8)
            except subprocess.CalledProcessError as e:
                errors += 1
                if errors <= 3:
                    log("MJPEG 截图返回码 %d（第%d次）" % (e.returncode, errors))
                time.sleep(0.5)
                continue
            except Exception as e:
                errors += 1
                if errors <= 3:
                    log("MJPEG 截图异常: %s（第%d次）" % (e, errors))
                time.sleep(0.5)
                continue
            if not img:
                errors += 1
                if errors <= 3:
                    log("MJPEG 截图为空（第%d次）" % errors)
                time.sleep(0.5)
                continue
            try:
                conn.sendall(boundary + b"\r\n")
                conn.sendall(b"Content-Type: image/png\r\n")
                conn.sendall(b"Content-Length: %d\r\n\r\n" % len(img))
                conn.sendall(img)
                conn.sendall(b"\r\n")
            except (BrokenPipeError, ConnectionResetError):
                break
            except Exception as e:
                log("MJPEG 发送帧失败: %s" % e)
                break
            frames += 1
            errors = 0
            time.sleep(0.15)
    except Exception as e:
        log("MJPEG 流异常: %s" % e)
    finally:
        log("MJPEG 流结束，共 %d 帧，错误 %d 次" % (frames, errors))
        try:
            conn.close()
        except Exception:
            pass

# ---------------------------------------------------------------- 请求处理

def serve():
    load_conf()
    try:
        os.unlink(SOCK_PATH)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    os.chmod(SOCK_PATH, 0o666)
    srv.listen(128)
    try:
        with open(CHILD_PID, "w") as f:
            f.write(str(os.getpid()))
        with open(VER_FILE, "w") as f:
            f.write(VERSION)
    except Exception:
        pass
    log("代理已监听 %s -> %s:%d tls=%s prefix=%s 版本=%s" % (
        SOCK_PATH, UPSTREAM_HOST, UPSTREAM_PORT, USE_TLS, PREFIX, VERSION))

    # 3.8.3: 翻译层崩溃自动检测线程（auto模式下检测到SIGILL自动切houdini）
    def _translation_crash_watcher():
        import subprocess
        CRASH_FLAG = "/var/apps/androidemu/var/translation_crash.flag"
        last_check = 0
        check_interval = 30  # 每30秒检查一次
        restart_cooldown = 300  # 重启冷却5分钟，避免循环重启
        last_restart = 0
        while True:
            time.sleep(check_interval)
            now = time.time()
            if now - last_check < check_interval:
                continue
            last_check = now
            try:
                # 检查logcat中的翻译层崩溃
                result = subprocess.run(
                    ["docker", "exec", "androidemu-android", "logcat", "-d", "-t", "200"],
                    capture_output=True, text=True, timeout=15
                )
                logcat = result.stdout + result.stderr
                if ("Undefined instruction" in logcat or "SIGILL" in logcat or
                    "ndk_translation" in logcat and "Undefined" in logcat):
                    # 检测到翻译层崩溃
                    if not os.path.exists(CRASH_FLAG):
                        os.makedirs(os.path.dirname(CRASH_FLAG), exist_ok=True)
                        with open(CRASH_FLAG, "w") as f:
                            f.write("translation_crash detected at %s\n" % time.strftime("%Y-%m-%d %H:%M:%S"))
                        log("翻译层崩溃检测：发现Undefined instruction/SIGILL，已标记，下次重启将自动切换到houdini")

                    # 如果在冷却期外，自动重启容器以应用houdini
                    if now - last_restart > restart_cooldown:
                        translation_mode = os.environ.get("ANDROIDEMU_TRANSLATION", "auto")
                        if translation_mode == "auto":
                            log("auto模式：自动重启容器以切换到houdini翻译层")
                            last_restart = now
                            subprocess.run(
                                ["bash", "-c", "cd /vol1/@appcenter/androidemu/docker && bash ../scripts/tune_compose.sh docker-compose.yaml && docker compose restart redroid"],
                                capture_output=True, timeout=60
                            )
            except Exception as e:
                pass  # 静默失败，不影响主服务

    threading.Thread(target=_translation_crash_watcher, daemon=True).start()

    while True:
        try:
            conn, _ = srv.accept()
        except Exception:
            continue
        threading.Thread(target=handle_request, args=(conn,), daemon=True).start()


def handle_request(conn):
    u = None
    try:
        f = conn.makefile("rb")
        req = read_headers(f)
        if not req:
            conn.close()
            return
        try:
            method, target, _ = req[0].split(None, 2)
        except Exception:
            send_err(conn, 400, "Bad Request")
            conn.close()
            return
        rh = hmap(req[1:])
        ext = is_external_host(rh.get(b"host", b""))
        body = read_body(f, rh)

        path = target.decode("latin1")
        if path.startswith(PREFIX):
            path = path[len(PREFIX):] or "/"
        if not path.startswith("/"):
            path = "/" + path
        bare = path.split("?")[0]

        # 2.0.80：CORS 预检直接回 204（飞牛手机 APP WebView 视页面为非 http 源时会先发 OPTIONS）
        if method == b"OPTIONS":
            conn.sendall(b"HTTP/1.1 204 No Content\r\n"
                         b"Access-Control-Allow-Origin: *\r\n"
                         b"Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS, PATCH\r\n"
                         b"Access-Control-Allow-Headers: Authorization, Content-Type, X-Requested-With\r\n"
                         b"Access-Control-Max-Age: 86400\r\n"
                         b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            conn.close()
            return

        if bare == "/api/status":
            b = api_status()
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n"
                         b"Access-Control-Allow-Origin: *\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(b) + b)
            return

        # 3.7.0：容器健康修复API
        if bare.startswith("/api/health_fix"):
            _action = "restart_container"
            if "?" in target.decode("latin1"):
                _q = target.decode("latin1").split("?", 1)[1]
                for _p in _q.split("&"):
                    if _p.startswith("action="):
                        _action = _p.split("=", 1)[1]
            b = api_health_fix(_action)
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n"
                         b"Access-Control-Allow-Origin: *\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(b) + b)
            return

        if bare == "/stream.mjpg":
            log("MJPEG 流请求来自 %s" % rh.get(b"x-forwarded-for", b"unknown").decode("latin1", "replace"))
            stream_mjpg(conn)
            return


        # 2.0.72：强制换页 —— 页面请求不带 gwv= 时 302 到带版本号的同一地址。
        # 浏览器（尤其长期开着的标签/被恢复的标签）会一直用缓存里的旧页面与旧懒加载 chunk，
        # 旧 chunk 里的地址没有前缀，会打到飞牛自己的 www（实测 /devices 404、/connect_client 404），
        # 表现为「0 台设备 + 未授权」，只刷新接口没用 —— 必须让浏览器重新取文档。
        if method == b"GET" and b"gwv=" not in target and b"text/html" in rh.get(b"accept", b"").lower():
            sep = b"&" if b"?" in target else b"?"
            loc = target + sep + b"gwv=" + VERSION.encode()
            log("强制换页 302 -> %s" % loc.decode("latin1"))
            conn.sendall(b"HTTP/1.1 302 Found\r\nLocation: " + loc +
                         b"\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return

        if b"websocket" in rh.get(b"upgrade", b"").lower():
            handle_ws(conn, method, path, req)
            return

        # 3.7.3：移除API层音频强制禁用（Opus编码器已通过audio_fix.py自动注入，允许用户开启音频）
        # 3.3.3：强制禁用音频 —— redroid 容器内 Opus 编码器未注册导致 CoreService 崩溃。
        # 只在 /api/default_settings 读取 body 并替换 audio:true -> audio:false，不影响其他 API。
        # if method == b"GET" and bare == "/api/default_settings":
        #     tok2 = ensure_session()
        #     uu2 = open_upstream()
        #     uu2.settimeout(30)
        #     out2 = [b"GET /api/default_settings HTTP/1.1\r\nHost: localhost\r\n"]
        #     if tok2:
        #         out2.append(b"Authorization: Bearer " + tok2.encode() + b"\r\n")
        #     out2.append(b"Accept: application/json\r\nConnection: close\r\n\r\n")
        #     uu2.sendall(b"".join(out2))
        #     uf2 = uu2.makefile("rb")
        #     resp2 = read_headers(uf2)
        #     if resp2:
        #         resph2 = hmap(resp2[1:])
        #         cl2 = int(resph2.get(b"content-length", b"0") or 0)
        #         rbody2 = uf2.read(cl2) if cl2 else b""
        #         import re as _re
        #         rbody2 = _re.sub(rb'"audio":\s*true', b'"audio":false', rbody2)
        #         log("强制禁用音频：/api/default_settings 已替换 audio:true -> audio:false")
        #         conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n"
        #                      b"Content-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" % len(rbody2) + rbody2)
        #         uu2.close()
        #         return
        #     uu2.close()

        # 3.3.2：前端 WS 不稳定时会 fallback 到 HTTP 轮询 /devices 期望 JSON，
        # 但 SPA fallback 会把它变成 index.html 导致 JSON.parse 崩（"0台在线"）。
        # 设备列表实际走 WS 推送，这里给轮询返回空数组，避免前端报错。
        if method == b"GET" and bare == "/devices" and b"application/json" in rh.get(b"accept", b"").lower():
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n"
                         b"Content-Length: 2\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n[]")
            return

        # 2.0.82：SPA fallback —— 非 API/非静态/非 WS 的 GET 页面请求统一请求上游 /，
        # 由前端 Vue Router 处理路由（上游对 /dashboard、/files 等子路径返回过旧版裸页面）。
        if method == b"GET" and not any(bare.startswith(p) for p in (
                "/api/", "/assets/", "/ws/", "/connect_client",
                "/snapshot", "/upload", "/download", "/favicon",
                "/audit", "/logs", "/monitor", "/terminal", "/files",
                "/devices")):
            log("SPA fallback: %s -> /" % bare)
            path = "/"
            bare = "/"

        # 2.0.75：网关对应用会话负责 —— 除匿名接口外，Authorization 一律用服务端会话，
        # 客户端自带的旧/坏 token 直接覆盖（否则上游回 13 字节 Unauthorized）。
        tok = ensure_session()
        override = bool(tok) and bare not in ("/api/login", "/api/register", "/api/auth-status", "/api/logout")

        def open_and_send():
            uu = open_upstream()
            uu.settimeout(120)
            out = [b"%s %s HTTP/1.1\r\n" % (method, path.encode("latin1"))]
            has_auth = False
            for h in strip_hop(req[1:]):
                hl = h.lower()
                if hl.startswith(b"accept-encoding:"):
                    continue
                if hl.startswith(b"authorization:"):
                    has_auth = True
                    if override:
                        continue
                out.append(h)
            if override:
                out.append(b"Authorization: Bearer " + tok.encode() + b"\r\n")
                log("%s服务端会话：%s %s" % ("覆盖客户端授权头为" if has_auth else "补注入",
                                            method.decode(errors="ignore"), bare))
            out.append(b"Content-Length: %d\r\n" % len(body))
            out.append(b"Accept-Encoding: identity\r\n")
            out.append(b"Connection: close\r\n\r\n")
            uu.sendall(b"".join(out) + body)
            return uu

        u = open_and_send()
        uf = u.makefile("rb")
        resp = read_headers(uf)
        try:
            rc = int(resp[0].split()[1]) if resp else 0
        except Exception:
            rc = 0
        # 2.0.75：服务端会话被上游拒绝（过期/被登出）→ 清缓存、重新登录、重试一次
        if rc == 401 and override:
            log("上游 401 拒绝服务端会话，重新登录后重试：%s" % bare)
            SESSION["js"] = b""
            SESSION["token"] = ""
            SESSION["ts"] = 0.0
            tok2 = ensure_session()
            if tok2:
                try:
                    u.close()
                except Exception:
                    pass
                tok = tok2
                u = open_and_send()
                uf = u.makefile("rb")
                resp = read_headers(uf)
                try:
                    rc = int(resp[0].split()[1]) if resp else 0
                except Exception:
                    rc = 0
        if not resp:
            log("上游无响应: %s %s" % (method.decode(errors="ignore"), path))
            send_err(conn, 502, "Bad Gateway: empty upstream response")
            return
        resph = hmap(resp[1:])
        # 3.1.0：上游（镜像内 webrtc-signaling 二进制，没有 nginx）对找不到的路径会无条件回退
        # index.html —— 于是 /assets/*.js 变成 "MIME text/html"、/api/* 变成 HTML 让前端
        # JSON.parse 崩掉（直连端口实测）。这里把"回退成 HTML"的静态资源与接口纠正为真实错误码。
        if (bare.startswith("/assets/") or bare.endswith(STATIC_EXT) or bare.startswith("/api/")) and b"text/html" in resph.get(b"content-type", b"").lower():
            if bare.startswith("/api/"):
                _b = b'{"error":"upstream_fallback_html","path":"' + bare.encode() + b'"}'
                _code, _ctype = 502, b"application/json; charset=utf-8"
            else:
                _b = b""
                _code, _ctype = 404, b"application/octet-stream"
            log("上游把 %s 回退成了 HTML，已纠正为 %d" % (bare, _code))
            conn.sendall(b"HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %d\r\n"
                         b"Cache-Control: no-store\r\nConnection: close\r\n\r\n" % (_code, _ctype, len(_b)) + _b)
            return
        if rc >= 400:
            log("上游 %d: %s %s" % (rc, method.decode(errors="ignore"), path))
        ctype = resph.get(b"content-type", b"").decode("latin1").lower()
        chunked = b"chunked" in resph.get(b"transfer-encoding", b"").lower()
        # 2.0.80：只改写 HTML/CSS（ES module 的 JS 盲改会破坏动态 import；运行期 shim 已覆盖）
        rewrite = ("text/html" in ctype) or ("text/css" in ctype)

        if rewrite:
            rbody = dechunk(uf) if chunked else uf.read(int(resph.get(b"content-length", b"0") or 0))
            rbody = rewrite_body(rbody, ext)
            is_html = "text/html" in ctype
            newh = [resp[0]]
            for h in strip_hop(resp[1:]):
                k = h.split(b":")[0].strip().lower()
                if k in (b"content-length", b"content-encoding"):
                    continue
                if is_html and k in (b"cache-control", b"expires", b"pragma", b"etag", b"last-modified"):
                    continue
                newh.append(h)
            newh.append(b"Content-Length: %d\r\n" % len(rbody))
            newh.append(b"Access-Control-Allow-Origin: *\r\n")
            newh.append(b"Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS, PATCH\r\n")
            newh.append(b"Access-Control-Allow-Headers: Authorization, Content-Type, X-Requested-With\r\n")
            if is_html:
                newh.append(b"Cache-Control: no-store, no-cache, must-revalidate\r\n")
                newh.append(b"Pragma: no-cache\r\n")
            newh.append(b"Connection: close\r\n\r\n")
            conn.sendall(b"".join(newh) + rbody)
        else:
            newh = [resp[0]] + strip_hop(resp[1:])
            newh.append(b"Access-Control-Allow-Origin: *\r\n")
            newh.append(b"Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS, PATCH\r\n")
            newh.append(b"Access-Control-Allow-Headers: Authorization, Content-Type, X-Requested-With\r\n")
            newh.append(b"Connection: close\r\n\r\n")
            conn.sendall(b"".join(newh))
            if chunked:
                while True:
                    line = uf.readline()
                    if not line:
                        break
                    conn.sendall(line)
                    s = line.strip()
                    if not s:
                        continue
                    try:
                        n = int(s.split(b";")[0], 16)
                    except Exception:
                        break
                    if n == 0:
                        conn.sendall(b"\r\n")
                        break
                    conn.sendall(uf.read(n))
                    conn.sendall(uf.read(2))
            else:
                left = int(resph.get(b"content-length", b"0") or 0)
                while left > 0:
                    d = uf.read(min(65536, left))
                    if not d:
                        break
                    conn.sendall(d)
                    left -= len(d)
    except Exception as e:
        log("代理异常: %r" % (e,))
        try:
            # 3.7.0：上游不可用时返回友好的状态页，而不是纯文本 Bad Gateway
            # 仅对页面请求（GET，非API，非静态资源）返回HTML，API请求仍返回JSON错误
            if method == b"GET" and not bare.startswith("/api/") and not bare.startswith("/assets/"):
                _html = status_page_html(str(e))
                conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\n"
                             b"Content-Type: text/html; charset=utf-8\r\n"
                             b"Content-Length: %d\r\n"
                             b"Cache-Control: no-store\r\nConnection: close\r\n\r\n" % len(_html) + _html)
            else:
                send_err(conn, 502, "Bad Gateway: proxy error")
        except Exception:
            pass
    finally:
        try:
            if u is not None:
                u.close()
        except Exception:
            pass
        try:
            conn.close()
        except Exception:
            pass


# ---------------------------------------------------------------- 探活与守护

def probe_once(timeout=8):
    """通过 socket 取一次页面：异常视为不可用。不依赖 curl。"""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(SOCK_PATH)
        s.sendall(("GET %s/?gwv=%s HTTP/1.1\r\nHost: localhost\r\nAccept: text/html\r\n"
                   "Connection: close\r\n\r\n" % (PREFIX, VERSION)).encode())
        data = s.recv(64)
        s.close()
        if not data.startswith(b"HTTP/"):
            return False
        try:
            code = int(data.split(b" ")[1])
        except Exception:
            return False
        return 200 <= code < 400
    except Exception:
        return False


def ver_ok():
    try:
        with open(VER_FILE) as f:
            return f.read().strip() == VERSION
    except Exception:
        return False



DAEMON_SH = os.path.join(APP_DEST, "scripts", "androidemu_daemon.sh")
AUDIO_PID = os.path.join(VAR_DIR, "audio_watchdog.pid")


def audio_watchdog_pid():
    """找出本应用正在运行的统一守护进程（音频+分辨率）。

    先认 PID 文件；PID 文件缺失/过期时再按命令行兜底扫描。
    """
    pid = read_pid(AUDIO_PID)
    if pid and is_mine(pid) and "androidemu_daemon" in pid_cmdline(pid):
        return pid
    me = os.getpid()
    try:
        entries = os.listdir("/proc")
    except Exception:
        return None
    for e in entries:
        if not e.isdigit():
            continue
        p = int(e)
        if p == me or not is_mine(p):
            continue
        cmd = pid_cmdline(p)
        if "androidemu_daemon" not in cmd:
            continue
        if not any(x and x in cmd for x in SELF_PREFIXES):
            continue
        return p
    return None


def audio_watchdog_ok():
    """音频守护是否在运行（PID 文件 + cmdline 身份校验，不依赖 pkill）。"""
    return audio_watchdog_pid() is not None


def _bind_listen():
    """绑定 Unix socket 并开始监听（本进程内）。失败抛异常。"""
    try:
        os.unlink(SOCK_PATH)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    os.chmod(SOCK_PATH, 0o666)
    srv.listen(128)
    return srv


def _accept_loop(srv):
    while True:
        try:
            conn, _ = srv.accept()
        except Exception:
            time.sleep(0.2)
            continue
        threading.Thread(target=handle_request, args=(conn,), daemon=True).start()


SERVER = {"srv": None, "thread": None}


def server_alive():
    t = SERVER.get("thread")
    return bool(t and t.is_alive())


def start_server_thread():
    """在守护进程**内部**用线程跑代理。

    3.0.5 的教训：安装/升级回调环境里 Python 的 subprocess.Popen 会报 PermissionError(13)，
    连"自己拉起自己"都做不到（日志实证：代理启动失败：PermissionError(13)）。因此守护与代理
    合并成一个进程：守护循环负责自愈，代理是其内部线程 —— 既不受 Popen 限制，也没有子进程
    孤儿问题。
    """
    load_conf()
    try:
        srv = _bind_listen()
    except Exception as e:
        log("代理监听失败：%r" % (e,))
        return False
    t = threading.Thread(target=_accept_loop, args=(srv,), daemon=True)
    t.start()
    SERVER["srv"] = srv
    SERVER["thread"] = t
    try:
        with open(CHILD_PID, "w") as f:
            f.write(str(os.getpid()))
        with open(VER_FILE, "w") as f:
            f.write(VERSION)
    except Exception:
        pass
    log("代理已监听 %s -> %s:%d tls=%s prefix=%s 版本=%s（守护进程内线程）" % (
        SOCK_PATH, UPSTREAM_HOST, UPSTREAM_PORT, USE_TLS, PREFIX, VERSION))
    return True


def _drop_privileges():
    """3.6.5：安装回调以root运行时，降权到应用用户 docker-androidemu，避免审核风险。
    仅在uid=0且目标用户存在时降权；非root环境直接跳过。"""
    try:
        if os.getuid() != 0:
            return False
        import pwd
        try:
            pw = pwd.getpwnam("docker-androidemu")
        except KeyError:
            try:
                pw = pwd.getpwnam("trim")
            except KeyError:
                log("降权跳过：未找到 docker-androidemu 或 trim 用户")
                return False
        target_uid, target_gid = pw.pw_uid, pw.pw_gid
        # 3.7.0：获取目标用户的所有附加组（包括docker组），不能清空，否则无法访问docker.sock
        import grp
        extra_groups = [g.gr_gid for g in grp.getgrall() if pw.pw_name in g.gr_mem]
        if target_gid not in extra_groups:
            extra_groups.append(target_gid)
        # 先设置附加组，再设置gid，最后设置uid（顺序不能反）
        try:
            os.setgroups(extra_groups)
        except Exception:
            try:
                os.setgroups([])
            except Exception:
                pass
        os.setgid(target_gid)
        os.setuid(target_uid)
        os.environ["HOME"] = pw.pw_dir
        os.environ["USER"] = pw.pw_name
        log("已降权到用户 %s (uid=%d, gid=%d)" % (pw.pw_name, target_uid, target_gid))
        return True
    except Exception as e:
        log("降权失败：%r（继续以当前用户运行）" % (e,))
        return False


def supervise():
    """守护循环：只保证"自己拉起的那个代理"存活，并清理上一版残留；绝不按名字杀别人的进程。"""
    # 3.6.5：安装回调以root启动时自动降权
    _drop_privileges()
    import fcntl
    lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except Exception:
        log("已有网关守护在运行（锁被占用），本进程退出以避免互掐")
        return 0
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))
    try:
        var_id = (os.stat(VAR_DIR).st_ino, os.stat(VAR_DIR).st_dev)
    except Exception:
        var_id = None
    log("守护启动 pid=%d 版本=%s 检查间隔 %ds" % (os.getpid(), VERSION, INTERVAL))
    if not start_server_thread():
        log("守护启动后代理未能监听，将在循环内重试")
    _last_audio = 0.0
    while True:
        try:
            cur = (os.stat(VAR_DIR).st_ino, os.stat(VAR_DIR).st_dev)
        except Exception:
            cur = None
        if var_id and cur != var_id:
            # 应用被卸载/重装：数据目录已被替换，立即退出，绝不与新实例抢 socket
            log("数据目录已不存在或已被替换（应用已卸载/重装），本守护退出")
            return 0
        # 清理上一版/重复的守护（只本用户、只本应用路径；保留自己，绝不按名字群杀）
        sweep(keep=(os.getpid(),))
        if not server_alive() or not os.path.exists(SOCK_PATH) or not ver_ok():
            try:
                if SERVER.get("srv"):
                    SERVER["srv"].close()
            except Exception:
                pass
            SERVER["thread"] = None
            start_server_thread()
            time.sleep(1)
            if probe_once():
                log("校验通过：%s 可服务（%s/）" % (SOCK_PATH, PREFIX))
            else:
                log("警告：%s 尚不可服务，下一轮重试（详见 %s）" % (SOCK_PATH, LOG_FILE))
        ### 3.0.3：顺带看住音频守护 —— 容器重建或守护异常退出后自动补起，
        ### 避免 media_codecs.xml 里的 Opus 声明丢失导致开音频就断流。
        ### （最多每 60 秒尝试一次；音频守护自身每 30 秒复查一次声明。）
        if os.path.exists(DAEMON_SH) and not audio_watchdog_ok():
            if time.time() - _last_audio > 60:
                _last_audio = time.time()
                try:
                    subprocess.Popen(["bash", DAEMON_SH, "start"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     stdin=subprocess.DEVNULL, start_new_session=True,
                                     cwd="/", env=dict(os.environ))
                    log("统一守护进程未在运行，已尝试拉起（Go版本，音频+分辨率）")
                except Exception as e:
                    log("统一守护进程拉起失败：%r" % (e,))
        time.sleep(INTERVAL)


def start():
    load_conf()
    d = daemon_pid()
    if d and ver_ok() and os.path.exists(SOCK_PATH):
        # 入口健康时不重启（重启即掐断在线会话），但清理上一版残留
        extra = [p for p in our_pids() if p != d]
        if not extra:
            print("gateway: 运行中（守护 %d，代理随守护同进程，版本 %s），无需重启" % (d, VERSION))
            return 0
        log("发现残留网关进程：%s（清理后保持当前入口不中断）" % " ".join(map(str, extra)))
        sweep(keep=(d,))
        print("gateway: 运行中（守护 %d，版本 %s），已清理上一版残留进程" % (d, VERSION))
        return 0
    if d:
        kill_pid(d)
    sweep()
    for p in (PID_FILE, CHILD_PID, VER_FILE):
        try:
            os.remove(p)
        except Exception:
            pass
    # 直接拉起守护；cwd 用 "/" —— 安装/升级回调环境里工作目录可能不可达，
    # 会让 subprocess 报 PermissionError(13)（实测）。真起不来时由薄壳 gw_socket.sh
    # 用 bash 原生 nohup+setsid 兜底（安装/升级回调走的就是薄壳）。
    logf = open(LOG_FILE, "a")
    env = dict(os.environ)
    env.update({"TRIM_APPDEST": APP_DEST, "TRIM_PKGVAR": VAR_DIR})
    try:
        subprocess.Popen([sys.executable, SELF, "supervise"], stdout=logf, stderr=subprocess.STDOUT,
                         cwd="/", start_new_session=True, env=env)
    except Exception as e:
        print("gateway: 守护启动失败：%r（可改用 scripts/gw_socket.sh start 兜底）" % (e,))
        return 1
    time.sleep(4)
    if os.path.exists(SOCK_PATH) and daemon_pid():
        print("gateway: 网关入口就绪：%s → 127.0.0.1:%d（上游 %s，前缀 %s，版本 %s）" % (
            SOCK_PATH, UPSTREAM_PORT, "TLS" if USE_TLS else "明文", PREFIX, VERSION))
        return 0
    print("gateway: 已启动守护但入口尚未就绪（详见 %s）" % LOG_FILE)
    return 1


def stop():
    killed = []
    for _ in range(2):          # 守护与代理已同进程；仍循环一次以兼容旧版双进程实例
        d = daemon_pid()
        if not d:
            break
        kill_pid(d)
        killed.append(d)
        time.sleep(0.3)
    # 连"数据目录被清空而失去 PID 记录"的上一版残留一并收干净
    sweep()
    for p in (PID_FILE, CHILD_PID, VER_FILE, SOCK_PATH):
        try:
            os.remove(p)
        except Exception:
            pass
    log("守护与代理已停止（%s）" % (" ".join(map(str, killed)) or "无进程"))
    print("gateway: 已停止")
    return 0


def status():
    d = daemon_pid()
    alive = server_alive()
    print("守护: %s" % ("running (pid %d)" % d if d else "not running"))
    if d:
        print("代理: running（与守护同进程 pid %d）" % d)
    else:
        print("代理: not running")
    print("socket: %s (%s)" % ("就绪" if os.path.exists(SOCK_PATH) else "未就绪", SOCK_PATH))
    try:
        with open(VER_FILE) as f:
            v = f.read().strip()
    except Exception:
        v = "-"
    print("版本: %s（本脚本 %s）" % (v, VERSION))
    print("上游: 127.0.0.1:%d（%s），路径前缀 %s" % (
        UPSTREAM_PORT, "TLS（自签证书不校验）" if USE_TLS else "明文 HTTP", PREFIX))
    others = [p for p in our_pids() if p != d]
    print("本应用网关进程: 守护 %s（代理同进程）%s" % (
        d or "无",
        ("；上一版残留 %s（可执行 restart 清理）" % " ".join(map(str, others))) if others else ""))
    return 0


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if action == "serve":
        serve()
    elif action == "supervise":
        sys.exit(supervise())
    elif action == "start":
        sys.exit(start())
    elif action == "stop":
        sys.exit(stop())
    elif action == "restart":
        stop()
        sys.exit(start())
    elif action == "status":
        sys.exit(status())
    elif action == "probe":
        if probe_once():
            print("gateway: 探活通过（%s 可服务 %s/）" % (SOCK_PATH, PREFIX))
            sys.exit(0)
        print("gateway: 探活失败（详见 %s）" % LOG_FILE)
        sys.exit(1)
    else:
        print("用法：%s {serve|start|stop|restart|status|supervise|probe}" % sys.argv[0])
        sys.exit(1)


if __name__ == "__main__":
    main()
