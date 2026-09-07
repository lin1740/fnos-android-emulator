#!/bin/bash
### start_pull_bg.sh — 后台拉取镜像并在就绪后自动启动容器（不阻塞调用方）。
###
### 快速安装版三入口统一复用：
###   1) install_callback  安装完成后调用 → 安装秒完成，后台自动拉镜像并自动启动容器，
###      无需用户手动启用；
###   2) cmd/main start    用户点「启用」时调用 → 立即返回，不阻塞、不卡界面；
###   3) 面板 index.cgi    打开面板/点「一键拉取」时调用 → 展示实时进度条。
###
### 拉取去重：若已有后台拉取进程在跑，直接返回，避免重复拉取。

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
mkdir -p "$VAR_DIR"
PULL_LOG="${VAR_DIR}/pull.log"
PULL_PID="${VAR_DIR}/pull.pid"
PROGRESS_LOG="${VAR_DIR}/pull-progress.log"

### 已在拉取则直接返回（防止安装/启用/面板重复触发）
if [ -f "$PULL_PID" ] && kill -0 "$(cat "$PULL_PID" 2>/dev/null)" 2>/dev/null; then
    exit 0
fi

rm -f "$PROGRESS_LOG"
rm -f "${VAR_DIR}/eta.state"

nohup bash -c '
    . "'"$APP_DIR"'"/scripts/pull_image.sh
    export PROGRESS_LOG="'"$PROGRESS_LOG"'"
    if ensure_redroid_image && ensure_webrtc_image; then
        echo "[$(date +%F\ %T)] 镜像就绪，正在启动容器…"
        # 启动前放开宿主 DRM 设备权限（redroid 无 /bin/sh，GPU 直通需宿主侧 chmod）
        [ -e /dev/dri ] && chmod 666 /dev/dri/card0 /dev/dri/renderD128 2>/dev/null || true
        cd "'"$APP_DIR"'"/docker && docker compose -p androidemu up -d >/dev/null 2>&1
        # 容器内兜底：宿主 chmod 在部分机器会被重置，须容器内再 chmod + 重启渲染服务
        nohup bash "'"$APP_DIR"'"/scripts/fix_gpu_perms.sh >/dev/null 2>&1 &
        echo "[$(date +%F\ %T)] 容器已启动，安卓模拟器可用。"
    else
        echo "[$(date +%F\ %T)] 免注册加速源与官方仓库均失败，请检查飞牛网络后重试。"
    fi
' > "$PULL_LOG" 2>&1 &
echo $! > "$PULL_PID"

exit 0
