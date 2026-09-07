#!/bin/bash
### Shared helper: ensure the redroid / webrtc images are present.
###
### Pull order:
###   1) Daocloud free mirror (docker.m.daocloud.io) FIRST — no registration
###      needed, fastest for mainland-China networks (verified in its
###      whitelist: allows.txt contains redroid & scrcpy-over-webrtc).
###   2) Docker Hub OFFICIAL registry as automatic fallback.
### The final image name is always the official one, so compose stays clean.
### If both fail, tell the user to configure a registry mirror in the fnOS
### Docker settings.
###
### NOTE (2026-09-03): no built-in third-party sources other than Daocloud;
### campus mirrors (Tsinghua / USTC) stopped syncing Docker Hub in 2024-2026.

REDROID_IMG="redroid/redroid:12.0.0-latest"
WEBRTC_IMG="buutuu/scrcpy-over-webrtc:latest"
DAO_REDROID="docker.m.daocloud.io/redroid/redroid:12.0.0-latest"
DAO_WEBRTC="docker.m.daocloud.io/buutuu/scrcpy-over-webrtc:latest"

### 低优先级拉取：docker pull 以「空闲级 IO + 低 CPU 优先级」运行，
### 避免拉取约 2GB 镜像时占满系统资源导致 NAS 网页服务超时断连。
### ionice/nice 为 util-linux / coreutils 自带，无则自动跳过。
PULL_NICE=""
if command -v ionice >/dev/null 2>&1; then PULL_NICE="ionice -c 3"; fi
if command -v nice >/dev/null 2>&1; then PULL_NICE="$PULL_NICE nice -n 19"; fi

pull_docker() {
    # shellcheck disable=SC2086
    if [ -n "$PROGRESS_LOG" ]; then
        # 进度条模式：--progress=plain 便于解析，输出同时写进度日志
        timeout 600 $PULL_NICE docker pull --progress=plain "$@" 2>&1 | tee -a "$PROGRESS_LOG"
        return ${PIPESTATUS[0]}
    fi
    timeout 600 $PULL_NICE docker pull "$@"
}

pull_with_fallback() {
    local PRIM="$1" SEC="$2" OFFICIAL="$3" NAME="$4"
    docker image inspect "$OFFICIAL" >/dev/null 2>&1 && return 0
    echo "[$(date '+%F %T')] 优先尝试免注册加速源（DaoCloud）：$PRIM"
    if pull_docker "$PRIM"; then
        [ "$PRIM" != "$OFFICIAL" ] && docker tag "$PRIM" "$OFFICIAL"
        echo "[$(date '+%F %T')] 镜像就绪（DaoCloud 加速）：$OFFICIAL"
        return 0
    fi
    echo "[$(date '+%F %T')] 加速源失败，切换 Docker Hub 官方仓库：$SEC"
    if pull_docker "$SEC"; then
        echo "[$(date '+%F %T')] 镜像就绪（官方仓库）：$OFFICIAL"
        return 0
    fi
    echo "[$(date '+%F %T')] 加速源与官方仓库均失败（$NAME）。"
    echo "        请在飞牛 Docker 设置中配置镜像加速器（registry-mirrors）后，"
    echo "        再到应用页面点「一键拉取镜像」重试。"
    return 1
}

ensure_redroid_image() {
    pull_with_fallback "$DAO_REDROID" "$REDROID_IMG" "$REDROID_IMG" "Redroid Android 系统镜像"
}

ensure_webrtc_image() {
    pull_with_fallback "$DAO_WEBRTC" "$WEBRTC_IMG" "$WEBRTC_IMG" "WebRTC 云手机画面服务镜像"
}
