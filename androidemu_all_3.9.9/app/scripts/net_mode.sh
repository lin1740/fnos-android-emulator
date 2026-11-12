#!/bin/bash
### 3.9.9-r2：补齐 /usr/sbin（runuser 所在目录），避免飞牛回调 PATH 缺失时
### 网关重启的降权分支静默失效。
case ":${PATH:-}:" in
    *:/usr/sbin:*) ;;
    *) export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/sbin:/sbin" ;;
esac

### net_mode.sh — 一键切换访问模式（局域网直连 / 公网端口映射 / 内网穿透·反向代理）。
###
### 用法：
###   net_mode.sh lan                      # 局域网直连（默认）
###   net_mode.sh wan  <域名或公网IP> [端口]   # 公网端口映射（WebRTC，需 UDP 可达）
###   net_mode.sh proxy <域名或IP>    [端口]   # 内网穿透/反向代理（自动 USE_TLS=false，走 TCP）
###   net_mode.sh https on|off             # 8443 直连 HTTPS 开关（独立于模式，持久化）
###   net_mode.sh <模式> ... --no-restart      # 只写配置不重建容器（供安装/升级阶段调用）
###   net_mode.sh                          # 不带参数：按已保存配置重新应用（幂等）
###
### HTTPS 开关（3.9.1）：
###   默认（lan/lanhttp/wan 三种模式）均为 USE_TLS=true —— 任何环境优先 HTTPS。
###   on  → 显式开启（幂等）
###   off → 仅在你确实需要明文时关闭（proxy 模式恒为明文，开关在 proxy 下不生效——TLS 由反代终结）
###   自签证书：浏览器首次访问需确认「继续访问」；如需无警告，可把域名证书放到镜像 certs 目录。
###   开关保存在 var/tls.conf，重放（升级/改端口）自动继承，不会被模式切换覆盖。
###
### 作用：仅修改 webrtc 服务的 PUBLIC_IP / USE_TLS / EXTERNAL_SIGNALING_PORT 三个环境变量，
###       同步 compose 到 /docker，然后按需重建 webrtc 容器（数据卷保持不变）。
### 幂等：重复执行结果一致；compose 缺失时安全退出。

set -u

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"
CONF="$VAR_DIR/net.conf"
mkdir -p "$VAR_DIR" 2>/dev/null || true

NO_RESTART=0
ARGS=""
for a in "$@"; do
    if [ "$a" = "--no-restart" ]; then NO_RESTART=1; else ARGS="$ARGS $a"; fi
done
# shellcheck disable=SC2086
set -- $ARGS

PORTS_CONF="$VAR_DIR/ports.conf"
P_WEB="8443"; P_EXT=""; P_TURN="3478"; P_ADB="5556"
if [ -f "$PORTS_CONF" ]; then
    _v=$(sed -n 's/^WEB_PORT=//p' "$PORTS_CONF" | head -n1); [ -n "$_v" ] && P_WEB="$_v"
    _v=$(sed -n 's/^EXT_PORT=//p' "$PORTS_CONF" | head -n1); [ -n "$_v" ] && P_EXT="$_v"
    _v=$(sed -n 's/^TURN_PORT=//p' "$PORTS_CONF" | head -n1); [ -n "$_v" ] && P_TURN="$_v"
    _v=$(sed -n 's/^ADB_PORT=//p' "$PORTS_CONF" | head -n1); [ -n "$_v" ] && P_ADB="$_v"
fi
case "$P_WEB" in ''|*[!0-9]*) P_WEB=8443 ;; esac
case "$P_TURN" in ''|*[!0-9]*) P_TURN=3478 ;; esac
case "$P_ADB" in ''|*[!0-9]*) P_ADB=5556 ;; esac
case "$P_EXT" in ''|*[!0-9]*) P_EXT="" ;; esac

MODE="${1:-}"
HOST_ARG="${2:-}"
PORT_ARG="${3:-}"

### 3.9.1：同 detect_net.sh —— 取真实局域网 IP，避免写成 docker 网桥
if [ -f "$(dirname "$0")/net_util.sh" ]; then . "$(dirname "$0")/net_util.sh"; fi
if command -v ae_lan_ip >/dev/null 2>&1; then
    LAN_IP="$(ae_lan_ip)"
else
    LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[ -z "$LAN_IP" ] && LAN_IP="127.0.0.1"

