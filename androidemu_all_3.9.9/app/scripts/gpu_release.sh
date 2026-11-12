#!/bin/bash
### gpu_release.sh — 给「容器内」的 DRM 节点放权（GPU 直通机器必需）。
###
### 【为什么改到这里做】（2026-11-07 实测，AMD + fnOS）
###   compose 用 devices: 直通时，容器内的 /dev/dri/* 是「创建/重启容器那一刻」按宿主
###   节点权限生成的副本，容器内 /dev 是 tmpfs，改它只影响容器自己，碰不到宿主节点 ——
###   这正是我们要的：安卓只需要**容器内**的节点可读写，宿主 /dev/dri 可以一直保持
###   root:video 660，不必被本应用改动。
###   实测（宿主 card0 一直 660 的情况下）：容器内 chmod 666 → boot_completed=1（20 秒）、
###   surfaceflinger 正常、logcat 无 EGL/DRM 报错、面板 8443=200。
###
### 【旧做法的两个问题（已废弃）】
###   1) 用一次性容器（docker run，系统内高权限）改宿主节点权限 —— 属于「额外的 高权限容器」；
###   2) 把宿主节点改成 666 —— 等于放宽了宿主设备权限，对审核与安全都不利。
###   现在的做法两者都不需要：只在应用自己的安卓容器里 chmod 自己的节点副本。
###
### 【注意】docker restart / compose up --force-recreate 都会按宿主权限重新生成容器内节点，
###   所以每次容器启动/重启后都要再执行本脚本（安装、升级、启用、重建、巡检都会调用）。
###
### 用法：gpu_release.sh [--wait 秒]   （--wait 默认 25 秒，等待容器进入 running）
### 退出码：恒为 0（失败不阻断启动，后续巡检还会重试）。
### 结果写入 ${TRIM_PKGVAR}/gpu_fix.log

set -u

WAIT=25
while [ $# -gt 0 ]; do
    case "$1" in
        --wait) WAIT="${2:-25}"; shift 2 ;;
        *)      shift ;;
    esac
done

VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
C="${AE_CONTAINER:-androidemu-android}"
mkdir -p "$VAR_DIR" 2>/dev/null || true

### 3.9.9：日志可写性探测。
### 安装/升级回调以系统身份执行，会先以 系统身份创建这个日志；之后包用户的守护
### （boot_guard / webrtc_watchdog）再往同一文件追加会 Permission denied，
### 表现为「放权本身成功、日志却缺行」。不可写就回退 /tmp，保证动作可追溯。
LOG="${VAR_DIR}/gpu_fix.log"
if [ -f "$LOG" ] && [ ! -w "$LOG" ]; then
    LOG="/tmp/androidemu-gpu_fix.log"
fi
if ! ( : >> "$LOG" ) 2>/dev/null; then
    LOG="/tmp/androidemu-gpu_fix.log"
fi
log() { echo "[$(date '+%F %T')] gpu_release: $*" >> "$LOG" 2>/dev/null || true; }

### 宿主没有 DRM 设备（无 GPU / 纯软件渲染机器）→ 容器内也不会有，直接跳过
[ -e /dev/dri ] || exit 0
docker inspect "$C" >/dev/null 2>&1 || exit 0

### 等容器进入 running（刚创建/刚重启时 exec 会失败）
_i=0
while [ "$_i" -lt "$WAIT" ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ] && break
    sleep 1; _i=$((_i+1))
done
[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ] || exit 0

### 容器内没有 /dev/dri（软件渲染 / 未直通）→ 无需处理
docker exec -u 0 "$C" test -e /dev/dri 2>/dev/null || exit 0

nodes(){
    docker exec -u 0 "$C" sh -c 'for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && printf " %s:%s" "$(basename "$d")" "$(stat -c %a "$d" 2>/dev/null)"; done' 2>/dev/null | tr -d '\r\n'
}
all_666(){
    _bad=0
    for m in $(nodes); do
        [ "${m##*:}" = "666" ] || _bad=1
    done
    return $_bad
}

BEFORE="$(nodes)"
[ -z "$BEFORE" ] && exit 0
if all_666; then
    log "容器内节点已是 666，跳过（${BEFORE}）"
    exit 0
fi

### 容器内放权：只改容器自己的 /dev 副本，宿主 /dev/dri 不动
_i=0
while [ "$_i" -lt 10 ]; do
    docker exec -u 0 "$C" sh -c 'for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && chmod 666 "$d" 2>/dev/null; done; exit 0' >/dev/null 2>&1
    all_666 && break
    sleep 1; _i=$((_i+1))
done

AFTER="$(nodes)"
if all_666; then
    log "容器内放权成功（宿主未改动）：${BEFORE} →${AFTER}"
else
    log "容器内放权未完成：${BEFORE} →${AFTER}（宿主节点保持 $(for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && printf '%s:%s ' "$(basename "$d")" "$(stat -c %a "$d" 2>/dev/null)"; done)）"
fi
exit 0
