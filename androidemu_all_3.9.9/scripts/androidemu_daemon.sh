#!/bin/bash
# androidemu 统一守护进程启动脚本（架构自适应，Go版本）
# 同时处理：音频修复守护 + 分辨率自动切换HTTP服务
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH=$(uname -m)

case "$ARCH" in
    x86_64|amd64)
        BIN="${SCRIPT_DIR}/androidemu_daemon_amd64"
        ;;
    aarch64|arm64)
        BIN="${SCRIPT_DIR}/androidemu_daemon_arm64"
        ;;
    *)
        echo "不支持的架构: $ARCH" >&2
        exit 1
        ;;
esac

if [ ! -x "$BIN" ]; then
    chmod +x "$BIN" 2>/dev/null || true
fi

exec "$BIN" "$@"
