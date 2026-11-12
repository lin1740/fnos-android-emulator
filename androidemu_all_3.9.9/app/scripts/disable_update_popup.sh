#!/bin/bash
### disable_update_popup.sh — 禁用穿云投屏面板的版本检查弹窗
###
### 背景：面板前端启动时向上游授权服务器（license.webrtc-phone.com）发版本检查，
###       1.5 秒后弹"当前已是最新版本/发现新版本"大弹窗占半屏。版本更新由本应用
###       发版统一管理，面板自查弹窗多余且扰人。
###
### 方案：外科手术式补丁——仅把前端 bundle 里的"版本检查"URL 改为死地址
###       （fetch 失败 → catch 静默 → 永不弹窗）。同域名的授权/激活等其他路径
###       完全不受影响。幂等：已补丁则跳过。
###
### 调用方：boot_guard 巡检（健康分支）或安装流程；容器运行时执行。
set +e
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
mkdir -p "$VAR_DIR" 2>/dev/null || true
### 3.9.2 热修：标记文件可能是早期系统身份流程建的（0:0 644），普通用户写不了 →
### 节流失效、每轮巡检都重复打补丁。不可写就退到临时目录。
_ae_wpath(){ # $1=文件名，输出一个可写的路径
    local n="$1" fb="${TMPDIR:-/tmp}/androidemu_$(id -u)"
    if [ -d "$VAR_DIR" ] && [ -w "$VAR_DIR" ] && { [ ! -e "$VAR_DIR/$n" ] || [ -w "$VAR_DIR/$n" ]; }; then
        printf '%s\n' "$VAR_DIR/$n"
    else
        mkdir -p "$fb" 2>/dev/null
        printf '%s\n' "$fb/$n"
    fi
}
STAMP=$(_ae_wpath update_popup.stamp)
log(){ echo "[$(date '+%F %T')] update_popup: $*"; }

### 3.9.8：容器发现必须在计算 _CID 之前 —— 旧代码在 C 还未定义时就算容器 ID，
### 节流标记形同虚设，停用期间还会把用户刚停掉的 webrtc 容器重启（实测抢跑之一）。
### 同时新增停用判定：安卓容器不在运行 = 用户已停用，本脚本绝不碰画面服务。
C=""
for CAND in androidemu-webrtc cloudphone-webrtc; do
    [ "$(docker inspect -f '{{.State.Running}}' "$CAND" 2>/dev/null)" = "true" ] && { C="$CAND"; break; }
done
[ -z "$C" ] && exit 0
for _AC in androidemu-android cloudphone-android; do
    docker inspect "$_AC" >/dev/null 2>&1 || continue
    _ast=$(docker inspect -f '{{.State.Status}}' "$_AC" 2>/dev/null)
    case "$_ast" in
        exited|created|dead) log "应用已停用（${_AC} ${_ast}），跳过弹窗补丁与容器重启"; exit 0 ;;
    esac
    break
done

_CID=$(docker inspect -f '{{.Id}}' "$C" 2>/dev/null | cut -c1-12)
if [ -f "$STAMP" ]; then
    read -r _scid _sts < "$STAMP" 2>/dev/null || true
    if [ "$_scid" = "$_CID" ]; then
        _age=$(( $(date +%s) - ${_sts:-0} ))
        [ "$_age" -lt 1800 ] && exit 0
    fi
fi

ORIG="https://license.webrtc-phone.com/api/version/latest"
DEAD="https://127.0.0.1:1/api/version/latest"

PATCHED=$(docker exec "$C" sh -c "grep -l '$DEAD' /app/assets/assets/index-*.js 2>/dev/null | head -1")
[ -n "$PATCHED" ] && exit 0   # 已补丁，跳过

TARGETS=$(docker exec "$C" sh -c "grep -l '$ORIG' /app/assets/assets/index-*.js 2>/dev/null")
[ -z "$TARGETS" ] && exit 0   # 该版本前端无此检查，无需处理

for T in $TARGETS; do
    docker exec "$C" sh -c "sed -i 's#$ORIG#$DEAD#g' '$T'" || { log "补丁失败: $T"; exit 1; }
    log "已禁用版本检查弹窗: $C:$T"
done

log "重启容器使前端生效..."
echo "$_CID $(date +%s)" > "$STAMP" 2>/dev/null || true
docker restart "$C" >/dev/null 2>&1
for i in $(seq 1 12); do
    sleep 5
    ss -tln 2>/dev/null | grep -qE ":8443 " && { log "服务已恢复（$((i*5))s）"; break; }
done
exit 0
