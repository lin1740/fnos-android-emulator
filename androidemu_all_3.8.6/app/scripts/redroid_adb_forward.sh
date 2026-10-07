#!/bin/bash
### redroid_adb_forward.sh — 让安卓（redroid）容器的 ADB 端口在宿主上同时支持
### 「127.0.0.1:5556」与「<局域网IP>:5556」，包括 NAS 本机自身的访问。
###
### 修复演进：
###   2.0.8  以宿主 socat 转发替代 Docker 发布（fnOS 无宿主回环、内核缺 REDIRECT）。
###   2.0.10 修复上一版致命缺陷：socat 常驻不看目标，容器重建后 IP 变化（172.19.0.3→.2）
###          仍指向旧 IP，客户端连上即被断开 → 「ADB 握手失败: 连接中断…EOF」、画面黑屏。
###          本版守护：容器 IP 变化或体检失败 → 立即用新 IP 重建 socat；体检不依赖 ADB 报文，
###          而是「目标端口可达 + 经转发端口连接不会被立刻断开」，避免误判导致反复重建。
###          清理旧 socat 用按端口属主 + 命令行精确匹配（守护命令行不含该串，不会自杀）。
###   2.0.85 监听地址可配置：默认 127.0.0.1（上架安全要求，避免无鉴权端口暴露公网），
###          用户可在面板一键切换为 0.0.0.0（局域网其他设备可用 ADB 连接）。
###
### 用法：redroid_adb_forward.sh install | remove | status | supervise（内部）

set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
C="${CNAME:-androidemu-android}"
### 2.0.35：ADB 转发端口可由 ${TRIM_PKGVAR}/ports.conf 的 ADB_PORT 覆盖（默认 5556）。
### 注意：必须在 PORT= 赋值之前设置 ADB_PORT 才生效。
if [ -z "${ADB_PORT:-}" ] && [ -f "${TRIM_PKGVAR:-/var/apps/androidemu/var}/ports.conf" ]; then
    _ap=$(sed -n 's/^ADB_PORT=//p' "${TRIM_PKGVAR:-/var/apps/androidemu/var}/ports.conf" 2>/dev/null | head -n1)
    case "$_ap" in ''|*[!0-9]*) : ;; *) export ADB_PORT="$_ap" ;; esac
fi
PORT="${ADB_PORT:-5556}"
TARGET="${ADB_TARGET_PORT:-5555}"
### 2.0.85：ADB 监听地址可配置（上架安全要求：默认仅本机 127.0.0.1，
###         避免无鉴权端口暴露公网）。用户可在面板一键切换为 0.0.0.0（局域网可用）。
###         配置来自 ${TRIM_PKGVAR}/ports.conf 的 ADB_BIND 字段。
BIND_HOST="127.0.0.1"
if [ -f "${TRIM_PKGVAR:-/var/apps/androidemu/var}/ports.conf" ]; then
    _ab=$(sed -n 's/^ADB_BIND=//p' "${TRIM_PKGVAR:-/var/apps/androidemu/var}/ports.conf" 2>/dev/null | head -n1)
    case "$_ab" in
        0.0.0.0|127.0.0.1) BIND_HOST="$_ab" ;;
    esac
fi
export ADB_BIND="$BIND_HOST"
### 2.0.58：pid/日志原先写死 /tmp，若先被其它用户创建，包用户无法写入 → 守护直接起不来
###         （验收实测：/tmp/androidemu-adb-forward.log 属主为 root，line 176 Permission denied，
###          导致 ADB 转发守护完全没有运行、5556 不监听）。改为写应用数据目录，并做可写性回退。
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
mkdir -p "$VAR_DIR" 2>/dev/null || true
PIDFILE="$VAR_DIR/adb_forward.pid"
LOGFILE="$VAR_DIR/adb_forward.log"
if [ -f "$LOGFILE" ] && [ ! -w "$LOGFILE" ]; then LOGFILE="/tmp/.androidemu-adb-forward.$$.log"; fi
if ! ( : >> "$LOGFILE" ) 2>/dev/null; then LOGFILE="/tmp/.androidemu-adb-forward.$$.log"; fi
if [ -f "$PIDFILE" ] && [ ! -w "$PIDFILE" ]; then PIDFILE="/tmp/.androidemu-adb-forward.$$.pid"; fi
if ! ( : >> "$PIDFILE" ) 2>/dev/null; then PIDFILE="/tmp/.androidemu-adb-forward.$$.pid"; fi
CHECK_INTERVAL="${ADB_FORWARD_CHECK_INTERVAL:-20}"

