#!/bin/bash
### audio_watchdog.sh — 兼容外壳（3.0.3 起；3.0.5 起带 bash 启动兜底）
###
### 旧版为 bash 实现的音频守护（周期性把 Opus 编码器声明补回 redroid 容器的 media_codecs.xml）；
### 3.0.3 起改由 scripts/androidemu_daemon.sh 实现（纯 Python 改 XML、PID 身份校验、不用 pkill）。
### 保留本文件名与参数（start|stop|status|fix），供 start_pull_bg.sh 与 cmd/* 回调继续调用。
###
### 3.0.5（ARM 实测）：安装/升级回调的运行环境里 Python subprocess.Popen 会报
### PermissionError(13)（安装日志实证），导致"安装期拉起的音频守护"失败。故 start 做兜底：
### Python 入口没起来时，用 bash 原生 nohup + setsid 直接拉起 watchdog（2.x 的稳定做法）。
set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
PY="$APP_DIR/scripts/androidemu_daemon.sh"
ACT="${1:-start}"

if [ ! -f "$PY" ]; then
    echo "audio_watchdog: 缺少音频模块：$PY" >&2
    exit 1
fi

running() {
    # 只看"本用户自己的"常驻进程：别的用户（例如历史测试遗留）跑的同类进程不算数，
    # 否则会误判为"已在运行"而跳过兜底启动（x86 真机实测过这个问题）。
    local me; me=$(id -un)
    ps -eo user=,args 2>/dev/null | awk -v u="$me" '$1==u' | grep -E 'audio_fix\.py (watchdog|start)' | grep -v grep >/dev/null 2>&1
}

case "$ACT" in
    start)
        python3 "$PY" start || true
        if ! running; then
            echo "audio_watchdog: Python 入口未能拉起守护，改用 bash nohup/setsid 兜底"
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
