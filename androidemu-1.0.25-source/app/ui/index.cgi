#!/bin/bash
### 安卓模拟器（国内版）控制面板 (CGI entry)。
### 功能：一键拉取镜像、后台拉取实时进度条 + 预计剩余时间（ETA）、缺镜像时打开面板自动后台拉取、
###       云手机画面入口（动态当前 IP，支持多设备统一远程操控）、复制 ADB 命令（动态当前 IP）。
### Docs: https://developer.fnnas.com/docs/core-concepts/index-cgi/
### TRIM_* env vars are NOT available in CGI context — paths hardcoded.

exec 2>/dev/null

### CGI 环境默认 PATH 往往不含 docker，必须先补齐，否则拉取/状态会异常
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

APP_DIR="/var/apps/androidemu/target"
VAR_DIR="/var/apps/androidemu/var"
PULL_LOG="${VAR_DIR}/pull.log"
PULL_PID="${VAR_DIR}/pull.pid"
PROGRESS_LOG="${VAR_DIR}/pull-progress.log"
ETA_STATE="${VAR_DIR}/eta.state"
REDROID_IMG="redroid/redroid:12.0.0-latest"
REDROID_NAME="androidemu-android"
WEBRTC_NAME="androidemu-webrtc"

mkdir -p "$VAR_DIR"

### ---- is a background pull already running? ----------------------------
PULLING=0
if [ -f "$PULL_PID" ] && kill -0 "$(cat "$PULL_PID" 2>/dev/null)" 2>/dev/null; then
    PULLING=1
fi

### ---- image present? ----------------------------------------------------
IMG_OK=0
docker image inspect "$REDROID_IMG" >/dev/null 2>&1 && IMG_OK=1

### ---- start_pull: 后台拉取（不阻塞），复用统一脚本，进度写入 PROGRESS_LOG
start_pull() {
    bash "${APP_DIR}/scripts/start_pull_bg.sh" 2>/dev/null || true
    PULLING=1
}

### ---- Handle API / one-click pull --------------------------------------
case "${QUERY_STRING}" in
    *action=pull*)
        if [ "$IMG_OK" = "0" ] && [ "$PULLING" = "0" ]; then
            start_pull
        fi
        echo "Status: 302 Found"
        echo "Location: /cgi/ThirdParty/androidemu/index.cgi/"
        echo ""
        exit 0
        ;;
    *action=pull_status*)
        if [ "$IMG_OK" = "1" ]; then
            echo '{"state":"done","percent":100,"done":0,"total":0,"eta":0,"log":""}'
            exit 0
        fi
        if [ "$PULLING" = "0" ]; then
            echo '{"state":"idle","percent":0,"done":0,"total":0,"eta":0,"log":""}'
            exit 0
        fi
        read P D T < <(bash "${APP_DIR}/scripts/pull_progress.sh" "$PROGRESS_LOG" 2>/dev/null)
        P="${P:--1}"; D="${D:-0}"; T="${T:-0}"
        ETA=0
        if [ -f "$ETA_STATE" ]; then
            read PREV_EPOCH PREV_DONE < "$ETA_STATE"
            NOW=$(date +%s)
            DT=$((NOW - PREV_EPOCH))
            if [ "$DT" -gt 0 ] && [ "$D" -gt "$PREV_DONE" ] 2>/dev/null; then
                SPD=$(( (D - PREV_DONE) / DT ))
                if [ "$SPD" -gt 0 ] && [ "$T" -gt "$D" ]; then
                    ETA=$(( (T - D) / SPD ))
                fi
            fi
        fi
        echo "$(date +%s) $D" > "$ETA_STATE"
        STATE=pulling
        [ "$P" = "-1" ] && STATE=unknown
        [ "$P" = "100" ] && STATE=done
        LOGTAIL=$(tail -n 3 "$PULL_LOG" 2>/dev/null | sed 's/"/\\"/g' | tr '\n' ' ')
        echo "Content-Type: application/json; charset=utf-8"
        echo ""
        echo "{\"state\":\"$STATE\",\"percent\":$P,\"done\":$D,\"total\":$T,\"eta\":$ETA,\"log\":\"$LOGTAIL\"}"
        exit 0
        ;;
