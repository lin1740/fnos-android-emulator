#!/bin/bash
### fix_pms_loop.sh — 修「安装会话残留 → PackageManager 崩溃循环」
###
### 现象（实测）：安卓每约 2 分钟重启一次，所有应用点不开；
###   logcat -b crash 里反复出现
###   FATAL EXCEPTION IN SYSTEM PROCESS: PackageManager
###   NullPointerException ... StorageManager.findPathForUuid ... at PackageManagerService.freeStorage
### 根因：/data/system/install_sessions.xml 里残留了未完成的安装会话（安装中途失败/容器被杀会留下），
###   每次开机 PMS 都会重试这些会话并尝试腾空间 → freeStorage → 此时 StorageManager 还没就绪就 NPE，
###   而 system_server 主线程抛异常 = 整机重启 → 再留会话 → 再崩，形成死循环。
### 处理：仅在「确实出现该崩溃特征」时，停容器 → 清会话与临时目录 → 起容器。
### 安全边界：默认只看不改；崩溃特征不足 3 次绝不动作；同一容器 ID 30 分钟内只做一次。
set +e
C="${ANDROIDEMU_CONTAINER:-androidemu-android}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
STAMP="$VAR_DIR/pms_loop.stamp"
mkdir -p "$VAR_DIR" 2>/dev/null || true

running(){ [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]; }
log(){ echo "[$(date '+%F %T')] pms_loop: $*"; }

running || exit 0

### 崩溃特征计数（只在 crash 缓冲里找，避免误判普通应用崩溃）
HITS=$(docker exec -u 0 "$C" sh -c 'logcat -b crash -d 2>/dev/null | grep -c "findPathForUuid"' 2>/dev/null | tr -d '\r\n')
case "$HITS" in ''|*[!0-9]*) HITS=0 ;; esac
[ "$HITS" -lt 3 ] && exit 0

_CID=$(docker inspect -f '{{.Id}}' "$C" 2>/dev/null | cut -c1-12)
if [ -f "$STAMP" ]; then
    read -r _scid _sts < "$STAMP" 2>/dev/null || true
    if [ "$_scid" = "$_CID" ]; then
        _age=$(( $(date +%s) - ${_sts:-0} ))
        [ "$_age" -lt 1800 ] && exit 0
    fi
fi

log "检测到 PackageManager 崩溃 ${HITS} 次（安装会话残留所致）→ 清理会话并重启容器"
echo "$_CID $(date +%s)" > "$STAMP" 2>/dev/null || true

docker stop "$C" >/dev/null 2>&1
docker exec -u 0 "$C" true >/dev/null 2>&1   # 容器已停，下面用宿主路径清
docker start "$C" >/dev/null 2>&1
sleep 5
docker exec -u 0 "$C" sh -c 'rm -f /data/system/install_sessions.xml; rm -rf /data/app/vmdl*.tmp' >/dev/null 2>&1
docker restart "$C" >/dev/null 2>&1

for i in $(seq 1 24); do
    sleep 10
    [ "$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')" = "1" ] && break
done
_left=$(docker exec -u 0 "$C" sh -c 'logcat -b crash -d 2>/dev/null | grep -c "findPathForUuid"' 2>/dev/null | tr -d '\r\n')
log "处理完成，boot=$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')，剩余崩溃计数=${_left:-0}"
exit 0
