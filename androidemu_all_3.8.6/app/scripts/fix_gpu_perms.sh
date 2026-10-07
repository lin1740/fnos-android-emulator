### 2.0.58：锁文件从 /tmp 迁到应用数据目录（避免被其它用户创建后包用户不可写）
LOCK_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
mkdir -p "$LOCK_DIR" 2>/dev/null || true
if ! ( : >> "$LOCK_DIR/.wtest" ) 2>/dev/null; then LOCK_DIR=/tmp; fi
rm -f "$LOCK_DIR/.wtest" 2>/dev/null || true
#!/bin/bash
### fix_gpu_perms.sh — 容器启动后的 GPU 权限自愈（宿主节点放权 + 必要时重建容器）。
###
### 【与 gpu_release.sh 的分工】
###   gpu_release.sh 在「启动容器之前」放权（主路径，最可靠，正常不会走到本脚本）；
###   本脚本是启动之后的兜底，覆盖：容器随系统自启、宿主机重启后 udev 又把节点重置为
###   660、启动前放权因镜像未就绪而跳过、以及升级/重建容器时错过放权的场景。
###
### 【2.0.15 修正的三个真实缺陷】（2026-09-19 实测）
###   ① 旧版在 $LOCK_DIR/.gpu.lock 上取 flock：该文件若被其它用户（或历史 root
###      进程）建成，包用户 `exec 9>` 会 Permission denied，脚本随即 exit 0 ——
###      自愈完全没跑（实测复现）。现在锁文件放在应用数据目录，并容忍取锁失败。
###   ② 旧版用 `docker exec -u 0 chmod` 放权：devices 直通方式下容器内的节点是宿主
###      节点的副本，改它不影响宿主；容器重建后又复制回 660 —— 等于无效。
###      现在改为调用 gpu_release.sh：用带 /bin/sh 的镜像起临时容器、绑定挂载
###      /dev/dri 共享 inode，放权的是**宿主节点**（实测有效）。
###   ③ 旧版恢复动作只有 `setprop ctl.restart surfaceflinger`：实测容器一旦进入
###      "no suitable EGLConfig found" 崩溃循环，单重启渲染服务无法恢复（120 秒仍
###      restarting）。现在改为「宿主节点放权 + docker restart 整个容器」。
###   另外：只有 surfaceflinger 的 PID 反复变化（真的在崩溃循环）才重启容器，
###   正常但较慢的首次启动不会被打断；全过程写 ${TRIM_PKGVAR}/gpu_fix.log。

C="${CNAME:-androidemu-android}"
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
LOG="${VAR_DIR}/gpu_fix.log"
mkdir -p "$VAR_DIR" 2>/dev/null || true
log() { echo "[$(date '+%F %T')] fix_gpu_perms: $*" >> "$LOG" 2>/dev/null || true; }

### 宿主无 GPU 直通条件（无 /dev/dri）时直接跳过（软件渲染不需要）
[ -e /dev/dri ] || exit 0

### flock 互斥（锁文件放在应用数据目录，避免 /tmp 下他人文件导致 Permission denied）
if command -v flock >/dev/null 2>&1; then
    if exec 9>"${VAR_DIR}/.gpu-fix.lock" 2>/dev/null; then
        flock -n 9 2>/dev/null || { log "已有实例在自愈，退出"; exit 0; }
    else
        log "无法创建锁文件，跳过互斥继续执行"
    fi
fi

### 等待容器进入运行态（最多 30 秒）
for _i in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ] && break
    sleep 1
done
[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ] || { log "容器未运行，退出"; exit 0; }

### 给系统初始化留出时间
sleep 5

### 容器内没有 /dev/dri（已回退软件渲染）则跳过
docker exec -u 0 "$C" test -e /dev/dri 2>/dev/null || { log "容器内无 /dev/dri（软件渲染），退出"; exit 0; }

