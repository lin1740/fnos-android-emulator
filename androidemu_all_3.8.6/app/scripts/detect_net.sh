#!/bin/bash
### detect_net.sh — 自动判断网络环境，推荐并（可选）应用「云手机画面」的访问方式。
###
### 判断逻辑：
###   1) 本机 IP 不是内网地址（直接持有公网 IP）→ 公网 / 端口映射；
###   2) 探测不到公网出口（离线/受限）→ 局域网直连；
###   3) 出口公网 IP 属于运营商大内网 CGNAT（100.64.0.0/10）→ 内网穿透 / 反向代理；
###   4) 本机在 NAT 之后（内网 IP + 有出口公网 IP）→ 默认最稳的局域网直连，并在说明里提示
###      已做端口映射就切公网、只有 TCP 通道就切穿透/反代。
###
### 用法：detect_net.sh [--apply]
### 输出：$VAR_DIR/net-detect.conf（MODE/LAN_IP/PUBLIC_IP/REASON/UPDATED），并打印一行摘要。

set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
OUT="$VAR_DIR/net-detect.conf"
mkdir -p "$VAR_DIR" 2>/dev/null || true

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$LAN_IP" ] && LAN_IP="127.0.0.1"

is_private() {
    case "$1" in
        10.*|127.*|169.254.*|192.168.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        *) return 1 ;;
    esac
}
is_cgnat() {
    case "$1" in
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        *) return 1 ;;
    esac
}

### 出口公网 IP：多个国内可达的探测点，取第一个成功且像 IPv4 的结果
PUB=""
for U in "https://ip.3322.net" "http://members.3322.org/dyndns/getip" "https://myip.ipip.net/s" "https://4.ipw.cn"; do
    R="$(timeout 8 curl -fsS "$U" 2>/dev/null | tr -d ' \r\n' | grep -o -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1)"
    if [ -n "${R:-}" ]; then PUB="$R"; break; fi
done

MODE="lan"
REASON=""
if ! is_private "$LAN_IP"; then
    MODE="wan"
    REASON="本机直接持有公网 IP（$LAN_IP），已按「公网 / 端口映射」配置"
elif [ -z "$PUB" ]; then
    MODE="lan"
    REASON="未探测到公网出口（离线或网络受限），已按「局域网直连」配置（内网 IP $LAN_IP）"
elif is_cgnat "$PUB"; then
    MODE="proxy"
    REASON="出口属于运营商大内网 CGNAT（$PUB），公网端口无法直接映射，已按「内网穿透 / 反向代理」配置（对外端口 443；连接时请在画面页点「改用 WebSocket 投屏」）"
else
    MODE="lan"
    REASON="本机在 NAT 之后（内网 IP $LAN_IP，出口公网 IP $PUB）：已按最稳的「局域网直连」配置。若已在路由器映射 8443/TCP、3478/TCP+UDP、50000-50100/UDP 到本机，可在面板一键切到「公网 / 端口映射」；若只有 TCP 通道（frp/nginx/cloudflared），请切到「内网穿透 / 反向代理」"
fi

{
    echo "MODE=$MODE"
    echo "LAN_IP=$LAN_IP"
    echo "PUBLIC_IP=$PUB"
    echo "REASON=$REASON"
    echo "UPDATED=$(date '+%F %T')"
} >"$OUT" 2>/dev/null || true

echo "detect_net: 推荐=$MODE"
echo "detect_net: $REASON"

if [ "${1:-}" = "--apply" ]; then
    HOST_ARG=""
    if [ "$MODE" = "wan" ] && [ -n "$PUB" ]; then HOST_ARG="$PUB"; fi
    if [ -f "$APP_DIR/scripts/net_mode.sh" ]; then
        # shellcheck disable=SC2086
        bash "$APP_DIR/scripts/net_mode.sh" "$MODE" $HOST_ARG --no-restart
    fi
fi
exit 0
