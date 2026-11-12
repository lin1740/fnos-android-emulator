#!/bin/bash
### androidemu_supervisor.sh — 统一守护进程启动脚本（架构自适应）
### 功能：统一监控安卓容器/WebRTC容器/agent进程/音频服务，异常自动恢复，HTTP状态API
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH=$(uname -m)

case "$ARCH" in
    x86_64|amd64)
        BIN="${SCRIPT_DIR}/androidemu_supervisor_amd64"
        ;;
    aarch64|arm64)
        BIN="${SCRIPT_DIR}/androidemu_supervisor_arm64"
        ;;
    *)
        echo "不支持的架构: $ARCH" >&2
        exit 1
        ;;
esac

if [ ! -x "$BIN" ]; then
    chmod +x "$BIN" 2>/dev/null || true
fi

# 清理旧的bash守护进程（由supervisor统一管理）
for p in $(ps -eo pid,args 2>/dev/null | grep -E 'agent_autodeploy.sh.*while|webrtc_watchdog.sh.*supervise|audio_watchdog' | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null || true
done

exec "$BIN" "$@"
