#!/usr/bin/env python3
"""
androidemu 3.9.2 音频修复模块（纯 Python 实现）

根本原因：redroid 镜像默认设置 debug.stagefright.ccodec=0，禁用了 Codec2 框架，
导致所有 c2.android.* 软件编码器（包括 c2.android.opus.encoder）都不会加载，
只有 OMX.google.* 编码器可用。穿云投屏开启音频时需要 Opus 编码器，因此连接失败。

做法：在 redroid 容器内设置 debug.stagefright.ccodec=1 和 debug.stagefright.c2software=1，
然后重启 media.swcodec/media 服务令其生效；另有一个守护进程周期性（默认 30 秒）
检查并补回（容器重启后属性会重置）。

3.0.3 相对 3.0.2 的修复：
  ① 不再用容器内的 sed 打补丁 —— 实测容器内是 toybox sed（非 GNU），
     `sed -i '/<Encoders>/a\\ 多行…'` 这类 GNU 方言不可靠；改为 Python 读回整个文件、
     用正则精确增删、再整体写回，行为与 sed 方言无关。
  ② 写入失败（/vendor 只读）时自动尝试 `mount -o remount,rw /vendor` 后重试，并把结论写日志/状态文件。
  ③ 去重按"完整 MediaCodec 块"处理，不再按行号 +4 猜测块边界（原实现删错行的风险）。
  ④ 守护/停止改用 PID 文件 + /proc/<pid>/cmdline 身份校验，不依赖 pkill（ARM 上实测该设备无 pkill）。
  ⑤ 状态落盘 audio.status，便于面板/诊断读取；守护间隔 120s → 30s（可用环境变量覆盖）。

用法：audio_fix.py {fix|watchdog|start|stop|status}
"""
import os
import re
import sys
import time
import fcntl
import signal
import subprocess

VERSION = "3.9.3"

VAR_DIR = os.environ.get("TRIM_PKGVAR", "/var/apps/androidemu/var")
CONTAINER = os.environ.get("CNAME", "androidemu-android")
XML_PATH = os.environ.get("AUDIO_XML", "/vendor/etc/media_codecs.xml")
BAK_PATH = XML_PATH + ".androidemu.bak"
CODEC = "c2.android.opus.encoder"

LOG_FILE = os.path.join(VAR_DIR, "audio_fix.log")
PID_FILE = os.path.join(VAR_DIR, "audio_watchdog.pid")
LOCK_FILE = os.path.join(VAR_DIR, ".audio.lock")
STATUS_FILE = os.path.join(VAR_DIR, "audio.status")

try:
    INTERVAL = int(os.environ.get("AUDIO_CHECK_INTERVAL", "30") or 30)
except Exception:
    INTERVAL = 30

CODEC_BLOCK = (
    '        <MediaCodec name="c2.android.opus.encoder" type="audio/opus">\n'
    '            <Limit name="channel-count" max="2" />\n'
    '            <Limit name="sample-rate" ranges="8000-48000" />\n'
    '            <Limit name="bitrate" range="6000-510000" />\n'
    '        </MediaCodec>\n'
)

BLOCK_RE = re.compile(
    r'[ \t]*<MediaCodec\b[^>]*name\s*=\s*"%s"[\s\S]*?</MediaCodec>[ \t]*\n?' % re.escape(CODEC))
COUNT_RE = re.compile(re.escape(CODEC))

try:
    os.makedirs(VAR_DIR, exist_ok=True)
except Exception:
    pass

# ---------------------------------------------------------------- 基础

def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write("[%s] %s\n" % (time.strftime("%F %T"), msg))
    except Exception:
        pass

def set_status(ok, msg):
    try:
        with open(STATUS_FILE, "w") as f:
            f.write("OK=%s\nMSG=%s\nTS=%d\nVER=%s\n" % ("1" if ok else "0", msg, int(time.time()), VERSION))
    except Exception:
        pass

