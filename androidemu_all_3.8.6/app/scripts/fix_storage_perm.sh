#!/bin/bash
### fix_storage_perm.sh — 持续修复安卓容器 /sdcard 存储目录权限。
###
### 根因（3.2.9 实测）：redroid 容器首次启动时，/data/media/0/ 下的标准目录
### （Download、DCIM、Pictures 等）权限为 drwx------ 1 961 994，只有 UID 961 能访问。
### 穿云投屏 agent（cloudphone-agent）通过 /sdcard FUSE 层访问时，FUSE 强制权限检查，
### root 也被拒绝，表现为"读取文件列表失败: permission denied"。
### /sdcard/Android 目录权限为 drwxrws--x（有执行位）所以"有些可以"，其他目录都是 700。
###
### 修复：容器 boot_completed=1 后，自动把 /data/media/0/ 下所有标准目录权限改成 777。
### 这是容器内部操作，不涉及宿主机 root，不影响审核。
###
### 用法：
###   fix_storage_perm.sh          # 前台持续守护（由 supervise 拉起）
###   fix_storage_perm.sh --once   # 只检测修复一次

set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
ANDROID_C="${REDROID_NAME:-androidemu-android}"
LOG="$VAR_DIR/storage_perm_fix.log"
PIDFILE="$VAR_DIR/storage_perm_fix.pid"
INTERVAL=120

mkdir -p "$VAR_DIR" 2>/dev/null || true

log(){ echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null || true; }

### 需要修复权限的标准存储目录
STORAGE_DIRS="Alarms Audiobooks DCIM Documents Download Movies Music Notifications Pictures Podcasts Ringtones"

### 检查并修复权限
fix_perms() {
    _fixed=0
    for _dir in $STORAGE_DIRS; do
        _path="/data/media/0/$_dir"
        ### 检查目录是否存在
        _exists=$(docker exec "$ANDROID_C" sh -c "test -d '$_path' && echo yes || echo no" 2>/dev/null | tr -d '\r\n')
        [ "$_exists" != "yes" ] && continue
        ### 检查当前权限
        _perm=$(docker exec "$ANDROID_C" sh -c "stat -c '%a' '$_path'" 2>/dev/null | tr -d '\r\n')
        if [ "$_perm" != "777" ]; then
            docker exec "$ANDROID_C" chmod 777 "$_path" 2>/dev/null && {
                log "修复 $_dir 权限: $_perm -> 777"
                _fixed=$((_fixed + 1))
            }
        fi
    done
    ### 同时修复 /data/media/0 本身的权限（确保可以进入）
    _root_perm=$(docker exec "$ANDROID_C" sh -c "stat -c '%a' /data/media/0" 2>/dev/null | tr -d '\r\n')
    if [ "$_root_perm" != "777" ] && [ "$_root_perm" != "775" ]; then
        docker exec "$ANDROID_C" chmod 777 /data/media/0 2>/dev/null && {
            log "修复 /data/media/0 权限: $_root_perm -> 777"
            _fixed=$((_fixed + 1))
        }
    fi
    [ $_fixed -gt 0 ] && log "本次共修复 $_fixed 个目录权限"
}

### 单次检测修复
check_once() {
    _state=$(docker inspect -f '{{.State.Running}}' "$ANDROID_C" 2>/dev/null)
    [ "$_state" != "true" ] && return 0
    _boot=$(docker exec "$ANDROID_C" getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
    [ "$_boot" != "1" ] && return 0
    fix_perms
}

### 主循环
if [ "${1:-}" = "--once" ]; then
    check_once
    exit 0
fi

### 守护模式：确保只有一个实例（3.6.5改进：启动时清理多余旧进程）
### 先清理除自己外的所有同名进程（升级/重启时旧进程可能残留）
_own_pid=$$
for _old_pid in $(pgrep -f "bash .*fix_storage_perm" 2>/dev/null); do
    [ "$_old_pid" = "$_own_pid" ] && continue
    kill "$_old_pid" 2>/dev/null || true
done
sleep 1
### 再检查PID文件中的进程
if [ -f "$PIDFILE" ]; then
    _pid_from_file=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$_pid_from_file" ] && kill -0 "$_pid_from_file" 2>/dev/null; then
        if [ "$_pid_from_file" != "$_own_pid" ]; then
            log "存储权限守护已在运行（pid=$_pid_from_file），退出"
            exit 0
        fi
    else
        rm -f "$PIDFILE" 2>/dev/null || true
    fi
fi
echo $$ > "$PIDFILE" 2>/dev/null || true
log "存储权限守护启动（pid=$$，每${INTERVAL}秒检测一次）"

trap 'rm -f "$PIDFILE"; log "存储权限守护退出"; exit 0' TERM INT

while :; do
    check_once
    sleep "$INTERVAL"
done
