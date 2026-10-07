#!/bin/bash
### agent_helper.sh — 云手机 Agent 的「容器内部署 + 自愈」助手（一次配好，不再手填 IP）。
###
### 【它解决什么问题】
###   fnOS 实测：bridge 容器访问「宿主局域网 IP」（如 192.168.1.11）与 127.0.0.1 都不通，
###   容器里只能走「网桥网关」（如 172.19.0.1）。而上游穿云投屏的云手机 Agent 必须在
###   安卓容器内运行，并连到宿主上的信令服务（8443）与 TURN（3478）。用局域网 IP 填，
###   日志必然出现：
###       [Agent] Connect signaling failed: dial tcp 192.168.x.x:8443: connect: network is unreachable
###   于是后台永远看不到设备在线（"手机没在线"的老毛病）。
###   compose 已注入 extra_hosts: host.docker.internal -> host-gateway，本脚本统一用
###   host.docker.internal 生成地址：与局域网 IP、网关地址、机器型号都无关，
###   换机器、换网段、重建容器都不用改。
###
### 【用法】
###   agent_helper.sh show                        打印「复制即用」的部署命令（默认）
###   agent_helper.sh deploy <宿主目录> [--tls]   把该目录内的 agent 文件拷进容器并启动
###   agent_helper.sh status                      查看容器/agent 状态与最近日志
###   agent_helper.sh watchdog install|remove|status
###                                              宿主侧守护：容器重建或 agent 退出后自动重新拉起
###
### 【可覆盖的环境变量】
###   CNAME       容器名，默认 androidemu-android
###   SIG_PORT    信令端口，默认 8443
###   TURN_PORT   TURN 端口，默认 3478
###   AGENT_ID    设备 ID，默认 androidemu
###   TURN_USER / TURN_PASS  TURN 凭据（默认取上游镜像默认值）
###   AGENT_BIN   容器内 agent 可执行文件路径，默认 /data/local/tmp/cloudphone-agent
###   AGENT_JAR   容器内 agent 依赖库路径，默认 /data/local/tmp/libsys_core.so
###   TRIM_PKGVAR 应用数据目录（日志与 pid 存放），默认 /var/apps/androidemu/var

C="${CNAME:-androidemu-android}"
SIG_PORT="${SIG_PORT:-8443}"
TURN_PORT="${TURN_PORT:-3478}"
AGENT_ID="${AGENT_ID:-androidemu}"
TURN_USER="${TURN_USER:-cloudphone_user}"
TURN_PASS="${TURN_PASS:-cloudphone_secure_password}"
AGENT_BIN="${AGENT_BIN:-/data/local/tmp/cloudphone-agent}"
AGENT_JAR="${AGENT_JAR:-/data/local/tmp/libsys_core.so}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
LOG="${VAR_DIR}/agent_helper.log"
PIDFILE="${VAR_DIR}/agent_watchdog.pid"
### 2.0.26：优先用容器自己的网桥网关（Android 会重写 /etc/hosts，host.docker.internal 常不可用）
SIG_HOST="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}} {{end}}' "$C" 2>/dev/null | awk '{print $1}')"
[ -n "$SIG_HOST" ] || SIG_HOST="host.docker.internal"

mkdir -p "$VAR_DIR" 2>/dev/null || true
log() { echo "[$(date '+%F %T')] agent_helper: $*" >> "$LOG" 2>/dev/null || true; }

### 网桥网关（作为 host.docker.internal 之外的备选地址打印出来）
gateway() {
    GW=$(docker network inspect androidemu_default --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null | tr -d '\r\n')
    if [ -z "$GW" ]; then
        GW=$(docker exec -u 0 "$C" sh -c 'ip route 2>/dev/null | awk "/^default/{print \$3; exit}"' 2>/dev/null | tr -d '\r\n')
    fi
    echo "$GW"
}

container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]
}

agent_pid() {
    docker exec -u 0 "$C" sh -c "pidof cloudphone-agent 2>/dev/null | head -1" 2>/dev/null | tr -d '\r\n'
}

boot_done() {
    [ "$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')" = "1" ]
}

### 2.0.28：先清掉所有旧实例，避免同一设备 ID 重复注册导致连接抖动（ARM 实测）
kill_all_agents() {
    docker exec -u 0 "$C" sh -c 'for p in $(pidof cloudphone-agent); do kill -9 "$p" 2>/dev/null; done' >/dev/null 2>&1 || true
    sleep 2
}

