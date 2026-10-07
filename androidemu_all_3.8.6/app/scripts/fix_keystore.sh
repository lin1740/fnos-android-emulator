#!/bin/bash
### fix_keystore.sh — 持续监控并自动修复安卓容器 keystore2 数据库损坏。
###
### 根因（3.2.5/3.2.6 实测）：/data/misc/keystore/persistent.sqlite 属主/权限异常时，
### keystore2 服务在 create_thread_local_db 时 Rust panic（expect_none_failed），
### 连带 LockSettingsService 崩溃（AssertionError: 4），系统服务反复重启，
### 表现为"Phone is starting..."卡死、容器 Exited(137) 后被 restart 策略拉起。
###
### 3.2.6 改进：
###   ① 移除一次性标记文件，改为持续守护（每60秒检测一次）；
###   ② 直接检查数据库文件属主/权限（比检测 logcat 更可靠）；
###   ③ 检测到异常时删除数据库并重启容器，keystore2 自动重建。
###
### 用法：
###   fix_keystore.sh          # 前台持续守护（由 supervise 拉起）
###   fix_keystore.sh --once   # 只检测修复一次

set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
ANDROID_C="${REDROID_NAME:-androidemu-android}"
LOG="$VAR_DIR/keystore_fix.log"
PIDFILE="$VAR_DIR/keystore_fix.pid"
INTERVAL=60

mkdir -p "$VAR_DIR" 2>/dev/null || true

log(){ echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null || true; }

### 检查 keystore 数据库是否正常（属主为 keystore，权限为 600）
keystore_is_broken() {
    _f="/data/misc/keystore/persistent.sqlite"
    _owner=$(docker exec "$ANDROID_C" sh -c "stat -c '%U:%G' $_f 2>/dev/null" 2>/dev/null | tr -d '\r\n')
    _perm=$(docker exec "$ANDROID_C" sh -c "stat -c '%a' $_f 2>/dev/null" 2>/dev/null | tr -d '\r\n')
    ### 属主不是 keystore:keystore 或者权限不是 600 → 损坏
    [ "$_owner" != "keystore:keystore" ] && return 0
    [ "$_perm" != "600" ] && return 0
    return 1
}

### 执行修复：删除损坏的数据库并重启容器
do_fix() {
    log "检测到 keystore 数据库损坏，开始修复..."
    ### 在容器内删除损坏的数据库（必须在容器运行时用 docker exec，用 docker run -v 挂载不生效）
    docker exec "$ANDROID_C" rm -f /data/misc/keystore/persistent.sqlite \
        /data/misc/keystore/vpnprofilestore.sqlite \
        /data/system/locksettings.db \
        /data/system/locksettings.db-shm \
        /data/system/locksettings.db-wal \
        /data/system/gatekeeper.password.key \
        /data/system/gatekeeper.pattern.key 2>/dev/null || true
    log "已删除损坏的 keystore/locksettings 数据库"
    ### 重启容器让 keystore2 重建数据库
    docker restart "$ANDROID_C" >/dev/null 2>&1 || true
    log "已重启安卓容器，等待 keystore2 重建数据库（60秒）..."
    sleep 60
    ### 验证
    _boot=$(docker exec "$ANDROID_C" getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
    if keystore_is_broken; then
        log "修复后 keystore 仍异常，将在下次检测时重试"
    else
        log "keystore 修复成功（boot_completed=$_boot）"
    fi
    ### 容器重启后 agent 需要重新部署
    bash "$APP_DIR/scripts/agent_autodeploy.sh" >/dev/null 2>&1 || true
}

### 单次检测修复
check_once() {
    _state=$(docker inspect -f '{{.State.Running}}' "$ANDROID_C" 2>/dev/null)
    [ "$_state" != "true" ] && return 0
    _boot=$(docker exec "$ANDROID_C" getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
    [ "$_boot" != "1" ] && return 0
    if keystore_is_broken; then
        do_fix
    fi
}

### 主循环
if [ "${1:-}" = "--once" ]; then
    check_once
    exit 0
fi

### 守护模式：确保只有一个实例（3.6.5改进：启动时清理多余旧进程）
### 先清理除自己外的所有同名进程（升级/重启时旧进程可能残留）
_own_pid=$$
for _old_pid in $(pgrep -f "bash .*keystore" 2>/dev/null); do
    [ "$_old_pid" = "$_own_pid" ] && continue
    kill "$_old_pid" 2>/dev/null || true
done
sleep 1
### 再检查PID文件中的进程
if [ -f "$PIDFILE" ]; then
    _pid_from_file=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$_pid_from_file" ] && kill -0 "$_pid_from_file" 2>/dev/null; then
        if [ "$_pid_from_file" != "$_own_pid" ]; then
            log "keystore 守护已在运行（pid=$_pid_from_file），退出"
            exit 0
        fi
    else
        rm -f "$PIDFILE" 2>/dev/null || true
    fi
fi
echo $$ > "$PIDFILE" 2>/dev/null || true
log "keystore 守护启动（pid=$$，每${INTERVAL}秒检测一次）"

trap 'rm -f "$PIDFILE"; log "keystore 守护退出"; exit 0' TERM INT

while :; do
    check_once
    sleep "$INTERVAL"
done
