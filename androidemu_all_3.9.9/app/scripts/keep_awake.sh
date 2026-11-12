#!/bin/bash
### keep_awake.sh — 保持安卓设备唤醒，防止长时间无操作自动息屏/休眠导致连接断开。
###
### 作用：
###   1. 设置屏幕超时为最大值（约24.8天），避免自动息屏
###   2. 设置充电时保持屏幕常亮（任何电源状态都保持）
###   3. 如屏幕已息屏则发送唤醒命令
###   4. 幂等：重复执行结果一致，可由守护进程定期调用
###
### 用法：
###   keep_awake.sh          # 执行一次保持唤醒设置
###   keep_awake.sh --check  # 仅检查当前状态，不修改
###
### 由 agent_autodeploy.sh 在 boot_completed 后调用，并可由 webrtc_watchdog.sh 定期兜底。

set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
LOG="$VAR_DIR/keep_awake.log"
C="androidemu-android"
mkdir -p "$VAR_DIR" 2>/dev/null || true

log() { echo "[$(date '+%F %T')] keep_awake: $*" >> "$LOG" 2>/dev/null || true; }

# 容器是否在运行
running() { [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]; }

# 安卓是否启动完成
boot_done() { [ "$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')" = "1" ]; }

# 在容器内执行命令
exec_android() { docker exec -u 0 "$C" sh -c "$1" 2>/dev/null; }

### 检查模式
if [ "${1:-}" = "--check" ]; then
    if ! running; then echo "容器未运行"; exit 1; fi
    if ! boot_done; then echo "安卓尚未启动完成"; exit 1; fi
    TIMEOUT=$(exec_android 'settings get system screen_off_timeout' | tr -d '\r\n')
    STAYON=$(exec_android 'settings get global stay_on_while_plugged_in' | tr -d '\r\n')
    echo "屏幕超时: $TIMEOUT"
    echo "充电常亮: $STAYON"
    [ "$TIMEOUT" = "2147483647" ] && [ "$STAYON" = "7" ] && echo "状态: 已保持唤醒" || echo "状态: 未完全保持唤醒"
    exit 0
fi

### 执行模式
if ! running; then log "容器未运行，跳过"; exit 0; fi
if ! boot_done; then log "安卓尚未 boot_completed，跳过（守护会重试）"; exit 0; fi

# 1. 设置屏幕超时为最大值（约24.8天）
exec_android 'settings put system screen_off_timeout 2147483647'
log "屏幕超时已设为最大值 (2147483647ms)"

# 2. 设置充电时保持屏幕常亮（7=AC/USB/无线充电任何状态都保持）
exec_android 'settings put global stay_on_while_plugged_in 7'
log "充电常亮已开启 (stay_on_while_plugged_in=7)"

# 3. svc power stayon（双重保险）
exec_android 'svc power stayon true' 2>/dev/null
log "svc power stayon true 已执行"

# 4. 如屏幕已息屏则唤醒
exec_android 'input keyevent KEYCODE_WAKEUP' 2>/dev/null
log "屏幕唤醒命令已发送"

# 5. 【3.8.9 性能加强】定期修剪应用缓存（防国内 APP 缓存膨胀挤占内存；
#    目标为保留 1G 空闲空间，空闲充足时为空操作，低频幂等无副作用）
exec_android 'pm trim-caches 1G' 2>/dev/null
log "应用缓存修剪已执行 (trim-caches 1G)"

log "保持唤醒设置完成"
exit 0
