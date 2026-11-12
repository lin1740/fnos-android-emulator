#!/bin/bash
### tune_resources.sh — 按宿主实际 CPU / 内存动态设置容器资源上限（3.9.0）
###
### 【为什么需要】
### 固定写死「3 核 / 5G」在高配机器上会白白限死性能（用户以为很卡），
### 在低配机器上又拦不住跑飞。这里按宿主真实硬件计算：
###   · 安卓容器 CPU = max(2, 核数-1) —— 给宿主留 1 核，双核及以下等于不限制
###   · 安卓容器内存 = min(70% 总内存, 总内存-1.5G)，夹在 [2G, 12G]
###     （上限 12G：安卓实际用不到更多；下限/预留保证宿主不被拖死）
###   · 进程数上限按内存档位 4096 / 8192 / 16384，防 fork 炸弹
###   · 画面服务很轻（实测 74~110MB），CPU = max(1, 核数/2)，内存 768M（3.9.2 由 1G 下调）
###
### 幂等：值没变化时不改写文件；compose 缺失时静默跳过（不影响安装/启动）。
### 用法：bash tune_resources.sh [compose 路径]
set -u

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
C="${1:-$APP_DIR/docker/docker-compose.yaml}"
[ -f "$C" ] || exit 0

NCPU=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
case "$NCPU" in ''|*[!0-9]*) NCPU=4 ;; esac
[ "$NCPU" -ge 1 ] || NCPU=4

MEM_MB=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
case "$MEM_MB" in ''|*[!0-9]*) MEM_MB=0 ;; esac

### 安卓容器
if [ "$NCPU" -le 2 ]; then
    A_CPU="$NCPU"                       # 双核及以下：不限制（等于全部可用）
else
    A_CPU=$((NCPU - 1))                 # 给宿主留 1 核
fi

if [ "$MEM_MB" -gt 0 ]; then
    A_MEM=$((MEM_MB * 65 / 100))        # 65% 总内存（3.9.2：由 70% 下调，给宿主多留余量）
    ### 3.9.2：宿主预留量从「1.5G」提到「3G（<12G 的机器）/ 4G（>=12G 的机器）」。
    ### 实测依据（本机 x86，总内存 7420MB）：按旧公式（70%、预留 1.5G）给安卓 5194m，
    ### 宿主只剩 2.2G，而 fnOS 自带虚拟机还要占掉约 3G swap → 宿主 swap 长期打满，
    ### 容器内 lmkd 读到 /proc/swaps（就是宿主那份）判定「内存严重不足」，
    ### 对已装应用无差别回收；安卓容器自身实测峰值只用到 1.0~2.3G，5.2G 限额长期闲置。
    ### 现在改成 4348m：既有充足余量（约为实测峰值的 1.9 倍），又给宿主留出 3G。
    ### 内存仍然「够用且有余」，不是靠掐死安卓换稳定。
    if [ "$MEM_MB" -lt 12288 ]; then
        _reserve=$((MEM_MB - 3072))     # 小机器：给宿主留 3G
    else
        _reserve=$((MEM_MB - 4096))     # 大机器：给宿主留 4G
    fi
    [ "$A_MEM" -gt "$_reserve" ] && A_MEM="$_reserve"
    [ "$A_MEM" -lt 2048 ] && A_MEM=2048 # 下限 2G（低于此安卓跑不起来）
    [ "$A_MEM" -gt 12288 ] && A_MEM=12288 # 上限 12G（安卓用不到更多）
    if [ "$MEM_MB" -le 4096 ]; then
        A_PIDS=4096
    elif [ "$MEM_MB" -lt 16384 ]; then
        A_PIDS=8192
    else
        A_PIDS=16384
    fi
else
    A_MEM=0; A_PIDS=8192                # 读不到内存信息时保持宽松默认
fi

### 画面服务（轻量）
W_CPU=$((NCPU / 2)); [ "$W_CPU" -lt 1 ] && W_CPU=1

### 写回 compose（3.9.1：优先 Go 版 editcompose 结构化编辑；awk 作为回退）
_edit_res() {
    local GWBIN="$APP_DIR/server/gateway_amd64"
    [ "$(uname -m 2>/dev/null)" = "aarch64" ] && GWBIN="$APP_DIR/server/gateway_arm64"
    [ -x "$GWBIN" ] || return 1
    "$GWBIN" editcompose "$C" set-scalar redroid cpus "\"$A_CPU.0\"" >/dev/null 2>&1 || return 1
    [ "$A_MEM" -gt 0 ] && "$GWBIN" editcompose "$C" set-scalar redroid mem_limit "${A_MEM}m" >/dev/null 2>&1 || return 1
    "$GWBIN" editcompose "$C" set-scalar redroid pids_limit "$A_PIDS" >/dev/null 2>&1 || return 1
    "$GWBIN" editcompose "$C" set-scalar webrtc cpus "\"$W_CPU.0\"" >/dev/null 2>&1 || return 1
    "$GWBIN" editcompose "$C" set-scalar webrtc mem_limit 768m >/dev/null 2>&1 || return 1
    "$GWBIN" editcompose "$C" set-scalar webrtc pids_limit 2048 >/dev/null 2>&1 || return 1
    return 0
}
if _edit_res; then
    echo "tune_resources: 已按宿主(${NCPU}核/${MEM_MB}MB)设置上限 — 安卓 ${A_CPU}核/${A_MEM}m/${A_PIDS}进程，画面 ${W_CPU}核/768m/2048进程"
else
TMP="$C.tune.$$"
awk -v acpu="$A_CPU" -v amem="$A_MEM" -v apids="$A_PIDS" \
    -v wcpu="$W_CPU" '
/^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
    svc = $1; sub(/:.*/, "", svc)
}
/^[[:space:]]*cpus:/ {
    if (svc == "redroid")      { print "    cpus: \"" acpu ".0\""; next }
    if (svc == "webrtc")       { print "    cpus: \"" wcpu ".0\""; next }
}
/^[[:space:]]*mem_limit:/ {
    if (svc == "redroid" && amem > 0) { print "    mem_limit: " amem "m"; next }
    if (svc == "webrtc")              { print "    mem_limit: 768m"; next }
}
/^[[:space:]]*pids_limit:/ {
    if (svc == "redroid")      { print "    pids_limit: " apids; next }
    if (svc == "webrtc")       { print "    pids_limit: 2048"; next }
}
{ print }
' "$C" > "$TMP" 2>/dev/null || { rm -f "$TMP" 2>/dev/null; exit 0; }

if cmp -s "$C" "$TMP" 2>/dev/null; then
    rm -f "$TMP" 2>/dev/null
else
    cat "$TMP" > "$C" 2>/dev/null || cp -f "$TMP" "$C" 2>/dev/null || true
    rm -f "$TMP" 2>/dev/null
    echo "tune_resources: 已按宿主(${NCPU}核/${MEM_MB}MB)设置上限 — 安卓 ${A_CPU}核/${A_MEM}m/${A_PIDS}进程，画面 ${W_CPU}核/768m/2048进程"
fi
fi
exit 0