### 2.0.36：转发器不再是 socat 硬依赖 —— 优先 socat；宿主没有 socat 时回退到宿主 python3
### 内置转发（ARM 真机实测：部分 fnOS 设备未安装 socat，导致 ADB 转发完全不可用）。
ADB_PY="${TRIM_PKGVAR:-/var/apps/androidemu/var}/adb_forward.py"
FWD=""
write_py() {
    mkdir -p "$(dirname "$ADB_PY")" 2>/dev/null || true
    cat > "$ADB_PY" <<'PYEOF'
#!/usr/bin/env python3
import socket, sys, threading
PORT = int(sys.argv[1]); BIND = sys.argv[2]; HOST = sys.argv[3]; TPORT = int(sys.argv[4])
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except Exception: pass
            try: s.close()
            except Exception: pass
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((BIND, PORT))
srv.listen(128)
while True:
    try:
        c, _ = srv.accept()
    except Exception:
        continue
    try:
        u = socket.create_connection((HOST, TPORT), timeout=5)
    except Exception:
        try: c.close()
        except Exception: pass
        continue
    threading.Thread(target=pipe, args=(c, u), daemon=True).start()
    threading.Thread(target=pipe, args=(u, c), daemon=True).start()
PYEOF
    chmod 755 "$ADB_PY" 2>/dev/null || true
}
pick_forwarder() {
    if command -v socat >/dev/null 2>&1; then FWD="socat"; return 0; fi
    if command -v python3 >/dev/null 2>&1; then FWD="python3"; write_py; return 0; fi
    FWD=""; return 1
}
start_one_forward() {
    case "$FWD" in
        socat)   socat TCP-LISTEN:"$PORT",bind="$BIND_HOST",fork,reuseaddr TCP:"$1":"$TARGET" >>"$LOGFILE" 2>&1 & ;;
        python3) python3 "$ADB_PY" "$PORT" "$BIND_HOST" "$1" "$TARGET" >>"$LOGFILE" 2>&1 & ;;
        *)       return 1 ;;
    esac
    SPID=$!
}

container_ip() {
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$C" 2>/dev/null | tr -d '\r\n'
}
is_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true; }

port_owner_pids() {
    ss -lntp 2>/dev/null | awk -v pat=":$PORT " '$4 ~ pat { if (match($0, /pid=[0-9]+/)) print substr($0, RSTART+4, RLENGTH-4) }' | sort -u
}
### 2.0.39：不依赖 pkill（ARM 实测该设备没有 pkill/procps），用 ps + kill 精确清理。
kill_by_pattern() {
    PAT="$1"
    for p in $(ps -eo pid,args 2>/dev/null | grep -F "$PAT" | grep -v grep | awk '{print $1}'); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null || true
    done
}

kill_port_owners() {
    ### 按监听端口属主清理
    for p in $(port_owner_pids); do
        [ "$p" = "$$" ] && continue
        kill "$p" 2>/dev/null || true
    done
    ### 兜底：命令行精确匹配（守护自身命令行是 "bash <script> supervise"，不含此串）
    kill_by_pattern "socat TCP-LISTEN:$PORT"
    kill_by_pattern "adb_forward.py $PORT"
    sleep 1
}

### 目标端口是否可达（容器 adb 是否活着）
target_alive() { (exec 3<>"/dev/tcp/$1/$TARGET") >/dev/null 2>&1; }

### 经转发端口连接后，连接是否没有被立刻断开（目标不可达时 socat 会立即 EOF）
forward_ok() {
    exec 3<>"/dev/tcp/127.0.0.1/$PORT" 2>/dev/null || return 1
    local rc=0
    IFS= read -r -n 1 -t 2 _ <&3 2>/dev/null || rc=$?
    exec 3<&- 2>/dev/null
    if [ "$rc" -eq 0 ] || [ "$rc" -gt 128 ]; then return 0; fi
    return 1
}

