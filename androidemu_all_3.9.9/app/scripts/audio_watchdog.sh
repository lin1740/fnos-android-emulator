#!/bin/bash
### audio_watchdog.sh — 音频守护进程（3.8.9 修复版）
###
### 周期性检查并补回 Opus 编码器（容器重启后 debug.stagefright.ccodec 会重置为 0）。
set -u
### 3.9.9-r2：补齐常用系统目录（安装回调 PATH 常不完整），保证 python3/ps 可用。
case ":${PATH:-}:" in
    *:/usr/sbin:*) ;;
    *) export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/sbin:/sbin" ;;
esac
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
PY="$APP_DIR/server/audio_fix.py"
ACT="${1:-start}"

if [ ! -f "$PY" ]; then
    echo "audio_watchdog: 缺少音频模块：$PY" >&2
    exit 1
fi

running() {
    ### 3.9.2 修正：按「本应用 audio_fix.py 的完整路径」匹配，不再按当前用户名过滤。
    ### 原写法只认与脚本同用户的进程，而守护会降权到应用用户（docker-androidemu），
    ### 于是系统身份视角永远"看不见"已在运行的守护 → 误报"未能拉起"并反复再起一个
    ### （实测 NAS/ARM 每次安装都打两条告警）。
    ps -eo args 2>/dev/null | grep -F "audio_fix.py" | grep -E ' (watchdog|start)( |$)' | grep -v grep >/dev/null 2>&1
}

case "$ACT" in
    start)
        ### 3.9.9-r2：飞牛安装回调环境里 Python 的 subprocess.Popen 会直接抛
        ### PermissionError(13)（3.0.5 ARM 实测，x86 全新安装同样复现），
        ### 这是平台限制而非属主问题，外层 bash 兜底能稳定拉起同一个 watchdog。
        ### 这里把 Python 入口的输出收进自己的日志，避免 install.log 里出现
        ### 「音频守护启动失败」这种看似致命、实际已自愈的告警。
        python3 "$PY" start >>"$VAR_DIR/audio_fix.log" 2>&1 || true
        if ! running; then
            echo "audio_watchdog: 安装期 Popen 受限，改用 bash nohup/setsid 兜底"
            mkdir -p "$VAR_DIR" 2>/dev/null || true
            nohup setsid python3 "$PY" watchdog >>"$VAR_DIR/audio_fix.log" 2>&1 &
            sleep 2
            if running; then
                echo "audio_watchdog: 音频守护已启动（bash 兜底）"
            else
                echo "audio_watchdog: 兜底启动后仍未就绪，详见 $VAR_DIR/audio_fix.log" >&2
                exit 1
            fi
        fi
        ;;
    *)
        exec python3 "$PY" "$ACT"
        ;;
esac
exit 0
