#!/bin/bash
### net_mode.sh — 一键切换访问模式（局域网直连 / 公网端口映射 / 内网穿透·反向代理）。
###
### 用法：
###   net_mode.sh lan                      # 局域网直连（默认）
###   net_mode.sh wan  <域名或公网IP> [端口]   # 公网端口映射（WebRTC，需 UDP 可达）
###   net_mode.sh proxy <域名或IP>    [端口]   # 内网穿透/反向代理（自动 USE_TLS=false，走 TCP）
###   net_mode.sh <模式> ... --no-restart      # 只写配置不重建容器（供安装/升级阶段调用）
###   net_mode.sh                          # 不带参数：按已保存配置重新应用（幂等）
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

### 2.0.34：端口可自定义。端口写入 ${TRIM_PKGVAR}/ports.conf（WEB_PORT/EXT_PORT/TURN_PORT/ADB_PORT），
### 这里读取后写进 compose 的 SIGNALING_PORT / EXTERNAL_SIGNALING_PORT / EXTERNAL_TURN_PORT。
### 未提供配置文件时一律用默认值（画面 8443、TURN 3478、ADB 5556），保持向后兼容。
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

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$LAN_IP" ] && LAN_IP="127.0.0.1"

### 读取已保存配置（无参数时按旧配置重放；有参数时参数优先）
OLD_MODE=""; OLD_HOST=""; OLD_PORT=""
if [ -f "$CONF" ]; then
    OLD_MODE=$(sed -n 's/^MODE=//p' "$CONF" | head -n1)
    OLD_HOST=$(sed -n 's/^HOST=//p' "$CONF" | head -n1)
    OLD_PORT=$(sed -n 's/^PORT=//p' "$CONF" | head -n1)
fi
[ -z "$MODE" ] && MODE="${OLD_MODE:-lan}"

case "$MODE" in
    lan)
        PUB="$LAN_IP"; TLS="true"; EXT="${P_EXT:-$P_WEB}"; HOST_SAVE=""; PORT_SAVE="${P_EXT:-$P_WEB}"
        ;;
    lanhttp)
        ### 2.0.23：局域网直连但关闭 TLS（HTTP）——手机浏览器与 App 内嵌 WebView 对自签证书
        ### 会直接拦截或白屏，改用 HTTP 可免证书提示（仅建议在可信局域网内使用）。
        PUB="$LAN_IP"; TLS="false"; EXT="${P_EXT:-$P_WEB}"; HOST_SAVE=""; PORT_SAVE="${P_EXT:-$P_WEB}"
        ;;
    wan)
        PUB="${HOST_ARG:-${OLD_HOST:-$LAN_IP}}"
        EXT="${PORT_ARG:-${OLD_PORT:-${P_EXT:-$P_WEB}}}"
        TLS="true"; HOST_SAVE="$PUB"; PORT_SAVE="$EXT"
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

### 修改 environment 块中的三个键：先删除旧行，再在 environment: 后插入新行
TMP="$(mktemp)" || exit 0
awk -v pub="$PUBLIC_IP_FOR_CONTAINER" -v tls="$TLS" -v ext="$EXT" -v sig="$P_WEB" -v turn="$P_TURN" '
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

### 同步到 /docker（飞牛 docker-project 读取该路径）
mkdir -p /docker 2>/dev/null || true
cp -f "$COMPOSE" /docker/docker-compose.yaml 2>/dev/null || true
chmod 644 /docker/docker-compose.yaml 2>/dev/null || true

echo "net_mode[$MODE]: PUBLIC_IP(容器)=$PUBLIC_IP_FOR_CONTAINER USE_TLS=$TLS EXTERNAL_SIGNALING_PORT=$EXT SIGNALING_PORT=$P_WEB TURN=$P_TURN ADB=$P_ADB"

if [ "$NO_RESTART" = "1" ]; then
    echo "net_mode: --no-restart，仅写配置（安装/升级流程稍后统一启动容器）"
    exit 0
fi

### 重建 webrtc 容器使环境变量生效（数据卷 androidemu-webrtc-data 不变）
if docker inspect androidemu-webrtc >/dev/null 2>&1; then
    ( cd "$APP_DIR/docker" 2>/dev/null && docker compose -p androidemu up -d --force-recreate webrtc ) >/dev/null 2>&1 \
        && echo "net_mode: webrtc 已按新模式重建" || echo "net_mode: webrtc 重建失败（可稍后在应用中心重启应用）"
else
    echo "net_mode: webrtc 容器尚未创建，配置已就绪，启动时自动生效"
fi

exit 0