start_agent() {
    kill_all_agents
    GW="$(gateway)"
    docker exec -u 0 "$C" sh -c "chmod 755 '$AGENT_BIN' 2>/dev/null; export CP_AGENT_JAR='$AGENT_JAR'; nohup '$AGENT_BIN' -signaling ws://$SIG_HOST:$SIG_PORT -id $AGENT_ID -ice-servers 'turn:$TURN_USER:$TURN_PASS@$SIG_HOST:$TURN_PORT?transport=udp' -jar '$AGENT_JAR' > /data/local/tmp/agent.log 2>&1 &" >/dev/null 2>&1
    sleep 3
    P=$(agent_pid)
    if [ -n "$P" ]; then
        log "agent 已启动（pid=$P，signaling=ws://$SIG_HOST:$SIG_PORT，turn=$SIG_HOST:$TURN_PORT，网关备选=${GW:-未知}）"
    else
        log "agent 启动失败（signaling=ws://$SIG_HOST:$SIG_PORT）；容器内日志："
        docker exec -u 0 "$C" sh -c 'tail -5 /data/local/tmp/agent.log 2>/dev/null' 2>/dev/null | while read -r L; do log "    $L"; done
    fi
}

show_cmds() {
    GW="$(gateway)"
    cat <<EOF
================ 云手机 Agent 部署命令（复制即用） ================
容器名：$C
信令地址（容器内视角）：ws://$SIG_HOST:$SIG_PORT      ← 固定主机名，指向网桥网关
TURN 地址（容器内视角）：turn:$TURN_USER:***@$SIG_HOST:$TURN_PORT?transport=udp
当前网桥网关（备选地址，一般不需要用）：${GW:-未知}

—— 第 1 步：把 agent 文件拷进容器（在宿主上执行，路径按你本机实际改）——
docker cp <你的目录>/cloudphone-agent-amd64 $C:/data/local/tmp/cloudphone-agent
docker cp <你的目录>/libsys_core.so          $C:/data/local/tmp/libsys_core.so

—— 第 2 步：在容器内启动 agent（注意用 host.docker.internal，不要用 192.168.x.x）——
docker exec -u 0 $C sh -c "chmod 755 $AGENT_BIN && export CP_AGENT_JAR=$AGENT_JAR && nohup $AGENT_BIN -signaling ws://$SIG_HOST:$SIG_PORT -id $AGENT_ID -ice-servers 'turn:$TURN_USER:$TURN_PASS@$SIG_HOST:$TURN_PORT?transport=udp' -jar $AGENT_JAR > /data/local/tmp/agent.log 2>&1 &"

—— 第 3 步：确认进程与日志 ——
docker exec $C pidof cloudphone-agent
docker exec $C tail -5 /data/local/tmp/agent.log

—— 第 4 步（推荐）：装宿主侧守护，容器重建/agent 退出后自动拉起 ——
bash "\$0" watchdog install      # 或直接：$(basename "$0") watchdog install

提示：
· 若日志出现 x509/证书相关错误（而不是 network is unreachable），把 ws:// 换成 wss://，
  或在本机把信令服务改为非 TLS 模式后再试。
· 若日志出现 network is unreachable，说明还在用局域网 IP —— 改成 $SIG_HOST 即可。
· 云手机后台添加设备时，Android 侧地址请用宿主转发出来的 5556（127.0.0.1:5556 或 <局域网IP>:5556）。
=================================================================
EOF
}