health_ok() {
    local r; r="$(container_ip)"
    [ -n "$r" ] || return 1
    target_alive "$r" || return 1
    forward_ok
}

supervisor_alive() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

stop_forward() {
    if supervisor_alive; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
    rm -f "$PIDFILE"
    kill_port_owners
    ### 2.0.37：端口变更时清掉「旧端口」上的转发进程（否则改端口后旧端口仍在监听）。
    ### 只清本应用自己的转发器：python 转发脚本名唯一；socat 仅清目标指向本容器的那些。
    ### 2.0.38：还必须杀掉「所有」本脚本的守护进程 —— 只杀 PIDFILE 里那一个不够：
    ### 端口变更后，旧守护仍在运行，会按旧环境变量把自己的转发器重新拉起（实测 5557 反复复活）。
    kill_by_pattern "redroid_adb_forward.sh supervise"
    kill_by_pattern "adb_forward.py "
    RIPX="$(container_ip)"
    if [ -n "$RIPX" ]; then
        for p in $(ps -eo pid,args 2>/dev/null | grep -F "socat TCP-LISTEN:" | grep -F "TCP:$RIPX:$TARGET" | grep -v grep | awk '{print $1}'); do
            [ "$p" = "$$" ] && continue
            kill -9 "$p" 2>/dev/null || true
        done
    fi
    sleep 1
}

### 内部：守护循环（用 bash 运行；每 CHECK_INTERVAL 秒复查一次）
supervise() {
    local LAST="" SPID="" R need
    pick_forwarder || { echo "[$(date '+%F %T')] 未找到 socat 或 python3，无法转发" >>"$LOGFILE"; sleep 60; return 1; }
    while true; do
        R="$(container_ip)"
        [ -n "$R" ] || R="$LAST"
        need=0
        if [ -z "$SPID" ] || ! kill -0 "$SPID" 2>/dev/null; then need=1; fi
        if [ -n "$R" ] && [ "$R" != "$LAST" ]; then need=1; fi
        if [ "$need" = "0" ] && ! { target_alive "$R" && forward_ok; }; then need=1; fi
        if [ "$need" = "1" ] && [ -n "$R" ]; then
            [ -n "$SPID" ] && kill "$SPID" 2>/dev/null
            kill_port_owners
            start_one_forward "$R"
            LAST="$R"
            echo "[$(date '+%F %T')] forward -> $R:$TARGET (转发器 $FWD pid $SPID)" >>"$LOGFILE"
            sleep 2
        fi
        sleep "$CHECK_INTERVAL"
    done
}

start_forward() {
    if ! pick_forwarder; then
        echo "redroid_adb_forward: 宿主既没有 socat 也没有 python3，无法提供 ADB 转发（可在应用面板查看提示）" >&2; return 1
    fi
    if ! is_running "$C"; then
        echo "redroid_adb_forward: $C 未运行，跳过（容器启动后会自动重试）"; return 0
    fi
    RIP="$(container_ip)"
    [ -n "$RIP" ] || { echo "redroid_adb_forward: 无法取得容器 IP" >&2; return 1; }

    stop_forward
    nohup bash "$SELF" supervise >>"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    for i in $(seq 1 8); do
        sleep 2
        if health_ok; then
            echo "redroid_adb_forward: 已监听 $BIND_HOST:$PORT → $(container_ip):$TARGET（转发器 $FWD），端到端 ADB 通道正常"
            return 0
        fi
    done
    echo "redroid_adb_forward: 已启动守护，但体检未通过（详见 $LOGFILE）" >&2
    return 1
}

case "${1:-install}" in
    install) start_forward ;;
    remove)  stop_forward; echo "redroid_adb_forward: 已停止 ADB 转发" ;;
    supervise) supervise ;;
    status)
        if supervisor_alive; then echo -n "守护: running(pid $(cat "$PIDFILE")) / "; else echo -n "守护: not running / "; fi
        if health_ok; then echo "ADB 通道: OK → $(container_ip):$TARGET"; else echo "ADB 通道: FAIL"; fi
        ;;
    *) echo "redroid_adb_forward: 未知参数 '$1'（install|remove|status）" >&2 ;;
esac
exit 0
