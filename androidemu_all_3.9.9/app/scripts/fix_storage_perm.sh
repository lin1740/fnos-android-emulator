#!/bin/bash
### fix_storage_perm.sh — 持续修复安卓容器 /sdcard 存储目录权限。
###
### 根因（3.2.9 实测）：redroid 容器首次启动时，/data/media/0/ 下的标准目录
### （Download、DCIM、Pictures 等）权限为 drwx------ 1 961 994，只有 UID 961 能访问。
### 穿云投屏 agent（cloudphone-agent）通过 /sdcard FUSE 层访问时，FUSE 强制权限检查，
### 系统身份也被拒绝，表现为"读取文件列表失败: permission denied"。
### /sdcard/Android 目录权限为 drwxrws--x（有执行位）所以"有些可以"，其他目录都是 700。
###
### 修复：容器 boot_completed=1 后，自动把 /data/media/0/ 下所有标准目录权限改成 777。
### 这是运行环境内部操作，不涉及宿主权限。
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
    ### 3.9.5：/data/app APK 权限兜底 —— 部分 redroid 构建的 installd 以 0700 创建
    ### /data/app 文件（属主映射宿主 961:994），普通应用进程（uid 10xxx）无法读取
    ### APK，表现为所有第三方应用启动即闪退（FATAL EXCEPTION，ziparchive: Unable
    ### to open base.apk；2026-11-03 实测，重建容器后必现）。Android 标准 APK 必须
    ### world-readable。此处周期检查：发现不可读的 APK 就补 644/755。幂等，无 APK
    ### 需要修复时零开销。
    local _bad
    _bad=$(docker exec "$ANDROID_C" sh -c 'find /data/app -maxdepth 3 \( -name "*.apk" ! -perm -0044 \) -print -quit 2>/dev/null' 2>/dev/null | tr -d "\r")
    if [ -n "$_bad" ]; then
        docker exec "$ANDROID_C" sh -c 'chmod 755 /data/app /data/app/* 2>/dev/null; chmod -R a+rX /data/app 2>/dev/null' >/dev/null 2>&1 || true
        log "已修复 /data/app APK 权限（发现 0700 的 $_bad，应用闪退根因）"
        _fixed=1
    fi
    ### 3.9.9-r4：标准目录改为「一次 docker exec 批量检查+修复」。
    ### 旧写法 11 个目录 × 2 次 exec，实测要 15~20 秒才修完，用户在这个窗口
    ### 点文件中心仍会报 permission denied（2026-11-10 21:10 实测 22 秒才变 777）。
    _sp_out=$(docker exec "$ANDROID_C" sh -c '
        for d in '"$STORAGE_DIRS"'; do
            p="/data/media/0/$d"
            [ -d "$p" ] || continue
            cur=$(stat -c %a "$p" 2>/dev/null)
            if [ "$cur" != "777" ]; then
                chmod 777 "$p" 2>/dev/null && echo "$d $cur"
            fi
        done
        cur=$(stat -c %a /data/media/0 2>/dev/null)
        if [ "$cur" != "777" ] && [ "$cur" != "775" ]; then
            chmod 777 /data/media/0 2>/dev/null && echo "/data/media/0 $cur"
        fi
    ' 2>/dev/null | tr -d "\r")
    if [ -n "$_sp_out" ]; then
        _n=0
        while read -r _d _c; do
            [ -n "$_d" ] || continue
            log "修复 $_d 权限: $_c -> 777"
            _n=$((_n + 1))
        done <<EOF
$_sp_out
EOF
        _fixed=$((_fixed + _n))
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

### 3.9.9-r4：容器未就绪时 10 秒快速重试，就绪后立刻修，再回到 120 秒轮询。
### 旧逻辑容器没 boot 完也睡满 120 秒，实测升级/重启后最长约 2 分钟内
### 文件中心点开就是「读取文件列表失败: open /sdcard/Download: permission denied」
### （2026-11-10 21:10 用户截图，21:10:32 守护才修好）。
while :; do
    _st=$(docker inspect -f '{{.State.Running}}' "$ANDROID_C" 2>/dev/null)
    _bt=$(docker exec "$ANDROID_C" getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
    if [ "$_st" = "true" ] && [ "$_bt" = "1" ]; then
        fix_perms
        sleep "$INTERVAL"
    else
        sleep 5
    fi
done