esac

### ---- 打开面板时若缺镜像且未在拉取，自动后台拉取（安装不阻塞） ----------
if [ "$IMG_OK" = "0" ] && [ "$PULLING" = "0" ]; then
    start_pull
fi

### ---- 进度条区块（拉取中或镜像缺失时显示） ----------------------------
PROG_HTML=""
if [ "$PULLING" = "1" ] || [ "$IMG_OK" = "0" ]; then
    NEED_PROG=1
    PROG_HTML='<div style="margin:4px 0 14px">
  <div style="height:12px;background:#0f172a;border-radius:8px;overflow:hidden;box-shadow:inset 0 1px 3px rgba(0,0,0,.4)">
    <div id="progFill" style="height:100%;width:0%;background:linear-gradient(90deg,#3b82f6,#06b6d4,#22c55e);border-radius:8px;transition:width .6s ease"></div>
  </div>
  <div id="progText" style="font-size:12px;color:#94a3b8;margin-top:6px">正在获取进度…</div>
</div>'
else
    NEED_PROG=0
fi

PULL_BTN=""
if [ "$IMG_OK" = "0" ]; then
    if [ "$PULLING" = "1" ]; then
        PULL_BTN='<a class="btn secondary" href="javascript:void(0)" style="opacity:.6;cursor:default">镜像拉取进行中…（本页实时显示进度）</a>'
    else
        PULL_BTN='<a class="btn primary" href="/cgi/ThirdParty/androidemu/index.cgi/?action=pull">一键拉取镜像</a>'
    fi
fi

LOG_HTML=""
if [ -f "$PULL_LOG" ]; then
    LOG_LINES=$(tail -n 5 "$PULL_LOG" | sed 's/</\&lt;/g')
    [ -n "$LOG_LINES" ] && LOG_HTML="<pre style='background:#0f172a;border-radius:8px;padding:10px;font-size:12px;color:#cbd5e1;white-space:pre-wrap;margin-top:14px'>${LOG_LINES}</pre>"
fi

echo "Content-Type: text/html; charset=utf-8"
echo "Cache-Control: no-store"
echo ""

