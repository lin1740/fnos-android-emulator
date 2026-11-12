#!/bin/bash
### 3.9.9-r2：补齐 /usr/sbin（runuser 所在目录）。飞牛看护进程 environ 实测无 PATH，
### 缺它时下面的降权分支会回退成 高权限常驻，与受限档语义冲突。
case ":${PATH:-}:" in
    *:/usr/sbin:*) ;;
    *) export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/sbin:/sbin" ;;
esac

### runtime_guard.sh — 受限档的运行期复核：确保应用侧不提供调试级权限
###
### 触发条件：${VAR_DIR}/guard-on 存在（安装向导选受限档时由
###           runtime_profile.sh 写入；改到其它档会删除该标记）。
###
### 复核四件事（全部幂等，只收紧不放宽）：
###   1) 容器内 su 类二进制：发现即删除（/system 为 overlay 可写；删不掉则用空文件遮罩）
###   2) adbd 运行身份：若被调试命令切到高权限，恢复为 shell 后重启 adbd
###   3) 系统属性：ro.debuggable / ro.build.type 不合规时记录告警，
###      由 harden_system.sh 统一处理（它需要重启容器，本脚本不重复重启）
###   4) ADB 转发绑定地址：强制 127.0.0.1，发现 0.0.0.0 立即改回并重启转发
###   5) debuggable=1 的窗口期（容器刚重建、harden_system 尚未跑）：期间 `adb 调试提权` 仍可用，
###      因此临时关掉 ADB 转发并立即触发 harden_system.sh；属性归零后下一轮自动恢复转发
###
### 结果写 ${VAR_DIR}/runtime_guard.status，供面板与排障查看。
### 调用方：boot_guard 巡检（容器运行时每轮，内部 60 秒节流）、安装/升级收尾、启用链路。
set +e
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

C="${ANDROIDEMU_CONTAINER:-androidemu-android}"
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
mkdir -p "$VAR_DIR" 2>/dev/null || true

LOG="$VAR_DIR/runtime_guard.log"
if ! ( : >> "$LOG" ) 2>/dev/null; then
    LOG="/tmp/androidemu-runtime_guard.$(id -u).log"
fi
log(){ echo "[$(date '+%F %T')] runtime_guard: $*" >> "$LOG" 2>/dev/null || true; }

### 仅受限档执行。
### 3.9.9：除标记文件外，再认 profile-level=none —— 早期安装若在写标记前中止（实测
### 2026-11-09 主 NAS：安装卡在飞牛 compose 重建、install_callback 未执行到底），
### 只靠标记会让本档的复核永久失效；这里按已落盘的档位兜底补写标记后继续。
if [ ! -f "$VAR_DIR/guard-on" ]; then
    if [ "$(cat "$VAR_DIR/profile-level" 2>/dev/null | tr -d '\r\n ')" = "none" ]; then
        echo "on" > "$VAR_DIR/guard-on" 2>/dev/null || true
        log "profile-level=none 但缺少标记文件，已补写并继续复核"
    else
        exit 0
    fi
fi

### 容器不在运行：容器启动后由下一轮巡检接手（安装/升级收尾会显式调用一次）
[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ] || exit 0

### 节流：同一容器 60 秒内只复核一次（避免与 harden_system / boot_guard 互相抢）
STAMP="$VAR_DIR/runtime_guard.stamp"
CID=$(docker inspect -f '{{.Id}}' "$C" 2>/dev/null | cut -c1-12)
if [ -f "$STAMP" ]; then
    read -r _scid _sts < "$STAMP" 2>/dev/null || true
    case "${_sts:-}" in ''|*[!0-9]*) _sts=0 ;; esac
    if [ "${_scid:-}" = "$CID" ] && [ $(( $(date +%s) - _sts )) -lt 60 ]; then
        exit 0
    fi
fi

### 3.9.9 复测修订（2026-11-08）：状态文件原子写入 + adbd 取值重试 + 转发守护降权。
### 背景：安装回调以系统身份执行本脚本时，status / stamp / log 会以 系统属主创建（644），
### 包用户看护后续覆写报 Permission denied（boot_guard.log 实测反复出现），状态永远停在
### 首次；首次又恰逢容器刚 up、adbd 未就绪，于是「ADBD_USER=未知 / OK=1」被长期保留。
### 三处一起收紧：写入不依赖文件本身可写、身份取不到时延后重试、启动子进程一律降权。
write_atomic(){   ### $1=目标文件，stdin=内容；只依赖所在目录可写
    local _t="$1.$$.tmp"
    cat > "$_t" 2>/dev/null || return 1
    if [ "$(id -u)" = "0" ] && id "${TRIM_RUN_USERNAME:-docker-androidemu}" >/dev/null 2>&1; then
        chown "${TRIM_RUN_USERNAME:-docker-androidemu}":docker "$_t" 2>/dev/null || true
    fi
    mv -f "$_t" "$1" 2>/dev/null || { rm -f "$_t" 2>/dev/null; return 1; }
    return 0
}
if [ "$(id -u)" = "0" ] && [ -f "$LOG" ] && id "${TRIM_RUN_USERNAME:-docker-androidemu}" >/dev/null 2>&1; then
    chown "${TRIM_RUN_USERNAME:-docker-androidemu}":docker "$LOG" 2>/dev/null || true
