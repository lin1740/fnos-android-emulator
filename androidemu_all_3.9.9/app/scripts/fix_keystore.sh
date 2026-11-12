#!/bin/bash
### fix_keystore.sh — 持续监控并自动修复安卓容器的密钥/锁屏数据库异常。
###
### 根因（3.2.5 / 3.9.2 实测）：
###   ① /data/misc/keystore/persistent.sqlite 属主/权限异常 → keystore2 在
###      create_thread_local_db 时 Rust panic（expect_none_failed）。
###   ② /data/system 下的文件被改成「宿主数字 UID」（实测 961:994，正常应为
###      system:system = 1000:1000 或 0:0 = 0:0）→ keystore2 读取 locksettings
###      相关数据时崩溃，LockSettingsService 抛 java.lang.AssertionError: 4，
###      system_server 直接 FATAL EXCEPTION IN SYSTEM PROCESS 退出，zygote 随之重启
###      → 无限「正在启动手机…」，表现是**所有应用都点不开**。
###   宿主侧任何对数据目录的写入（备份还原、cp -a、tar 解包、手工 chown）都会造成 ②，
###   因此必须常驻巡检，而不是安装时跑一次。
###
### 判据（实测收紧过两次，别放宽）：
###   · 只把「uid 既不是 0 也不是 1000(system)」的文件视为损坏 ——
###     合法的 /data/system/packages.list 是 1000:1032，按 gid 判断会误报。
###   · Android 的 find 是 toybox，不支持 -uid/-gid（bad arg），必须 -exec stat + awk。
###   · 只有 keystore 库本身仍坏时才删库重建；单纯属主问题绝不删数据。
###
### 用法：
###   fix_keystore.sh          # 前台持续守护（由 boot_guard / start_pull_bg 拉起）
###   fix_keystore.sh --once   # 只检测修复一次
###   fix_keystore.sh --status # 只输出状态，不动任何东西
###

set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
ANDROID_C="${REDROID_NAME:-androidemu-android}"
LOG="$VAR_DIR/keystore_fix.log"
PIDFILE="$VAR_DIR/keystore_fix.pid"
LOCKFILE="$VAR_DIR/keystore_fix.lock"
INTERVAL=60
KFILE="/data/misc/keystore/persistent.sqlite"
SYS_DIR="/data/system"
SYS_UID=1000
SYS_GID=1000

mkdir -p "$VAR_DIR" 2>/dev/null || true

log(){ echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null || true; }

dex(){ docker exec -u 0 "$ANDROID_C" sh -c "$1" 2>/dev/null | tr -d '\r'; }

### ── 检查一：keystore 数据库属主/权限 ──────────────────────────────
keystore_meta() {
    dex "test -f $KFILE && stat -c '%u:%g %a %U:%G' $KFILE"
}

keystore_is_broken() {
    _meta=$(keystore_meta)
    [ -z "$_meta" ] && return 1          # 文件不存在 → 由 keystore2 自行创建，不算坏
    _perm=$(echo "$_meta" | awk '{print $2}')
    _owner=$(echo "$_meta" | awk '{print $3}')
    [ "$_owner" != "keystore:keystore" ] && return 0
    [ "$_perm" != "600" ] && return 0
    return 1
}

### ── 检查二：/data/system 属主是否被写成宿主数字 UID ──────────────
### 查 4 层：locksettings.db 在 1 层，users/0/settings_secure.xml 在第 3 层。
### 容器里只做"取属主"，过滤放宿主侧做 ——
### 之前把 awk 塞进 sh -c 的双引号里，$1 被容器内 shell 二次展开，
### 过滤条件失效 → 1316 个正常文件全被判为异常（实测误报，已改掉）。
sys_owner_raw() {
    dex "find $SYS_DIR -maxdepth 4 -exec stat -c '%u:%g %n' {} +"
}

### 只保留 uid 既不是 0 也不是 1000(system) 的行
### 注意只判 uid：/data/system/packages.list 合法属主是 1000:1032，按 gid 判会误报。
sys_owner_bad() {
    sys_owner_raw | grep -vE '^(0|1000):'
}

sys_owner_list() {
    sys_owner_bad | awk '{print $2}'
}

sys_owner_broken() {
    [ -n "$(sys_owner_bad)" ] && return 0
    return 1
}

sys_owner_count() {
    sys_owner_bad | grep -c .
}

### ── 修复 ────────────────────────────────────────────────────────
keystore_ids() {
    _ids=$(docker exec -u 0 "$ANDROID_C" sh -c 'id -u keystore 2>/dev/null; id -g keystore 2>/dev/null' 2>/dev/null | tr -d '\r')
    _uid=$(printf '%s\n' "$_ids" | sed -n 1p)
    _gid=$(printf '%s\n' "$_ids" | sed -n 2p)
    case "$_uid" in ''|*[!0-9]*) _uid=1017 ;; esac
    case "$_gid" in ''|*[!0-9]*) _gid=1017 ;; esac
    echo "$_uid:$_gid"
}

### 只纠正 keystore 库属主/权限（保留数据）
repair_keystore_owner() {
    _ids=$(keystore_ids)
    dex "chown $_ids /data/misc/keystore/persistent.sqlite /data/misc/keystore/vpnprofilestore.sqlite 2>/dev/null; \
         chmod 600 /data/misc/keystore/persistent.sqlite 2>/dev/null" >/dev/null 2>&1
    ! keystore_is_broken
}