cat <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>安卓模拟器（国内版）</title>
<style>
  *{box-sizing:border-box}
  body{margin:0;font-family:"PingFang SC","Microsoft YaHei",sans-serif;color:#e2e8f0;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:16px;background:linear-gradient(135deg,#0b1120 0%,#0f172a 45%,#16263f 100%)}
  .card{background:rgba(30,41,59,.85);backdrop-filter:blur(6px);border:1px solid rgba(255,255,255,.06);border-radius:20px;padding:30px;width:480px;max-width:100%;box-shadow:0 12px 40px rgba(0,0,0,.45)}
  h1{font-size:21px;margin:0 0 4px;background:linear-gradient(90deg,#60a5fa,#22d3ee);-webkit-background-clip:text;background-clip:text;color:transparent}
  .sub{color:#94a3b8;font-size:13px;margin-bottom:20px}
  .status{display:flex;align-items:center;gap:10px;font-size:14px;margin-bottom:10px;padding:10px 12px;border-radius:12px;background:rgba(15,23,42,.45);border:1px solid rgba(255,255,255,.05)}
  .dot{width:10px;height:10px;border-radius:50%;display:inline-block;flex:none;box-shadow:0 0 8px currentColor}
  .status .name{flex:1}
  .badge{font-size:12px;padding:3px 10px;border-radius:999px;font-weight:600}
  .btn{display:block;width:100%;padding:13px;border-radius:12px;border:none;font-size:15px;cursor:pointer;margin-bottom:10px;text-align:center;text-decoration:none;font-weight:600}
  .primary{background:linear-gradient(90deg,#3b82f6,#06b6d4);color:#fff;box-shadow:0 4px 16px rgba(59,130,246,.35)}
  .primary:hover{filter:brightness(1.08)}
  .secondary{background:#334155;color:#e2e8f0}
  .secondary:hover{background:#3b4a63}
  .tips{font-size:12px;color:#94a3b8;line-height:1.9;margin-top:16px;border-top:1px solid rgba(255,255,255,.08);padding-top:12px;word-break:break-all}
  code{background:#0f172a;padding:2px 6px;border-radius:4px;font-size:12px;color:#7dd3fc}
  @media (max-width:480px){.card{padding:20px}}
</style>
</head>
<body>
<div class="card">
  <h1>安卓模拟器（国内版）</h1>
  <div class="sub">Redroid 容器 · GPU 直通 · 浏览器云手机画面（支持多设备统一远程操控）</div>
  ${PROG_HTML}
  ${PULL_BTN}
  <a class="btn primary" id="openWeb" href="#" target="_blank" rel="noopener">打开云手机画面（电脑/手机自适应）</a>
  <a class="btn secondary" href="javascript:void(0)" onclick="copyAdb()">复制 ADB 连接命令</a>
  ${LOG_HTML}
  <div class="tips">
    · 安装不阻塞：安装完成后自动在后台拉取容器镜像（约 2GB，优先 DaoCloud 免注册加速源，失败自动回退 Docker Hub 官方仓库），上方进度条实时显示进度与预计剩余时间，拉完自动启动容器<br>
    · 打开云手机画面：不仅可操控本机内置的安卓模拟器，还支持通过「穿云投屏 Agent」接入多台安卓设备 / 真机，在浏览器中统一远程操控、多设备矩阵管理（详见使用手册「穿云投屏接入安卓设备」章节）<br>
    · 云手机画面默认走 HTTPS：<code id="webUrl"></code>，首次访问浏览器提示证书时选择继续即可（自签证书）<br>
    · 画面服务的登录账号以镜像文档说明为准<br>
    · 电脑 ADB / Scrcpy：<code id="adbCmd"></code><br>
    · 若拉取失败，请在飞牛 Docker 设置中配置镜像加速器（registry-mirrors）后，回到本页会自动重试<br>
    · 本页面每 3 秒自动刷新拉取进度，拉取完成后自动启动容器
  </div>
  <div class="tips" style="margin-top:10px">
    · 免责声明：本应用为非官方第三方应用，按"现状"提供，使用风险自负；上游组件出处与许可状态详见包内 LICENSE 文件。
  </div>
</div>
<script>
  var host = location.hostname;
  document.getElementById('openWeb').href = 'https://' + host + ':8443';
  document.getElementById('webUrl').innerText = 'https://' + host + ':8443';
  document.getElementById('adbCmd').innerText = 'adb connect ' + host + ':5556';
  function copyAdb(){
    var t = 'adb connect ' + host + ':5556';
    if (navigator.clipboard) { navigator.clipboard.writeText(t); alert('已复制：' + t); }
    else { prompt('请手动复制：', t); }
  }
  function fmtBytes(n){
    if(!n||n<=0) return '0 B';
    var u=['B','KB','MB','GB']; var i=0; var v=n;
    while(v>=1024&&i<3){v/=1024;i++;}
    return v.toFixed(1)+' '+u[i];
  }
  function fmtEta(s){
    if(!s||s<=0) return '';
    if(s<60) return '约 '+s+' 秒';
    var m=Math.floor(s/60), ss=s%60;
    return '约 '+m+' 分'+(ss>0?' '+ss+' 秒':'');
  }
  var needProg = ${NEED_PROG};
  if(needProg){
    var bar=document.getElementById('progFill'), tx=document.getElementById('progText');
    setInterval(function(){
      fetch('index.cgi/?action=pull_status').then(function(r){return r.json();}).then(function(d){
        if(d.state==='done'){
          bar.style.width='100%';
          tx.innerText='镜像就绪，正在启动容器…';
          setTimeout(function(){location.reload();},4000);
          return;
        }
        if(d.state==='idle'){
          tx.innerText='准备开始拉取…';
          return;
        }
        var p=(d.percent>0)?d.percent:0;
        bar.style.width=p+'%';
        var s='已下载 '+fmtBytes(d.done);
        if(d.total>0) s+=' / '+fmtBytes(d.total)+'（'+p+'%）';
        if(d.state==='unknown') s+=' · 正在解析进度';
        if(d.eta>0) s+=' · 预计还需 '+fmtEta(d.eta);
        tx.innerText=s;
      }).catch(function(){});
    },3000);
  }
</script>
</body>
</html>
HTML