fi
adbd_user(){      ### 容器刚启动时 adbd 可能还没起来，最多重试 3 次（间隔 2 秒）
    local _u="" _i
    for _i in 1 2 3; do
        _u=$(docker exec "$C" sh -c 'ps -A -o USER,NAME 2>/dev/null | awk "\$2==\"adbd\"{print \$1; exit}"' 2>/dev/null | tr -d '\r\n')
        [ -n "$_u" ] && break
        sleep 2
    done
    printf '%s' "$_u"
}
adb_forward_start(){   ### 无论本脚本被系统身份还是包用户调用，转发守护都以包用户常驻
    if [ "$(id -u)" = "0" ] && command -v runuser >/dev/null 2>&1 \
       && id "${TRIM_RUN_USERNAME:-docker-androidemu}" >/dev/null 2>&1; then
        nohup runuser -u "${TRIM_RUN_USERNAME:-docker-androidemu}" -- \
            env TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/redroid_adb_forward.sh" install >/dev/null 2>&1 &
    else
        TRIM_PKGVAR="$VAR_DIR" nohup bash "$APP_DIR/scripts/redroid_adb_forward.sh" install >/dev/null 2>&1 &
    fi
}

SU_LEFT=""
ADBD_USER=""
DBG=""
BT=""
BIND=""
ADB_FORWARD="on"
NEED_HARDEN=0
CHANGED=0

### 1) su 类二进制
SU_LIST=$(docker exec -u 0 "$C" sh -c '
for p in /system/bin/su /system/xbin/su /system/sbin/su /sbin/su /vendor/bin/su /debug_ramdisk/su; do
    [ -e "$p" ] && echo "$p"
done' 2>/dev/null | tr -d '\r')
if [ -n "$SU_LIST" ]; then
    log "发现 su：$(echo "$SU_LIST" | tr '\n' ' ')"
    docker exec -u 0 "$C" sh -c '
for p in /system/bin/su /system/xbin/su /system/sbin/su /sbin/su /vendor/bin/su /debug_ramdisk/su; do
    [ -e "$p" ] || continue
    rm -f "$p" 2>/dev/null
    if [ -e "$p" ]; then
        : > /data/local/tmp/.empty_su 2>/dev/null
        mount -o bind /data/local/tmp/.empty_su "$p" 2>/dev/null || chmod 000 "$p" 2>/dev/null
    fi
done' >/dev/null 2>&1
    CHANGED=1
    SU_LEFT=$(docker exec -u 0 "$C" sh -c '
n=0; for p in /system/bin/su /system/xbin/su /system/sbin/su /sbin/su /vendor/bin/su /debug_ramdisk/su; do
    [ -e "$p" ] && n=$((n+1)); done; echo $n' 2>/dev/null | tr -d '\r\n')
    log "su 清理后剩余：${SU_LEFT:-?} 个"
else
    SU_LEFT=0
fi

### 2) adbd 身份（容器刚起时 adbd 未必就绪，adbd_user 内部带重试）
ADBD_USER=$(adbd_user)
case "$ADBD_USER" in
    root)
        log "adbd 以系统身份运行（adb 调试提权 已被执行过）→ 恢复 shell 身份"
        docker exec "$C" sh -c 'setprop service.adb.root 0; setprop ctl.restart adbd' >/dev/null 2>&1
        sleep 3
        ADBD_USER=$(adbd_user)
        CHANGED=1
        log "adbd 恢复后身份：${ADBD_USER:-未知}"
        ;;
    "") ADBD_USER="未知" ;;
esac
[ "$ADBD_USER" = "未知" ] && log "本轮未取到 adbd 身份（容器可能刚启动）→ 记为待复核，下一轮继续"

### 3) 系统属性复核（不合规交给 harden_system.sh，它需要重启容器，这里只记录）
DBG=$(docker exec "$C" getprop ro.debuggable 2>/dev/null | tr -d '\r\n')
BT=$(docker exec "$C" getprop ro.build.type 2>/dev/null | tr -d '\r\n')
[ "$DBG" = "1" ] && NEED_HARDEN=1
[ "$BT" = "userdebug" ] && NEED_HARDEN=1
if [ "$NEED_HARDEN" = "1" ]; then
    ### debuggable=1 时调试命令仍可切到高权限（ro 属性运行期改不了），
    ### 所以窗口期内干脆不提供 ADB 入口：先停转发，再让 harden_system.sh 把属性归零。
    log "属性仍为 debuggable=1 / build.type=$BT → 临时关闭 ADB 转发并触发 harden_system"
    if [ -x "$APP_DIR/scripts/redroid_adb_forward.sh" ]; then
        TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/redroid_adb_forward.sh" remove >/dev/null 2>&1
        ADB_FORWARD=off
    fi
    if [ -f "$APP_DIR/scripts/harden_system.sh" ]; then
        TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/harden_system.sh" >>"$LOG" 2>&1 || true
        DBG=$(docker exec "$C" getprop ro.debuggable 2>/dev/null | tr -d '\r\n')
        BT=$(docker exec "$C" getprop ro.build.type 2>/dev/null | tr -d '\r\n')
        [ "$DBG" = "1" ] && NEED_HARDEN=1 || NEED_HARDEN=0
        [ "$BT" = "userdebug" ] && NEED_HARDEN=1
    fi
