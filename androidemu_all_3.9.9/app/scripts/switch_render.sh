#!/bin/bash
### switch_render.sh — 手动切换渲染模式（GPU 直通 ⇄ 软件渲染）
###
### 用途：GPU 直通在个别驱动上可能出现花屏/错帧（boot_guard 会自动回退，见 gpu_artifact.done），
###   或用户想主动用软件渲染换取稳定性 / 想重新尝试 GPU 加速时使用。
###
### 用法：
###   switch_render.sh status              # 查看当前模式、回退标记与最近诊断
###   switch_render.sh software            # 切软件渲染（swiftshader，30fps/长边960）并重建容器
###   switch_render.sh gpu                 # 重新尝试 GPU 直通（清除一次性回退标记）并重建容器
###   switch_render.sh <mode> --no-restart # 只改配置不重建
set -u

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"

MODE="${1:-status}"
NO_RESTART=0
for a in "$@"; do [ "$a" = "--no-restart" ] && NO_RESTART=1; done

show_status(){
    echo "容器：$(docker inspect -f '{{.State.Status}}' androidemu-android 2>/dev/null || echo 未创建)"
    echo "--- render-mode ---"
    cat "$VAR_DIR/render-mode" 2>/dev/null || echo "(无记录)"
    echo "--- 回退标记 ---"
    [ -f "$VAR_DIR/gpu_fallback.done" ] && echo "gpu_fallback.done：曾因 GPU 直通失败回退软件渲染" || echo "gpu_fallback.done：无"
    [ -f "$VAR_DIR/gpu_artifact.done" ] && echo "gpu_artifact.done：曾因渲染异常（花屏）回退软件渲染" || echo "gpu_artifact.done：无"
    echo "--- compose 关键参数 ---"
    grep -E "androidboot\.redroid_(gpu_mode|gpu_node)|androidboot\.redroid_fps" "$COMPOSE" 2>/dev/null | sed 's/^[[:space:]]*/  /'
    echo "--- 最近诊断 ---"
    grep -E "^(TS|logcat_gpu_drm_hits|verdict)=" "$VAR_DIR/boot_diag.status" 2>/dev/null | sed 's/^/  /'
}

case "$MODE" in
    status|"") show_status; exit 0 ;;
    software|gpu) ;;
    *) echo "用法：$0 {status|software|gpu} [--no-restart]"; exit 1 ;;
esac

[ -f "$COMPOSE" ] || { echo "switch_render: compose 不存在：$COMPOSE" >&2; exit 1; }

if [ "$MODE" = "gpu" ]; then
    rm -f "$VAR_DIR/gpu_fallback.done" "$VAR_DIR/gpu_artifact.done" 2>/dev/null || true
    echo "switch_render: 已清除一次性回退标记，将重新探测 GPU 能力"
    bash "$APP_DIR/scripts/tune_compose.sh" "$COMPOSE" || true
else
    echo "switch_render: 切换到软件渲染（swiftshader）"
    bash "$APP_DIR/scripts/tune_compose.sh" --force-software "$COMPOSE" || true
fi

### 同步到 /docker（飞牛 docker-project 读取该路径）
mkdir -p /docker 2>/dev/null || true
cp -f "$COMPOSE" /docker/docker-compose.yaml 2>/dev/null || true
chmod 644 /docker/docker-compose.yaml 2>/dev/null || true

if [ "$NO_RESTART" = "1" ]; then
    echo "switch_render: --no-restart，仅改配置（下次启动生效）"
    exit 0
fi

echo "switch_render: 重建 redroid 容器使渲染模式生效（约 1~3 分钟开机）…"
( cd "$(dirname "$COMPOSE")" 2>/dev/null && docker compose -p androidemu up -d --force-recreate redroid ) 2>&1 | tail -3
echo "switch_render: 完成。用 '$0 status' 查看当前模式；boot_guard 会继续巡检渲染异常"