### 读取已保存配置（无参数时按旧配置重放；有参数时参数优先）
OLD_MODE=""; OLD_HOST=""; OLD_PORT=""
if [ -f "$CONF" ]; then
    OLD_MODE=$(sed -n 's/^MODE=//p' "$CONF" | head -n1)
    OLD_HOST=$(sed -n 's/^HOST=//p' "$CONF" | head -n1)
    OLD_PORT=$(sed -n 's/^PORT=//p' "$CONF" | head -n1)
fi
[ -z "$MODE" ] && MODE="${OLD_MODE:-lan}"

### 3.9.1：HTTPS 直连独立开关（持久化在 tls.conf，模式切换不覆盖）
TLS_CONF="$VAR_DIR/tls.conf"
TLS_OVERRIDE=""
if [ -f "$TLS_CONF" ]; then
    TLS_OVERRIDE=$(sed -n 's/^TLS_OVERRIDE=//p' "$TLS_CONF" | head -n1)
fi
case "$TLS_OVERRIDE" in on|off) ;; *) TLS_OVERRIDE="" ;; esac

if [ "$MODE" = "https" ]; then
    ACT="${2:-}"
    case "$ACT" in on|off) ;; *)
        echo "net_mode: 用法 net_mode.sh https on|off" >&2; exit 1 ;;
    esac
    { echo "TLS_OVERRIDE=$ACT"; echo "UPDATED=$(date '+%F %T')"; } > "$TLS_CONF" 2>/dev/null || true
    TLS_OVERRIDE="$ACT"
    MODE="${OLD_MODE:-lan}"; HOST_ARG="${OLD_HOST:-}"; PORT_ARG="${OLD_PORT:-}"
    echo "net_mode: HTTPS 直连开关 -> $ACT（按当前模式 $MODE 应用）"
fi

case "$MODE" in
    lan|lanhttp)
        PUB="$LAN_IP"; TLS="true"; EXT="${P_EXT:-$P_WEB}"; HOST_SAVE=""; PORT_SAVE="${P_EXT:-$P_WEB}"
        ### 3.9.1：局域网默认也用 HTTPS（用户要求"任何环境优先 HTTPS"）。
        ### 自签证书浏览器首次需确认；如确需明文：net_mode.sh https off。
        [ "$TLS_OVERRIDE" = "off" ] && TLS="false"
        ;;
    wan)
        PUB="${HOST_ARG:-${OLD_HOST:-$LAN_IP}}"
        EXT="${PORT_ARG:-${OLD_PORT:-${P_EXT:-$P_WEB}}}"
        TLS="true"; HOST_SAVE="$PUB"; PORT_SAVE="$EXT"
        [ "$TLS_OVERRIDE" = "off" ] && TLS="false"
        ;;
    proxy)
        PUB="${HOST_ARG:-${OLD_HOST:-$LAN_IP}}"
        EXT="${PORT_ARG:-${OLD_PORT:-${P_EXT:-443}}}"
        TLS="false"; HOST_SAVE="$PUB"; PORT_SAVE="$EXT"
        ;;
    *)
        echo "net_mode: 未知模式 '$MODE'（可用：lan|lanhttp|wan|proxy）" >&2
        exit 1
        ;;
esac
[ "$MODE" = "proxy" ] && [ "$TLS_OVERRIDE" = "on" ] && \
    echo "net_mode: proxy 模式恒为明文（TLS 由反向代理终结），https 开关不生效"