### 只纠正 /data/system 里被写坏的那几个文件（保留数据，绝不整树 chown）
repair_sys_owner() {
    _list=$(sys_owner_list)
    if [ -z "$_list" ]; then
        return 0
    fi
    _n=$(printf '%s\n' "$_list" | grep -c .)
    _args=$(printf '%s' "$_list" | tr '\n' ' ')
    ### 路径由 find 产出（无空格），逐批 chown 即可
    dex "chown $SYS_UID:$SYS_GID $_args 2>/dev/null" >/dev/null 2>&1
    if sys_owner_broken; then
        log "/data/system 属主纠正后仍有残留（原 $_n 项），可能被占用，下次巡检重试"
        return 1
    fi
    log "/data/system 属主已纠正（原 $_n 项为宿主 UID，数据保留）"
    return 0
}

### 删库重建（仅在 keystore 库本身仍坏时使用；会丢锁屏口令）
do_fix_delete() {
    log "回退方案：删除损坏的 keystore/locksettings 数据库并重建"
    dex "rm -f $KFILE \
        /data/misc/keystore/vpnprofilestore.sqlite \
        /data/system/locksettings.db \
        /data/system/locksettings.db-shm \
        /data/system/locksettings.db-wal \
        /data/system/gatekeeper.password.key \
        /data/system/gatekeeper.pattern.key" >/dev/null 2>&1
    docker restart "$ANDROID_C" >/dev/null 2>&1 || true
    sleep 60
    _boot=$(dex "getprop sys.boot_completed")
    if keystore_is_broken; then
        log "删库重建后 keystore 仍异常，将在下次检测时重试"
    else
        log "keystore 库已重建（boot_completed=$_boot）"
    fi
    bash "$APP_DIR/scripts/agent_autodeploy.sh" >/dev/null 2>&1 || true
}

### 执行修复：先只纠正属主；仅当 keystore 库仍坏时才删库
do_fix() {
    _why=""
    keystore_is_broken && _why="${_why}keystore库 "
    sys_owner_broken   && _why="${_why}/data/system属主 "
    log "检测到异常（${_why}），开始修复..."

    repair_keystore_owner || true
    repair_sys_owner || true

    if keystore_is_broken; then
        ### 只有库文件本身仍不合规才走删库
        do_fix_delete
        return
    fi

    log "属主/权限已纠正（保留数据），重启容器让 keystore2 重新打开"
    docker restart "$ANDROID_C" >/dev/null 2>&1 || true
    sleep 60
    _boot=$(dex "getprop sys.boot_completed")
    log "修复完成（保留数据，boot_completed=$_boot）"
    bash "$APP_DIR/scripts/agent_autodeploy.sh" >/dev/null 2>&1 || true
}

### 单次检测修复
check_once() {
    _state=$(docker inspect -f '{{.State.Running}}' "$ANDROID_C" 2>/dev/null)
    [ "$_state" != "true" ] && return 0

    _k=0; _s=0
    keystore_is_broken && _k=1
    sys_owner_broken   && _s=1
    [ "$_k" = "0" ] && [ "$_s" = "0" ] && return 0

    _boot=$(dex "getprop sys.boot_completed")
    if [ "$_boot" = "1" ]; then
        do_fix
    else
        ### 开机早期：只纠正属主，不重启（避免打断正在进行的开机）
        [ "$_k" = "1" ] && repair_keystore_owner
        [ "$_s" = "1" ] && repair_sys_owner
        log "开机早期检测到异常（keystore=$_k sys=$_s），已纠正属主（不重启，等待开机完成）"
    fi
}

status_report() {
    _state=$(docker inspect -f '{{.State.Running}}' "$ANDROID_C" 2>/dev/null)
    echo "容器运行: ${_state:-未知}"
    echo "keystore 库: $(keystore_meta)"
    echo "keystore 异常: $(keystore_is_broken && echo 是 || echo 否)"
    echo "/data/system 异常项: $(sys_owner_count)"
    echo "---- 前 5 个异常项 ----"
    sys_owner_list | head -5
}

case "${1:-}" in
    --status)
        status_report
        exit 0
        ;;
    --once)
        check_once
        exit 0
        ;;
esac

### 守护模式：flock 独占锁保证单实例（3.8.9 修复：原 pgrep+kill 竞态会互相杀掉导致无人守护）
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCKFILE" 2>/dev/null || true
    if ! flock -n 9 2>/dev/null; then
        log "keystore 守护已在运行（flock 占用），退出"
        exit 0
    fi
else
    ### 无 flock 时的退化方案：PID 文件校验
    if [ -f "$PIDFILE" ]; then
        _p=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
            log "keystore 守护已在运行（pid=$_p），退出"
            exit 0
        fi
    fi
fi
echo $$ > "$PIDFILE" 2>/dev/null || true
log "keystore 守护启动（pid=$$，每${INTERVAL}秒检测一次）"

trap 'rm -f "$PIDFILE"; log "keystore 守护退出"; exit 0' TERM INT

### 3.9.2：容器连续 3 次不在运行就自行退出。
### 飞牛「停用」只停容器、不会调用应用的停用脚本（实测 cmd/main stop 未被调用），
### 守护进程会一直挂在宿主上；这里用"容器不在就退"解决残留，不依赖框架钩子。
_down=0
while :; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$ANDROID_C" 2>/dev/null)" = "true" ]; then
        _down=0
        check_once
    else
        _down=$((_down + 1))
        if [ "$_down" -ge 3 ]; then
            log "容器连续 ${_down} 次未运行（应用已停用/卸载），守护退出"
            rm -f "$PIDFILE" 2>/dev/null || true
            exit 0
        fi
    fi
    sleep "$INTERVAL"
done