def dsh(cmd, stdin=None, timeout=30):
    """在容器内以系统身份执行命令。返回 (rc, stdout, stderr)。"""
    try:
        r = subprocess.run(["docker", "exec", "-i", "-u", "0", CONTAINER, "sh", "-c", cmd],
                           input=stdin, capture_output=True, timeout=timeout)
        return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
    except Exception as e:
        return -1, "", str(e)

def container_running():
    rc, out, _ = dsh("echo ok", timeout=10)
    return rc == 0 and "ok" in out

def read_remote(path):
    try:
        r = subprocess.run(["docker", "exec", "-u", "0", CONTAINER, "cat", path],
                           capture_output=True, timeout=30)
        if r.returncode != 0:
            return None
        return r.stdout
    except Exception:
        return None

def write_remote(path, data):
    """把 bytes 整体写回容器内文件（不经过 sed）。"""
    rc, _, err = dsh("cat > %s" % path, stdin=data, timeout=30)
    if rc != 0:
        return False, err.strip()
    return True, ""

def file_exists(path):
    rc, _, _ = dsh("[ -f %s ]" % path, timeout=10)
    return rc == 0

def lib_exists():
    rc, _, _ = dsh("[ -e /system/lib64/libcodec2_soft_opusenc.so ] || "
                   "[ -e /system/apex/com.android.media.swcodec/lib64/libcodec2_soft_opusenc.so ] "
                   "|| [ -e /system/lib/libcodec2_soft_opusenc.so ]", timeout=10)
    return rc == 0

def platform_sdk():
    """容器内 Android SDK 版本（取不到返回 0）。仅用于把"不适用"讲清楚。"""
    rc, out, _ = dsh("getprop ro.build.version.sdk", timeout=10)
    try:
        return int(out.strip())
    except Exception:
        return 0

def codec2_platform():
    """3.8.9：判断本平台是否使用 Codec2 框架（Codec2 自 Android 10 / API 29 引入并逐步成为默认）。
    这是**能力判断**而非"按版本打补丁"：取不到 SDK 时退化为能力探测（有 Codec2 库/属性即视为适用）。
    目的：在 Android 9 等 OMX 平台上明确说明"本项不适用"，而不是报成"缺少 Opus 编码器库"造成误导。"""
    sdk = platform_sdk()
    if sdk:
        return sdk >= 29
    rc, out, _ = dsh("getprop ro.media.codec2; getprop debug.stagefright.ccodec; "
                     "ls /system/lib64/libcodec2* 2>/dev/null", timeout=10)
    return bool(out.strip())

def codec_count(text):
    return len(COUNT_RE.findall(text))

def insert_block(text):
    """把声明插到 <Encoders> 段末尾（找不到就退到 </MediaCodecs> 之前）。"""
    for anchor in ("</Encoders>", "</MediaCodecs>", "</media_codecs>"):
        i = text.find(anchor)
        if i >= 0:
            line_start = text.rfind("\n", 0, i) + 1
            return text[:line_start] + CODEC_BLOCK + text[line_start:]
    # 最后兜底：插到根元素结束前
    i = text.rfind("</")
    if i >= 0:
        line_start = text.rfind("\n", 0, i) + 1
        return text[:line_start] + CODEC_BLOCK + text[line_start:]
    return text

def restart_media():
    dsh("setprop ctl.restart media.swcodec", timeout=10)
    dsh("setprop ctl.restart media", timeout=10)

# ---------------------------------------------------------------- 修复

