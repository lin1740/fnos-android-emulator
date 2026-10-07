#!/bin/bash
set -e

# ==============================================================================
# CloudPhone All-in-One 容器入口启动脚本（androidemu 定制版）
# 基于原 entrypoint.sh，添加 listening-ip=0.0.0.0 确保 TURN 监听所有接口
# ==============================================================================

# 1. 读取并配置默认环境变量
PUBLIC_IP=${PUBLIC_IP:-"127.0.0.1"}
# 3.5.7：IP 兜底检测 — 如果 PUBLIC_IP 是 127.0.0.1 或 Docker 网桥地址（172.16-31.x），
# 自动检测正确的局域网 IP（优先 192.168.x.x），避免 TURN external-ip 错误导致 WebRTC 失败。
if [ "$PUBLIC_IP" = "127.0.0.1" ] || echo "$PUBLIC_IP" | grep -qE '^172\.(1[6-9]|2[0-9]|3[01])\.'; then
    _detected_ip=""
    for _ip in $(hostname -I 2>/dev/null); do
        case "$_ip" in
            192.168.*) _detected_ip="$_ip"; break ;;
            10.*)     [ -z "$_detected_ip" ] && _detected_ip="$_ip" ;;
            172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) : ;;  # Docker 网桥，跳过
            *)        [ -z "$_detected_ip" ] && _detected_ip="$_ip" ;;
        esac
    done
    [ -z "$_detected_ip" ] && _detected_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -n "$_detected_ip" ] && PUBLIC_IP="$_detected_ip" && echo "Auto-detected LAN IP: $PUBLIC_IP (overrode invalid default)"
fi
TURN_USER=${TURN_USER:-"cloudphone_user"}
TURN_PASSWORD=${TURN_PASSWORD:-"cloudphone_secure_password"}
SIGNALING_PORT=${SIGNALING_PORT:-8443}
USE_TLS=${USE_TLS:-true}
DEFAULT_SETTINGS=${DEFAULT_SETTINGS:-'{"maxBitrate":4,"minBitrate":1,"fps":30,"size":1920,"bitrate":4}'}

EXTERNAL_SIGNALING_PORT=${EXTERNAL_SIGNALING_PORT:-${SIGNALING_PORT}}
EXTERNAL_TURN_PORT=${EXTERNAL_TURN_PORT:-3478}

COTURN_MIN_PORT=${COTURN_MIN_PORT:-50000}
COTURN_MAX_PORT=${COTURN_MAX_PORT:-50100}

echo "========================================================"
echo "    Starting CloudPhone All-in-One Services (AIO)"
echo "    androidemu custom entrypoint (TURN listen 0.0.0.0)"
echo "========================================================"
echo "Public IP:          $PUBLIC_IP"
echo "Signaling Port:     $SIGNALING_PORT (Mapped Externally as: $EXTERNAL_SIGNALING_PORT)"
echo "TURN Port:          3478 (Mapped Externally as: $EXTERNAL_TURN_PORT)"
echo "TURN Username:      $TURN_USER"
echo "TURN UDP Ports:     $COTURN_MIN_PORT -> $COTURN_MAX_PORT"
echo "TLS Enabled:        $USE_TLS"
echo "========================================================"

# 2. 动态生成 coturn 配置文件（包含 listening-ip=0.0.0.0）
mkdir -p /etc/coturn
cat <<EOF > /etc/coturn/turnserver.conf
# 自动生成的 AIO TurnServer 配置文件 (androidemu custom)
listening-port=3478
listening-ip=0.0.0.0
fingerprint
lt-cred-mech
user=${TURN_USER}:${TURN_PASSWORD}
realm=cloudphone
external-ip=${PUBLIC_IP}
min-port=${COTURN_MIN_PORT}
max-port=${COTURN_MAX_PORT}
stale-nonce=600
no-multicast-peers
no-loopback-peers
no-cli
simple-log
syslog
verbose
# 3.8.3：TURN 性能与稳定性优化
bps-capacity=0
user-quota=0
total-quota=0
max-allocate-lifetime=3600
channel-lifetime=600
permission-lifetime=300
EOF

# 3. 创建非 root 用户并设置权限（3.4.8：容器内服务降权运行）
APP_UID=${APP_UID:-1000}
APP_GID=${APP_GID:-1000}
if ! id appuser >/dev/null 2>&1; then
    addgroup -g "$APP_GID" appuser 2>/dev/null || true
    adduser -u "$APP_UID" -G appuser -s /bin/sh -D appuser 2>/dev/null || true