case "${1:-show}" in
    show)
        show_cmds
        ;;
    deploy)
        DIR="${2:-}"
        [ -n "$DIR" ] && [ -d "$DIR" ] || { echo "用法：agent_helper.sh deploy <包含 agent 文件的宿主目录> [--tls]"; exit 1; }
        USE_TLS=0
        [ "${3:-}" = "--tls" ] && USE_TLS=1
        container_running || { echo "容器 $C 未运行，请先在应用面板启动"; exit 1; }
        kill_all_agents
        boot_done || echo "提示：Android 尚未 boot_completed，agent 可能起不来（等待启动完成再试）"
        for F in "$DIR"/*; do
            [ -f "$F" ] || continue
            BASE=$(basename "$F")
            case "$BASE" in
                cloudphone-agent*|*agent*) docker cp "$F" "$C:/data/local/tmp/cloudphone-agent" >/dev/null 2>&1 && echo "已拷贝 $BASE -> /data/local/tmp/cloudphone-agent" ;;
                libsys_core*|*.so)         docker cp "$F" "$C:/data/local/tmp/libsys_core.so" >/dev/null 2>&1 && echo "已拷贝 $BASE -> /data/local/tmp/libsys_core.so" ;;
                *) echo "跳过 $BASE（未识别，如需拷贝请手动 docker cp）" ;;
            esac
        done
        docker exec -u 0 "$C" sh -c "chmod 755 $AGENT_BIN" >/dev/null 2>&1 || true
        ### 2.0.42：两个文件都要在位（缺 libsys_core.so 时会话启动会报 no such file or directory）
        if docker exec -u 0 "$C" sh -c "test -s $AGENT_BIN && test -s $AGENT_JAR" >/dev/null 2>&1; then
            echo "容器内文件就绪：$(docker exec -u 0 "$C" sh -c "ls -l $AGENT_BIN $AGENT_JAR 2>/dev/null | awk '{print \$5, \$9}'" 2>/dev/null | tr '\n' ' ')"
        else
            echo "警告：容器内 $AGENT_BIN 或 $AGENT_JAR 缺失；部署目录需同时包含 cloudphone-agent-* 与 libsys_core.so"
        fi
        if [ "$USE_TLS" = "1" ]; then SIG_SCHEME="wss"; else SIG_SCHEME="ws"; fi
        GW="$(gateway)"
        docker exec -u 0 "$C" sh -c "export CP_AGENT_JAR='$AGENT_JAR'; nohup '$AGENT_BIN' -signaling $SIG_SCHEME://$SIG_HOST:$SIG_PORT -id $AGENT_ID -ice-servers 'turn:$TURN_USER:$TURN_PASS@$SIG_HOST:$TURN_PORT?transport=udp' -jar '$AGENT_JAR' > /data/local/tmp/agent.log 2>&1 &" >/dev/null 2>&1
        sleep 3
        P=$(agent_pid)
        if [ -n "$P" ]; then
            echo "agent 已启动（pid=$P，signaling=$SIG_SCHEME://$SIG_HOST:$SIG_PORT，网关备选=${GW:-未知}）"
            log "deploy 成功：pid=$P（$SIG_SCHEME://$SIG_HOST:$SIG_PORT）"
            docker exec -u 0 "$C" sh -c 'tail -5 /data/local/tmp/agent.log' 2>/dev/null
        else
            echo "agent 未启动，容器内日志："
            docker exec -u 0 "$C" sh -c 'tail -10 /data/local/tmp/agent.log 2>/dev/null' 2>/dev/null
            log "deploy 失败（$SIG_SCHEME://$SIG_HOST:$SIG_PORT）"
        fi
        ;;
    status)
        echo "容器 $C：$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null || echo 未知)"
        echo "Android boot_completed：$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')"
        echo "agent pid：$(agent_pid)"
        echo "网桥网关：$(gateway)"
        echo "host.docker.internal 解析：$(docker exec -u 0 "$C" sh -c 'getent hosts host.docker.internal 2>/dev/null || echo 未解析' 2>/dev/null | tr -d '\r\n')"
        echo "--- 容器内 agent 日志尾部 ---"
        docker exec -u 0 "$C" sh -c 'tail -8 /data/local/tmp/agent.log 2>/dev/null' 2>/dev/null || echo "(无日志)"
        ;;
    watchdog)
        ACTION="${2:-status}"
        case "$ACTION" in
            install)
                if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
                    echo "守护已在运行（pid=$(cat "$PIDFILE")）"; exit 0
                fi
                setsid nohup bash -c '
                    while :; do
                        if [ "$(docker inspect -f "{{.State.Running}}" "'"$C"'" 2>/dev/null)" = "true" ]; then
                            if [ -z "$(docker exec -u 0 "'"$C"'" sh -c "pidof cloudphone-agent 2>/dev/null | head -1" 2>/dev/null)" ]; then
                                if docker exec -u 0 "'"$C"'" sh -c "test -x '"'"$AGENT_BIN"'"'" 2>/dev/null; then
                                    bash "'"$0"'" deploy-restart >/dev/null 2>&1
                                    echo "[$(date "+%F %T")] watchdog: 已重新拉起 agent" >> "'"$LOG"'"
                                fi
                            fi
                        fi
                        sleep 60
                    done
                ' >/dev/null 2>&1 < /dev/null &
                echo $! > "$PIDFILE"
                echo "守护已安装（pid=$(cat "$PIDFILE")，每 60 秒检查一次，容器重建后会自动重新拉起 agent）"
                log "watchdog install pid=$(cat "$PIDFILE")"
                ;;
            remove)
                [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
                rm -f "$PIDFILE"
                echo "守护已移除"
                log "watchdog remove"
                ;;
            status)
                if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
                    echo "守护运行中（pid=$(cat "$PIDFILE")）"
                else
                    echo "守护未运行"
                fi
                ;;
            *) echo "用法：agent_helper.sh watchdog install|remove|status" ;;
        esac
        ;;
    deploy-restart)
        start_agent
        ;;
    *)
        show_cmds
        ;;
esac

exit 0