### 2.0.43：coturn 的 external-ip 只接受 IP。用户常填域名（公网/穿透场景），
### 直接写进 PUBLIC_IP 会让画面服务启动异常（表现为"局域网能用、公网/穿透打不开"）。
### 这里把「对外主机」与「PUBLIC_IP」分离：net.conf 保留域名用于面板链接，
### 传给容器的 PUBLIC_IP 一律用可解析到的 IP（域名解析 → 探测到的出口公网 IP → 局域网 IP）。
PUBLIC_IP_FOR_CONTAINER="$PUB"
case "$PUB" in
    ''|*[!0-9.]*)   ### 不是 IPv4（视为域名）
        RESOLVED=""
        if command -v getent >/dev/null 2>&1; then
            RESOLVED=$(getent hosts "$PUB" 2>/dev/null | awk '{print $1; exit}')
        fi
        if [ -z "$RESOLVED" ] && command -v nslookup >/dev/null 2>&1; then
            RESOLVED=$(nslookup "$PUB" 2>/dev/null | awk '/^Address: /{print $2; exit}')
        fi
        if [ -n "$RESOLVED" ]; then
            PUBLIC_IP_FOR_CONTAINER="$RESOLVED"
            echo "net_mode: 域名 $PUB 解析为 $RESOLVED（写入容器的 PUBLIC_IP 用 IP，面板地址仍用域名）"
        else
            DETECTED_PUB=""
            [ -f "$VAR_DIR/net-detect.conf" ] && DETECTED_PUB=$(sed -n 's/^PUBLIC_IP=//p' "$VAR_DIR/net-detect.conf" 2>/dev/null | head -n1)
            case "$DETECTED_PUB" in ''|*[!0-9.]*) DETECTED_PUB="$LAN_IP" ;; esac
            PUBLIC_IP_FOR_CONTAINER="$DETECTED_PUB"
            echo "net_mode: 域名 $PUB 无法解析，容器 PUBLIC_IP 回退为 $PUBLIC_IP_FOR_CONTAINER（面板地址仍用域名 $PUB）"
        fi
        ;;
esac

### 写配置文件（供面板显示与后续重放）
{
    echo "MODE=$MODE"
    echo "HOST=$HOST_SAVE"
    echo "PORT=$PORT_SAVE"
    echo "UPDATED=$(date '+%F %T')"
} > "$CONF" 2>/dev/null || true

[ -f "$COMPOSE" ] || { echo "net_mode: compose 不存在：$COMPOSE"; exit 0; }

### 修改 environment 块中的五个键（3.9.1：优先 Go 版 editcompose 结构化编辑，awk 回退）
### 注意：这五个键都在 **webrtc** 服务的 environment 里，不是 redroid！
### 历史 bug：曾把服务名写成 redroid，editcompose 返回成功但什么都没改（静默失效），
### 表现为 net_mode 报告 USE_TLS=true 而 compose/容器仍是旧值。
_edit_compose_env() {
    local GWBIN="$APP_DIR/server/gateway_amd64"
    [ "$(uname -m 2>/dev/null)" = "aarch64" ] && GWBIN="$APP_DIR/server/gateway_arm64"
    [ -x "$GWBIN" ] || return 1
    local k
    for k in PUBLIC_IP USE_TLS EXTERNAL_SIGNALING_PORT SIGNALING_PORT EXTERNAL_TURN_PORT; do
        "$GWBIN" editcompose "$COMPOSE" set-env webrtc "$k" - >/dev/null 2>&1 || return 1
    done
    "$GWBIN" editcompose "$COMPOSE" set-env webrtc "PUBLIC_IP=$PUBLIC_IP_FOR_CONTAINER" >/dev/null 2>&1 || return 1
    "$GWBIN" editcompose "$COMPOSE" set-env webrtc "USE_TLS=$TLS" >/dev/null 2>&1 || return 1
    "$GWBIN" editcompose "$COMPOSE" set-env webrtc "EXTERNAL_SIGNALING_PORT=$EXT" >/dev/null 2>&1 || return 1
    "$GWBIN" editcompose "$COMPOSE" set-env webrtc "SIGNALING_PORT=$P_WEB" >/dev/null 2>&1 || return 1
    "$GWBIN" editcompose "$COMPOSE" set-env webrtc "EXTERNAL_TURN_PORT=$P_TURN" >/dev/null 2>&1 || return 1
    # 写后必须校验：editcompose 可能「静默成功」或留下重复键（compose 后者生效，
    # 会盖掉新值）。任一键不存在 / 不唯一 / 值不对，都交给 awk 回退重写。
    for k in PUBLIC_IP USE_TLS EXTERNAL_SIGNALING_PORT SIGNALING_PORT EXTERNAL_TURN_PORT; do
        [ "$(grep -c -- "- ${k}=" "$COMPOSE")" = "1" ] || return 1
    done
    grep -q -- "- USE_TLS=$TLS" "$COMPOSE" || return 1
    grep -q -- "- PUBLIC_IP=$PUBLIC_IP_FOR_CONTAINER" "$COMPOSE" || return 1
    return 0
}
if ! _edit_compose_env; then
    TMP="$(mktemp)" || exit 0
    awk -v pub="$PUBLIC_IP_FOR_CONTAINER" -v tls="$TLS" -v ext="$EXT" -v sig="$P_WEB" -v turn="$P_TURN" '
        /^  redroid:/ { inw=0 }
        /^  webrtc:/ { inw=1 }
        !inw { print; next }
        /^[[:space:]]*-[[:space:]]*(PUBLIC_IP|USE_TLS|EXTERNAL_SIGNALING_PORT|SIGNALING_PORT|EXTERNAL_TURN_PORT)=/ { next }
        { print }
        /^[[:space:]]*environment:[[:space:]]*$/ && !done {
            print "      - PUBLIC_IP=" pub
            print "      - USE_TLS=" tls
            print "      - EXTERNAL_SIGNALING_PORT=" ext
            print "      - SIGNALING_PORT=" sig
            print "      - EXTERNAL_TURN_PORT=" turn
            done=1
        }
    ' "$COMPOSE" > "$TMP" && mv -f "$TMP" "$COMPOSE" 2>/dev/null || rm -f "$TMP"
