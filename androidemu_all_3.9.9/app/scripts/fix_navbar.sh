#!/bin/bash
### fix_navbar.sh — 修复系统导航条异常巨大、遮挡应用底部控件的问题
###
### 【它解决什么问题】（2026-11-09 主 NAS 实测，Android 12 / redroid）
###   该镜像 SystemUI 的全部导航栏模式 RRO overlay 均处于「禁用」状态
###   （cmd overlay list 里 gestural/threebutton 全是 [ ]），3 键导航按
###   未 overlay 的默认资源绘制：高度约为正常值的 2.4 倍，且系统报给
###   应用的底部 inset 与实际绘制高度不一致 —— 应用底部的控件（如视频
###   播放器的暂停键）被导航条直接盖住、无法点击。
###
### 【做法】幂等两步（与 Android 设置里「三键导航」等价）：
###   1) cmd overlay enable com.android.internal.systemui.navbar.threebutton
###   2) settings put secure navigation_mode 0
###   已处于目标状态时一次 docker exec 检查后直接退出，不做任何写入。
###   用户之后在系统设置里自行切换手势导航，SystemUI 会正常接管 overlay。
###
### 【用法】fix_navbar.sh [--runtime|--install]
###   宿主侧以包用户运行（boot_guard 巡检 / 安装、升级回调）；
###   通过 docker exec 进容器执行，不建 高权限常驻进程。
### 退出码恒为 0（失败不阻断启动，后续巡检会重试）。

set -u
ACTION="${1:---runtime}"
C="${AE_CONTAINER:-androidemu-android}"
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
LOG="$VAR_DIR/fix_navbar.log"
mkdir -p "$VAR_DIR" 2>/dev/null || true
if [ -f "$LOG" ] && [ ! -w "$LOG" ]; then LOG="/tmp/androidemu-fix_navbar.log"; fi
if ! ( : >> "$LOG" ) 2>/dev/null; then LOG="/tmp/androidemu-fix_navbar.log"; fi
log(){ echo "[$(date '+%F %T')] fix_navbar: $*" >>"$LOG" 2>/dev/null || true; }

### 容器必须存在且安卓已完成启动（SystemUI 未起时 cmd overlay 会失败）
if ! docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null | grep -q true; then
    exit 0
fi
_BOOTED=$(docker exec "$C" getprop sys.boot_completed 2>/dev/null | tr -d '\r')
if [ "$_BOOTED" != "1" ]; then
    exit 0
fi

### 幂等检查：overlay 已启用且模式已是 3 键 → 直接退出（每轮巡检只花一次 exec）
_ON=$(docker exec "$C" cmd overlay list 2>/dev/null | grep -c '\[x\] com.android.internal.systemui.navbar.threebutton')
_MODE=$(docker exec "$C" settings get secure navigation_mode 2>/dev/null | tr -d '\r')
if [ "$_ON" = "1" ] && [ "$_MODE" = "0" ]; then
    exit 0
fi

log "检测到导航条 overlay 未启用（threebutton=$_ON mode=$_MODE），应用修复"
docker exec "$C" cmd overlay enable com.android.internal.systemui.navbar.threebutton >>"$LOG" 2>&1 || true
docker exec "$C" cmd overlay disable com.android.internal.systemui.navbar.gestural >>"$LOG" 2>&1 || true
docker exec "$C" settings put secure navigation_mode 0 >>"$LOG" 2>&1 || true
_FINAL=$(docker exec "$C" cmd overlay list 2>/dev/null | grep -c '\[x\] com.android.internal.systemui.navbar.threebutton')
if [ "$_FINAL" = "1" ]; then
    log "修复完成：3 键导航条已恢复正常高度"
else
    log "警告：overlay 启用未生效，下一轮巡检重试"
fi
exit 0