def fix_audio(force=False):
    """执行一次音频修复（幂等）。返回 (ok, msg)。
    3.7.3：根本原因是 redroid 默认禁用 Codec2（debug.stagefright.ccodec=0），
    导致 c2.android.opus.encoder 不加载。通过 setprop 启用 Codec2 即可。
    3.9.2 热修（同步自 3.9.1）：抢不到锁时先等待重试（约 36 秒），仍抢不到则
    无锁执行。背景（x86 实测）：Python 守护与 Go 守护共用本锁且原先"抢不到即
    跳过"，容器重启后 docker exec 变慢、Go 守护持锁时间占比过高，修复永远轮
    不到执行（audio.status 连续 9 分钟停在"跳过"），media 服务不被重启，
    Opus 编码器缺失 → 开音频连接 100% 失败。修复动作均为幂等操作，
    无锁并发执行的最坏情形只是 media 被多重启一次，远优于修复无法执行。"""
    lock_fd = None
    got_lock = False
    _deadline = time.time() + 36
    while True:
        try:
            lock_fd = open(LOCK_FILE, "w")
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            got_lock = True
            break
        except Exception:
            try:
                if lock_fd:
                    lock_fd.close()
            except Exception:
                pass
            lock_fd = None
            if time.time() >= _deadline:
                break
            time.sleep(3)
    if not got_lock:
        log("音频修复锁被长期占用（另一守护可能卡住），改为无锁执行（幂等）")

    try:
        if not container_running():
            return False, "安卓容器未运行，跳过"
        if not codec2_platform():
            _sdk = platform_sdk()
            msg = ("当前 Android 平台不使用 Codec2 框架（API %s；Codec2 自 API 29 起引入），"
                   "Codec2/Opus 修复不适用，已跳过（该平台音频编码方案需按平台另行适配）" % (_sdk or "未知"))
            log(msg)
            return False, msg
        if not lib_exists():
            log("Opus 编码器库不存在，跳过")
            return False, "容器内缺少 Opus 编码器库"

        # 检查当前 CCodec 状态
        rc, ccodec_val, _ = dsh("getprop debug.stagefright.ccodec", timeout=10)
        ccodec_val = ccodec_val.strip()
        rc2, c2sw_val, _ = dsh("getprop debug.stagefright.c2software", timeout=10)
        c2sw_val = c2sw_val.strip()

        # 检查 opus 编码器是否已可用
        rc3, encoder_check, _ = dsh("dumpsys media.player 2>/dev/null | grep -A1 'audio/opus' | grep Encoder", timeout=15)
        opus_available = "c2.android.opus.encoder" in encoder_check or "OMX.google.opus.encoder" in encoder_check

        if opus_available and ccodec_val == "1" and not force:
            return True, "Opus 编码器已可用（CCodec 已启用）"

        # 启用 CCodec
        log("启用 Codec2：debug.stagefright.ccodec=1 (当前=%s), c2software=1 (当前=%s)" % (ccodec_val, c2sw_val))
        dsh("setprop debug.stagefright.ccodec 1", timeout=10)
        dsh("setprop debug.stagefright.c2software 1", timeout=10)

        # 重启 media 服务
        restart_media()
        time.sleep(3)

        # 验证
        rc4, verify, _ = dsh("dumpsys media.player 2>/dev/null | grep -A1 'audio/opus' | grep Encoder", timeout=15)
        if "c2.android.opus.encoder" in verify:
            log("Opus 编码器已启用：c2.android.opus.encoder")
            return True, "已启用 Codec2，Opus 编码器可用"
        else:
            # 备用方案：注入 media_codecs.xml 声明
            log("CCodec 启用后 opus 仍未出现，尝试备用方案（注入 media_codecs.xml）")
            return _fix_audio_xml(force)
    finally:
        if got_lock and lock_fd:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
                lock_fd.close()
            except Exception:
                pass

def _fix_audio_xml(force=False):
    """备用方案：注入 media_codecs.xml 声明（3.7.3 之前的方法）。"""
    if not file_exists(XML_PATH):
        return False, "%s 不存在" % XML_PATH
    raw = read_remote(XML_PATH)
    if raw is None:
        return False, "读取 media_codecs.xml 失败"
    text = raw.decode("utf-8", "replace")
    blocks = BLOCK_RE.findall(text)
    count = codec_count(text)
    if count == 1 and len(blocks) == 1 and not force:
        return True, "Opus 编码器声明已存在（1 条）"
    new_text = BLOCK_RE.sub("", text)
    new_text = insert_block(new_text)
    if new_text == text:
        return True, "无需改动"
    if not file_exists(BAK_PATH):
        ok, err = write_remote(BAK_PATH, raw)
        if not ok:
            log("备份 media_codecs.xml 失败：%s" % err)
    ok, err = write_remote(XML_PATH, new_text.encode("utf-8"))
    if not ok:
        dsh("mount -o remount,rw /vendor 2>/dev/null || mount -o rw,remount /vendor 2>/dev/null", timeout=15)
        ok, err = write_remote(XML_PATH, new_text.encode("utf-8"))
    if not ok:
        msg = "写入 media_codecs.xml 失败：%s" % err
        log(msg)
        return False, msg
    restart_media()
    return True, "已注入 Opus 编码器声明（备用方案）"

