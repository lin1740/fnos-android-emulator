#!/bin/bash
### 3.9.9-r2：飞牛应用回调/看护的 PATH 常不含 /usr/sbin（实测看护进程 environ 无 PATH），
### 而 runuser 位于 /usr/sbin/runuser。缺它时降权分支会静默回退成 高权限常驻
### （socat 变成 高权限进程、卸载时包用户杀不掉），或 setsid 直接报
### "failed to execute runuser"。这里只补缺失段，不改动原有 PATH 与业务逻辑。
case ":${PATH:-}:" in
    *:/usr/sbin:*) ;;
    *) export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/sbin:/sbin" ;;
esac

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
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
mkdir -p "$VAR_DIR" 2>/dev/null || true
PIDFILE="$VAR_DIR/adb_forward.pid"
LOGFILE="$VAR_DIR/adb_forward.log"
if [ -f "$LOGFILE" ] && [ ! -w "$LOGFILE" ]; then LOGFILE="/tmp/.androidemu-adb-forward.$$.log"; fi
if ! ( : >> "$LOGFILE" ) 2>/dev/null; then LOGFILE="/tmp/.androidemu-adb-forward.$$.log"; fi
if [ -f "$PIDFILE" ] && [ ! -w "$PIDFILE" ]; then PIDFILE="/tmp/.androidemu-adb-forward.$$.pid"; fi
if ! ( : >> "$PIDFILE" ) 2>/dev/null; then PIDFILE="/tmp/.androidemu-adb-forward.$$.pid"; fi
CHECK_INTERVAL="${ADB_FORWARD_CHECK_INTERVAL:-20}"

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
    local LAST="" SPID="" R need _idle=0
    pick_forwarder || { echo "[$(date '+%F %T')] 未找到 socat 或 python3，无法转发" >>"$LOGFILE"; sleep 60; return 1; }
    while true; do
        ### 3.9.3：应用停用自清 —— fnOS 停用只停容器，不会调用 cmd/main stop，
        ### 旧版转发守护会一直空转（审核侧看就是「停用了还有进程在跑」）。
        ### 容器连续 4 分钟未运行即判定停用：撤掉转发器后退出；启用时由 cmd/main start 重新拉起。
        if ! is_running "$C"; then
            [ "$_idle" = "0" ] && _idle=$(date +%s)
            if [ $(( $(date +%s) - _idle )) -ge 240 ]; then
                echo "[$(date '+%F %T')] 容器已停止超过 240s（判定应用停用）→ 转发守护退出" >>"$LOGFILE"
                [ -n "$SPID" ] && kill "$SPID" 2>/dev/null
                kill_port_owners 2>/dev/null || true
                exit 0
            fi
        else
            _idle=0
        fi
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

    ### 3.9.2 修正（ADB 直连不通的真因）：redroid 的 adbd 默认是 **stopped**，
    ### 且 service.adb.tcp.port 为空。只做 socat 转发而不启动 adbd，转发表面上在、
    ### 实际连上去立即断，实测 5555 根本没有进程监听。这里先保证 adbd 跑起来。
    ensure_adbd() {
        docker exec -u 0 "$C" sh -c "[ \"\$(getprop init.svc.adbd)\" = running ] && exit 0; setprop service.adb.tcp.port $TARGET; start adbd 2>/dev/null || setprop ctl.start adbd 2>/dev/null" >/dev/null 2>&1
        _k=0
        while [ "$_k" -lt 8 ]; do
            if docker exec -u 0 "$C" sh -c "netstat -tln 2>/dev/null | grep -q :$TARGET || ss -tln 2>/dev/null | grep -q :$TARGET" >/dev/null 2>&1; then
                return 0
            fi
            _k=$((_k + 1)); sleep 2
        done
        return 1
    }
    if ! ensure_adbd; then
        echo "redroid_adb_forward: adbd 未能启动（容器内 init 未放行），ADB 直连不可用" >&2
    fi

    stop_forward
    ### 3.9.3：幂等去重 —— 安装/启用/巡检都会调用 install，实测会残留两个 supervise
    ### 同时抢 5556 端口（改端口后又互相复活）。这里起新的之前把旧的全清掉。
    for _p in $(ps -eo pid,args 2>/dev/null | grep -F "redroid_adb_forward.sh supervise" | grep -v grep | awk '{print $1}'); do
        [ "$_p" = "$$" ] && continue
        kill -9 "$_p" 2>/dev/null || true
    done
    ### 3.9.9 复测修订（2026-11-08）：本脚本可能被安装/升级回调以系统身份调用
    ### （例如容器刚起时 runtime_guard.sh 会拉起 ADB 转发）。若直接 spawn，supervise
    ### 就以 高权限常驻；降权看护随后又杀不掉它，形成 高权限版 + 降权版并存。
    ### 这里统一以包用户 spawn，所有调用路径（系统身份或包用户）都得到同一个身份。
    if [ "$(id -u)" = "0" ] && command -v runuser >/dev/null 2>&1 \
       && id "${TRIM_RUN_USERNAME:-docker-androidemu}" >/dev/null 2>&1; then
        nohup runuser -u "${TRIM_RUN_USERNAME:-docker-androidemu}" -- \
            env TRIM_PKGVAR="$VAR_DIR" CNAME="$C" ADB_PORT="$PORT" \
                ADB_TARGET_PORT="$TARGET" ADB_BIND="$BIND_HOST" \
                ADB_FORWARD_CHECK_INTERVAL="$CHECK_INTERVAL" \
                bash "$SELF" supervise >>"$LOGFILE" 2>&1 &
    else
        nohup bash "$SELF" supervise >>"$LOGFILE" 2>&1 &
    fi
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