fi

### 4) ADB 转发绑定地址
PC="$VAR_DIR/ports.conf"
if [ -f "$PC" ]; then
    BIND=$(sed -n 's/^ADB_BIND=//p' "$PC" 2>/dev/null | head -n1 | tr -d ' \r\n')
fi
[ -z "$BIND" ] && BIND="127.0.0.1"   # 缺省即本机绑定
if [ "$BIND" != "127.0.0.1" ]; then
    log "ADB 绑定地址为 $BIND（本档不允许对外开放）→ 改回 127.0.0.1 并重启转发"
    if grep -q '^ADB_BIND=' "$PC" 2>/dev/null; then
        sed -i 's/^ADB_BIND=.*/ADB_BIND=127.0.0.1/' "$PC" 2>/dev/null
    else
        echo 'ADB_BIND=127.0.0.1' >> "$PC" 2>/dev/null
    fi
    if [ -x "$APP_DIR/scripts/redroid_adb_forward.sh" ] && [ "$NEED_HARDEN" != "1" ]; then
        TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/redroid_adb_forward.sh" remove >/dev/null 2>&1
        adb_forward_start
        ADB_FORWARD=on
    fi
    BIND="127.0.0.1"
    CHANGED=1
fi

### 窗口期已过：恢复 ADB 转发（若当前没在跑）
if [ "$NEED_HARDEN" != "1" ] && [ "$ADB_FORWARD" != "off" ]; then
    AP="5556"
    if [ -f "$VAR_DIR/ports.conf" ]; then
        _ap=$(sed -n 's/^ADB_PORT=//p' "$VAR_DIR/ports.conf" 2>/dev/null | head -n1 | tr -d ' \r\n')
        case "$_ap" in ''|*[!0-9]*) : ;; *) AP="$_ap" ;; esac
    fi
    if ! ss -lnt 2>/dev/null | grep -q ":$AP "; then
        if [ -x "$APP_DIR/scripts/redroid_adb_forward.sh" ]; then
            log "debuggable 已归零，ADB 转发未在跑 → 恢复（$AP）"
            adb_forward_start
        fi
    fi
    ### 容器重启后 adbd 可能是 stopped（service.adb.tcp.port 也被清空），
    ### 光有转发等于空转 —— 这里补一次拉起，端口固定 5555。
    ADB_SVC=$(docker exec "$C" getprop init.svc.adbd 2>/dev/null | tr -d ' \r\n')
    if [ "$ADB_SVC" != "running" ]; then
        docker exec -u 0 "$C" sh -c 'setprop service.adb.tcp.port 5555; start adbd' >/dev/null 2>&1 \
            || docker exec -u 0 "$C" sh -c 'setprop ctl.start adbd' >/dev/null 2>&1
        log "adbd 未运行（init.svc.adbd=${ADB_SVC:-空}）→ 已尝试拉起"
        sleep 2
    fi
fi

### 汇总状态（「未知」不算通过，并留待下一轮复核）
OK=1
[ "${SU_LEFT:-0}" != "0" ] && OK=0
[ "$ADBD_USER" = "root" ] && OK=0
[ "$ADBD_USER" = "未知" ] && OK=0
[ "$BIND" != "127.0.0.1" ] && OK=0
[ "$NEED_HARDEN" = "1" ] && OK=0
RECHECK=0
[ "$ADBD_USER" = "未知" ] && RECHECK=1
{
    echo "LEVEL=none"
    echo "SU_LEFT=${SU_LEFT:-0}"
    echo "ADBD_USER=${ADBD_USER:-未知}"
    echo "DEBUGGABLE=${DBG:-未知}"
    echo "BUILD_TYPE=${BT:-未知}"
    echo "ADB_BIND=${BIND}"
    echo "ADB_FORWARD=${ADB_FORWARD}"
    echo "HARDEN_PENDING=${NEED_HARDEN}"
    echo "PENDING_RECHECK=${RECHECK}"
    echo "OK=${OK}"
    echo "UPDATED=$(date '+%F %T')"
} | write_atomic "$VAR_DIR/runtime_guard.status" || true

### 身份未确认时不写节流标记：让下一轮巡检继续复核，避免「容器刚启动 adbd 还没起」
### 这一次空值被 60 秒节流锁死，状态长期停在「未知 / OK=1」。
if [ "$RECHECK" != "1" ]; then
    echo "$CID $(date +%s)" | write_atomic "$STAMP" || true
fi

[ "$CHANGED" = "1" ] && log "本轮已收紧：su剩余=${SU_LEFT:-0} adbd=${ADBD_USER} bind=${BIND}"
exit 0