# ---------------------------------------------------------------- 守护进程

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

def _own(pid):
    try:
        return os.stat("/proc/%d" % pid).st_uid == os.getuid()
    except Exception:
        return False

def watchdog_pid():
    """PID 文件 + cmdline 身份校验（不依赖 pkill）。

    PID 文件缺失/过期时按命令行兜底扫描：3.0.2 及更早的守护 argv 是 `audio_fix.py start`
    （fork 出守护后父进程退出），只认 `watchdog` 会把"已在运行的旧守护"当成不存在，
    start 会重复拉起、stop 也杀不掉（x86 真机实测）。
    """
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        if pid_alive(pid) and _own(pid) and "audio_fix" in pid_cmdline(pid):
            return pid
    except Exception:
        pass
    me = os.getpid()
    try:
        entries = os.listdir("/proc")
    except Exception:
        return None
    for e in entries:
        if not e.isdigit():
            continue
        p = int(e)
        if p == me or not _own(p):
            continue
        cmd = pid_cmdline(p)
        if "audio_fix.py" not in cmd:
            continue
        if "watchdog" in cmd or " start" in cmd or cmd.endswith("start"):
            return p
    return None

def _drop_privileges():
    """3.6.5：安装回调以系统身份运行时，降权到应用用户 docker-androidemu。
    与gateway.py保持一致，避免网关降权后看不到系统账号的音频守护。
    3.9.2 热修（同步自 3.9.1）：保留目标用户的全部附加组（尤其 docker 组）——
    ARM 实测该用户主组是 AppUsers、docker 是附加组，旧实现 setgroups([]) 清空
    附加组后降权进程无法访问 docker.sock，音频守护从此永远报"容器未运行"
    （x86 该用户主组恰好是 docker 故未暴露）。与 Go 网关 3.7.0 写法对齐。"""
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
                return False
        try:
            import grp
            extra_groups = [g.gr_gid for g in grp.getgrall() if pw.pw_name in g.gr_mem]
            if pw.pw_gid not in extra_groups:
                extra_groups.append(pw.pw_gid)
            os.setgroups(extra_groups)
        except Exception:
            try:
                os.setgroups([])
            except Exception:
                pass
        os.setgid(pw.pw_gid)
        os.setuid(pw.pw_uid)
        os.environ["HOME"] = pw.pw_dir
        os.environ["USER"] = pw.pw_name
        return True
    except Exception:
        return False

def watchdog():
    _drop_privileges()
    existing = watchdog_pid()
    if existing and existing != os.getpid():
        log("已有音频守护（pid %d）在运行，本进程退出" % existing)
        return
    time.sleep(0.2 + (os.getpid() % 7) * 0.07)
    existing = watchdog_pid()
    if existing and existing != os.getpid():
        log("已有音频守护（pid %d）在运行，本进程退出" % existing)
        return
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))
    time.sleep(0.8)
    try:
        with open(PID_FILE) as f:
            owner = int(f.read().strip())
        if owner != os.getpid():
            log("检测到另一个音频守护（pid %d）已接管，本进程退出" % owner)
            return
    except Exception:
        pass
    log("音频守护启动 pid=%d（每 %d 秒检查一次，版本 %s）" % (os.getpid(), INTERVAL, VERSION))
    _idle_since = None
    while True:
        try:
            ### 3.9.3：应用停用自清 —— fnOS 停用只停容器，不调用 cmd/main stop，
            ### 旧版音频守护会一直空转。容器连续 4 分钟未运行即判定停用并退出；
            ### 启用时应用中心执行 cmd/main start 会重新拉起。
            if not container_running():
                if _idle_since is None:
                    _idle_since = time.time()
                elif time.time() - _idle_since >= 240:
                    log("主容器已停止超过 240s（判定应用停用）→ 音频守护退出")
                    try:
                        if os.path.exists(PID_FILE):
                            os.remove(PID_FILE)
                    except Exception:
                        pass
                    return
            else:
                _idle_since = None
            ok, msg = fix_audio()
            if ok:
                set_status(True, msg)
            else:
                set_status(False, msg)
        except Exception as e:
            log("守护异常：%r" % (e,))
        time.sleep(INTERVAL)