fi
# 配置文件和数据目录授权给 appuser
chown -R appuser:appuser /etc/coturn /app/data 2>/dev/null || true
chmod 755 /etc/coturn /app/data 2>/dev/null || true
echo "Services will run as appuser (uid=$APP_UID, gid=$APP_GID)"

# 4. 启动 coturn 服务进程（降权到 appuser）
# turnserver 用 -c 指定配置文件，不依赖环境变量，su 降权即可
echo "Starting coturn daemon (listening on 0.0.0.0, as appuser)..."
# 3.5.8 性能优化：提升 TURN 进程优先级（nice=-10），减少调度延迟
nice -n -10 su appuser -c "turnserver -c /etc/coturn/turnserver.conf" &
COTURN_PID=$!

# 4. 配置并透传环境变量给 webrtc-signaling 服务
export PORT=${SIGNALING_PORT}
export HOST=0.0.0.0
export ASSETS=${ASSETS:-"/app/assets"}
export USE_TLS=${USE_TLS}
export TLS_CERT=/app/certs/server.crt
export TLS_KEY=/app/certs/server.key
export DEFAULT_SETTINGS=${DEFAULT_SETTINGS}

export ICE_SERVERS="turn:${TURN_USER}:${TURN_PASSWORD}@${PUBLIC_IP}:${EXTERNAL_TURN_PORT}?transport=udp,turn:${TURN_USER}:${TURN_PASSWORD}@${PUBLIC_IP}:${EXTERNAL_TURN_PORT}?transport=tcp,stun:${PUBLIC_IP}:${EXTERNAL_TURN_PORT}"

if [ ! -e "${ASSETS}/agent" ]; then
    echo "assets/agent directory not found. Restoring built-in agent binaries..."
    mkdir -p "${ASSETS}"
    ln -s /app/agent_binaries "${ASSETS}/agent" 2>/dev/null || cp -r /app/agent_binaries "${ASSETS}/agent"
fi

# 3.8.6：注入设备检测 JS，客户端打开页面时自动上报设备类型（pc/phone/tablet），
# 宿主守护脚本接收后自动切换分辨率。仅注入一次，幂等。
INDEX_HTML="${ASSETS}/index.html"
if [ -f "$INDEX_HTML" ] && ! grep -q "androidemu-device-detect" "$INDEX_HTML" 2>/dev/null; then
    cat >> "$INDEX_HTML" << 'INJECT_EOF'
<script id="androidemu-device-detect">
(function(){
  try {
    var ua = navigator.userAgent || "";
    var device = "pc";
    if (/Mobile|Android|iPhone|iPod|Windows Phone/i.test(ua)) {
      if (/iPad|Tablet|PlayBook|Silk|Android(?!.*Mobile)/i.test(ua)) {
        device = "tablet";
      } else {
        device = "phone";
      }
    } else if (/iPad|Tablet|PlayBook|Silk/i.test(ua)) {
      device = "tablet";
    }
    /* 图片信标上报，避免 HTTPS 页面的混合内容限制 */
    var img = new Image();
    img.src = "http://127.0.0.1:18443/?device=" + device + "&t=" + Date.now();
  } catch(e) {}
})();
</script>
INJECT_EOF
    echo "已注入设备检测 JS 到 ${INDEX_HTML}"
fi

# 6. 启动 webrtc-signaling 信令服务进程（降权到 appuser）
# 3.5.5 修复：外层已 export ICE_SERVERS/PORT/HOST/USE_TLS 等变量，BusyBox su 默认保留已 export 的环境变量，
# 不需要在 su -c 内重复 export（3.5.4 的内部 export 方式导致 $ICE_SERVERS 展开为空，ICE_SERVERS 丢失）。
echo "Starting webrtc-signaling server (as appuser, env inherited from export)..."
# 3.5.8 性能优化：提升信令服务进程优先级（nice=-10），降低画面卡顿
nice -n -10 su appuser -c "/app/webrtc-signaling" &
SIGNALING_PID=$!

sleep 1
echo ""
echo "========================================================"
echo "          🎉 CloudPhone 容器服务已成功启动！"
echo "========================================================"
echo " TURN listening on 0.0.0.0:3478 (all interfaces)"
echo "========================================================"
echo ""

# 7. 定义信号捕获与优雅退出逻辑
cleanup_processes() {
    echo "Stopping all services gracefully..."
    kill -TERM "$COTURN_PID" "$SIGNALING_PID" 2>/dev/null || true
    wait "$COTURN_PID" 2>/dev/null || true
    wait "$SIGNALING_PID" 2>/dev/null || true
    echo "Services stopped successfully."
}

trap cleanup_processes SIGINT SIGTERM

# 8. 等待任一关键进程退出
wait -n

echo "One of the services terminated unexpectedly!"
cleanup_processes
exit 1