host_modes() {
    for d in /dev/dri/card* /dev/dri/renderD*; do
        [ -e "$d" ] && printf ' %s:%s' "$(basename "$d")" "$(stat -c %a "$d" 2>/dev/null)"
    done
}
boot_done() {
    [ "$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')" = "1" ]
}
sf_pid() {
    docker exec -u 0 "$C" sh -c 'ps -A 2>/dev/null | awk "\$NF==\"surfaceflinger\"{print \$2}" | head -1' 2>/dev/null | tr -d '\r\n'
}
### surfaceflinger 服务状态：崩溃循环时 init 会一直把它标成 restarting（实测可靠信号；
### 崩溃太快时 ps 甚至抓不到进程，所以不能只看 PID 变化）
sf_state() {
    docker exec -u 0 "$C" sh -c 'getprop init.svc.surfaceflinger' 2>/dev/null | tr -d '\r\n'
}
### 最近的崩溃原因是否就是 EGLConfig 失败（GPU 权限问题的特征报错）
egl_errors() {
    E=$(docker exec -u 0 "$C" sh -c 'logcat -d -t 150 2>/dev/null | grep -c "no suitable EGLConfig found"' 2>/dev/null | tr -d '\r\n')
    case "$E" in ''|*[!0-9]*) E=0 ;; esac
    echo "$E"
}
### 给宿主节点放权（复用主路径脚本；它自己会判断是否已是 666）
release_host() {
    if [ -f "${APP_DIR}/scripts/gpu_release.sh" ]; then
        TRIM_PKGVAR="$VAR_DIR" bash "${APP_DIR}/scripts/gpu_release.sh" >/dev/null 2>&1 || true
    else
        log "未找到 ${APP_DIR}/scripts/gpu_release.sh（APP_DIR=${APP_DIR}），无法放权，请确认包完整"
    fi
}
### 重建本应用容器。
### 关键（实测）：compose 用 devices: 直通时，容器内的设备节点是「创建容器那一刻」按宿主
### 权限生成的副本；docker restart 不会重新生成它，只有重建容器才会拿到放权后的权限。
### 因此这里用 compose --force-recreate；compose 不可用时退回 docker restart。
recreate_container() {
    if [ -f "${APP_DIR}/docker/docker-compose.yaml" ]; then
        if ( cd "${APP_DIR}/docker" && docker compose -p androidemu up -d --force-recreate redroid ) >/dev/null 2>&1; then
            return 0
        fi
    fi
    docker restart "$C" >/dev/null 2>&1 || true
}

if boot_done; then
    log "容器已 boot 完成（宿主节点$(host_modes)），无需干预"
    exit 0
fi

log "容器未完成 boot，开始自愈（宿主节点$(host_modes)）"
release_host

ROUND=0
while [ "$ROUND" -lt 2 ]; do
    CHANGES=0     # surfaceflinger PID 变化次数
    CRASHING=0    # 连续观测到 init.svc.surfaceflinger=restarting 的次数
    EGL=0         # 最近日志中 "no suitable EGLConfig found" 的次数
    PREV=""
    for _i in $(seq 1 30); do              # 每轮最多观察 150 秒
        if boot_done; then log "boot 已完成（观察 $((_i*5)) 秒）"; exit 0; fi
        P=$(sf_pid)
        if [ -n "$P" ] && [ -n "$PREV" ] && [ "$P" != "$PREV" ]; then
            CHANGES=$((CHANGES+1))
        fi
        [ -n "$P" ] && PREV="$P"
        if [ "$(sf_state)" = "restarting" ]; then
            CRASHING=$((CRASHING+1))
        else
            CRASHING=0
        fi
        if [ $((_i % 3)) -eq 0 ]; then
            E=$(egl_errors)
            [ "${E:-0}" -gt 0 ] && EGL="$E"
        fi
        if [ "$CHANGES" -ge 3 ] || [ "$CRASHING" -ge 3 ] || [ "${EGL:-0}" -gt 0 ]; then
            break
        fi
        sleep 5
    done

    if [ "$CHANGES" -ge 3 ] || [ "$CRASHING" -ge 3 ] || [ "${EGL:-0}" -gt 0 ]; then
        log "surfaceflinger 崩溃循环（PID 变化 ${CHANGES} 次 / restarting 采样 ${CRASHING} 次 / EGLConfig 报错 ${EGL} 次）：放权宿主节点并重建容器（第 $((ROUND+1)) 次）"
        release_host
        recreate_container
        sleep 20
        if boot_done; then log "重建容器后 boot 已完成（宿主节点$(host_modes)）"; exit 0; fi
        ROUND=$((ROUND+1))
    else
        ### 没有崩溃循环，只是启动较慢：再等一轮，不重启容器（避免打断首次初始化）
        log "boot 尚未完成但 surfaceflinger 稳定（PID 未反复变化、无 restarting、无 EGLConfig 报错），继续等待"
        sleep 20
        if boot_done; then log "boot 已完成"; exit 0; fi
        ROUND=$((ROUND+1))
    fi
done

log "仍未 boot_completed（宿主节点$(host_modes)），请查看 docker logs $C 与宿主 GPU 状态"
exit 0