def start_watchdog():
    if watchdog_pid():
        print("音频守护已在运行")
        return 0
    try:
        os.remove(PID_FILE)
    except Exception:
        pass
    # 独立会话里拉起守护（start_new_session 断开终端；cmdline 含 audio_fix.py 以便身份校验）
    try:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "watchdog"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True,
                         env=dict(os.environ))
    except Exception as e:
        print("音频守护启动失败：%r" % e)
        return 1
    time.sleep(1.5)
    pid = watchdog_pid()
    if pid:
        print("音频守护已启动（pid %d）" % pid)
        return 0
    print("音频守护启动后未检测到进程，请查看 %s" % LOG_FILE)
    return 1

def stop_watchdog():
    pid = watchdog_pid()
    if not pid:
        try:
            os.remove(PID_FILE)
        except Exception:
            pass
        print("音频守护未在运行")
        return 0
    try:
        os.kill(pid, signal.SIGTERM)
    except Exception:
        pass
    for _ in range(15):
        if not pid_alive(pid):
            break
        time.sleep(0.1)
    if pid_alive(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
    try:
        os.remove(PID_FILE)
    except Exception:
        pass
    log("音频守护已停止")
    print("音频守护已停止")
    return 0

def status():
    pid = watchdog_pid()
    print("音频守护: %s" % ("running (pid %d)" % pid if pid else "not running"))
    print("检查间隔: %d 秒" % INTERVAL)
    print("容器: %s（%s）" % (CONTAINER, "运行中" if container_running() else "未运行"))
    try:
        with open(STATUS_FILE) as f:
            print("最近结果:\n%s" % f.read().strip())
    except Exception:
        print("最近结果: 暂无（尚未执行过修复）")
    if container_running() and file_exists(XML_PATH):
        raw = read_remote(XML_PATH) or b""
        print("Opus 声明: %d 条" % codec_count(raw.decode("utf-8", "replace")))
    return 0

def fix_with_wait(max_wait=120, interval=5):
    """执行修复，容器未启动时等待一段时间（默认最多等120秒，每5秒检查一次）。
    首次安装时容器可能还在启动，直接fix会跳过；等待后再fix能提高首次注入成功率。
    超时仍未启动则交给守护进程兜底。"""
    waited = 0
    while not container_running() and waited < max_wait:
        log("容器未运行，等待启动（已等 %d 秒，最多等 %d 秒）" % (waited, max_wait))
        print("容器未启动，等待中...（已等 %d 秒）" % waited)
        time.sleep(interval)
        waited += interval
    if not container_running():
        msg = "等待 %d 秒后容器仍未启动，跳过本次修复，交由守护进程兜底" % max_wait
        log(msg)
        return False, msg
    log("容器已启动（等待 %d 秒），开始执行修复" % waited)
    return fix_audio()

def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "fix"
    if action == "fix":
        ok, msg = fix_with_wait()
        set_status(ok, msg)
        print("音频修复：%s（%s）" % ("成功" if ok else "未完成", msg))
        sys.exit(0 if ok else 1)
    elif action == "watchdog":
        watchdog()
    elif action == "start":
        sys.exit(start_watchdog())
    elif action == "stop":
        sys.exit(stop_watchdog())
    elif action == "status":
        sys.exit(status())
    else:
        print("用法：%s {fix|watchdog|start|stop|status}" % sys.argv[0])
        sys.exit(1)

if __name__ == "__main__":
    main()