fi

### 同步到 /docker（飞牛 docker-project 读取该路径）
mkdir -p /docker 2>/dev/null || true
cp -f "$COMPOSE" /docker/docker-compose.yaml 2>/dev/null || true
chmod 644 /docker/docker-compose.yaml 2>/dev/null || true

echo "net_mode[$MODE]: PUBLIC_IP(容器)=$PUBLIC_IP_FOR_CONTAINER USE_TLS=$TLS EXTERNAL_SIGNALING_PORT=$EXT SIGNALING_PORT=$P_WEB TURN=$P_TURN ADB=$P_ADB"

if [ "$NO_RESTART" = "1" ]; then
    echo "net_mode: --no-restart，仅写配置（安装/升级流程稍后统一启动容器）"
    exit 0
fi

### 3.9.1：重建前做中继段占用预检（仅冲突时换段；无冲突完全不动）
if [ -f "$(dirname "$0")/turn_ports.sh" ]; then
    bash "$(dirname "$0")/turn_ports.sh" >/dev/null 2>&1 || true
fi

### 重建 webrtc 容器使环境变量生效（数据卷 androidemu-webrtc-data 不变）
if docker inspect androidemu-webrtc >/dev/null 2>&1; then
    ( cd "$APP_DIR/docker" 2>/dev/null && docker compose -p androidemu up -d --force-recreate webrtc ) >/dev/null 2>&1 \
        && echo "net_mode: webrtc 已按新模式重建" || echo "net_mode: webrtc 重建失败（可稍后在应用中心重启应用）"
    ### 3.9.1：TLS 开关变化后 agent 的连接协议（ws/wss）必须跟随，否则设备会掉线。
    ### 以应用用户**同步**执行（后台方式会在所属会话退出时被杀，实测导致协议没切换）。
    if [ -f "$(dirname "$0")/agent_autodeploy.sh" ]; then
        if [ "$(id -un 2>/dev/null)" = "root" ]; then
            runuser -u docker-androidemu -- env TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" \
                timeout 240 bash "$(dirname "$0")/agent_autodeploy.sh" --force >/dev/null 2>&1
        else
            timeout 240 bash "$(dirname "$0")/agent_autodeploy.sh" --force >/dev/null 2>&1
        fi
        echo "net_mode: agent 已按新协议重新部署（ws/wss 跟随 TLS）"
    fi
    ### 3.9.1：网关只在启动时读取 USE_TLS —— TLS 切换后必须重启网关，否则应用中心入口
    ### 会继续按旧协议连上游（切 HTTPS 后 → 502；切回明文后 → TLS 握手失败）。
    ### 同理以应用用户重启（网关常驻身份就是 docker-androidemu）。
    if [ -f "$(dirname "$0")/gw_socket.sh" ]; then
        if [ "$(id -un 2>/dev/null)" = "root" ]; then
            runuser -u docker-androidemu -- env TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" \
                bash "$(dirname "$0")/gw_socket.sh" restart >/dev/null 2>&1
        else
            bash "$(dirname "$0")/gw_socket.sh" restart >/dev/null 2>&1
        fi
        echo "net_mode: 网关已重启（上游协议跟随 USE_TLS）"
    fi
else
    echo "net_mode: webrtc 容器尚未创建，配置已就绪，启动时自动生效"
fi

exit 0
