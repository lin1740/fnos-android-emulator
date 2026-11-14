#!/bin/bash
set -e

# ==============================================================================
# CloudPhone All-in-One 容器入口启动脚本（androidemu 定制版）
# 基于原 entrypoint.sh，添加 listening-ip=0.0.0.0 确保 TURN 监听所有接口
# ==============================================================================

# 1. 读取并配置默认环境变量
PUBLIC_IP=${PUBLIC_IP:-"127.0.0.1"}
if [ "$PUBLIC_IP" = "127.0.0.1" ] || echo "$PUBLIC_IP" | grep -qE '^172\.(1[6-9]|2[0-9]|3[01])\.'; then
    _detected_ip=""
    for _ip in $(hostname -I 2>/dev/null); do
        case "$_ip" in
            172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) [ -z "$_detected_ip" ] && _detected_ip="$_ip" ;;  # 容器自身 IP 仅作兜底
            192.168.*|10.*) _detected_ip="$_ip"; break ;;
            *) [ -z "$_detected_ip" ] && _detected_ip="$_ip" ;;
        esac
    done
    if [ -n "$_detected_ip" ]; then
        PUBLIC_IP="$_detected_ip"
        echo "WARNING: PUBLIC_IP 未由 net_mode 配置，回退为容器 IP: $PUBLIC_IP"
        echo "         （bridge 模式下浏览器侧 TURN 将不可达；请用 net_mode.sh lan 写入宿主局域网 IP）"
    fi
fi
TURN_USER=${TURN_USER:-"cloudphone_user"}
TURN_PASSWORD=${TURN_PASSWORD:-"cloudphone_secure_password"}
SIGNALING_PORT=${SIGNALING_PORT:-8443}
USE_TLS=${USE_TLS:-true}
DEFAULT_SETTINGS=${DEFAULT_SETTINGS:-'{"maxBitrate":4,"minBitrate":1,"fps":30,"size":1920,"bitrate":4}'}

EXTERNAL_SIGNALING_PORT=${EXTERNAL_SIGNALING_PORT:-${SIGNALING_PORT}}
EXTERNAL_TURN_PORT=${EXTERNAL_TURN_PORT:-3478}

COTURN_MIN_PORT=${COTURN_MIN_PORT:-50000}
COTURN_MAX_PORT=${COTURN_MAX_PORT:-50029}

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

# 3. 创建普通用户并设置权限（3.4.8：内部服务降权运行）
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
if [ -n "${CLOUDPHONE_DEVICE_SECRET:-}" ]; then
    export CLOUDPHONE_DEVICE_SECRET
fi

### 3.9.9：多网卡适配。PUBLIC_IPS 为逗号分隔的宿主局域网地址（net_mode.sh 写入），
### 每个都生成一组 TURN/STUN。浏览器会逐个尝试，落在同网段的那个必然可达 ——
### 相当于「自动选与客户端同网段」，但不需要服务端猜客户端在哪。
### PUBLIC_IPS 为空/未设时，行为与旧版完全一致（只用 PUBLIC_IP）。
_AE_IPS="${PUBLIC_IPS:-$PUBLIC_IP}"
_AE_ICE=""
_AE_OLDIFS="$IFS"; IFS=','
for _ae_ip in $_AE_IPS; do
    _ae_ip=$(printf '%s' "$_ae_ip" | tr -d ' \r\n')
    [ -z "$_ae_ip" ] && continue
    [ -n "$_AE_ICE" ] && _AE_ICE="${_AE_ICE},"
    _AE_ICE="${_AE_ICE}turn:${TURN_USER}:${TURN_PASSWORD}@${_ae_ip}:${EXTERNAL_TURN_PORT}?transport=udp"
    _AE_ICE="${_AE_ICE},turn:${TURN_USER}:${TURN_PASSWORD}@${_ae_ip}:${EXTERNAL_TURN_PORT}?transport=tcp"
    _AE_ICE="${_AE_ICE},stun:${_ae_ip}:${EXTERNAL_TURN_PORT}"
done
IFS="$_AE_OLDIFS"
[ -z "$_AE_ICE" ] && _AE_ICE="turn:${TURN_USER}:${TURN_PASSWORD}@${PUBLIC_IP}:${EXTERNAL_TURN_PORT}?transport=udp,stun:${PUBLIC_IP}:${EXTERNAL_TURN_PORT}"
export ICE_SERVERS="${_AE_ICE},turn:${TURN_USER}:${TURN_PASSWORD}@webrtc:${EXTERNAL_TURN_PORT}?transport=udp,turn:${TURN_USER}:${TURN_PASSWORD}@webrtc:${EXTERNAL_TURN_PORT}?transport=tcp,stun:webrtc:${EXTERNAL_TURN_PORT}"
echo "ICE 通告地址：${_AE_IPS}（共 $(printf '%s' "$_AE_IPS" | awk -F, '{print NF}') 个）"

if [ ! -e "${ASSETS}/agent" ]; then
    echo "assets/agent directory not found. Restoring built-in agent binaries..."
    mkdir -p "${ASSETS}"
    ln -s /app/agent_binaries "${ASSETS}/agent" 2>/dev/null || cp -r /app/agent_binaries "${ASSETS}/agent"
fi

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

if [ -f "$INDEX_HTML" ] && ! grep -q "androidemu-ice-config" "$INDEX_HTML" 2>/dev/null; then
    cat >> "$INDEX_HTML" << 'INJECT_EOF'
<script id="androidemu-ice-config">
(function(){
  var host = window.location.hostname;
  var iceServers = [
    {urls: "turn:" + host + ":3478?transport=udp", username: "cloudphone_user", credential: "cloudphone_secure_password"},
    {urls: "turn:" + host + ":3478?transport=tcp", username: "cloudphone_user", credential: "cloudphone_secure_password"},
    {urls: "stun:" + host + ":3478"}
  ];
  var OrigPC = window.RTCPeerConnection || window.webkitRTCPeerConnection || window.mozRTCPeerConnection;
  if(OrigPC){
    window.RTCPeerConnection = function(config, constraints){
      config = config || {};
      config.iceServers = iceServers;
      return new OrigPC(config, constraints);
    };
    window.RTCPeerConnection.prototype = OrigPC.prototype;
    console.log("[androidemu] ICE servers injected:", iceServers);
  }
})();
</script>
INJECT_EOF
    echo "已注入 ICE/TURN 配置 JS 到 ${INDEX_HTML}"
fi

if [ -f "$INDEX_HTML" ] && ! grep -q "androidemu-hide-wan-tip" "$INDEX_HTML" 2>/dev/null; then
    cat >> "$INDEX_HTML" << 'INJECT_EOF'
<script id="androidemu-hide-wan-tip">
(function(){
  var hiddenSet = {};
  function hideWanTip(){
    var els = document.querySelectorAll('body *');
    for(var i=0;i<els.length;i++){
      var el = els[i];
      if(el.children.length===0 && el.textContent && el.textContent.trim().indexOf('外网访问')===0){
        var p = el;
        for(var j=0;j<6 && p.parentElement;j++){
          p = p.parentElement;
          var s = getComputedStyle(p);
          if((s.position==='fixed'||s.position==='absolute') && p.textContent.indexOf('外网访问')!==-1){
            var key = p.textContent.substring(0,30);
            if(!hiddenSet[key]){
              hiddenSet[key] = true;
              /* 先显示3秒，再淡出自动关闭 */
              p.style.transition = 'opacity 0.5s ease';
              setTimeout(function(){
                p.style.opacity = '0';
                setTimeout(function(){ p.style.display='none'; }, 500);
              }, 3000);
            }
            break;
          }
        }
      }
    }
  }
  hideWanTip();
  if(window.MutationObserver){
    new MutationObserver(hideWanTip).observe(document.body,{childList:true,subtree:true});
  } else {
    setInterval(hideWanTip, 1000);
  }
})();
</script>
INJECT_EOF
    echo "已注入隐藏外网提示框 JS 到 ${INDEX_HTML}"
fi

if [ -f "$INDEX_HTML" ] && ! grep -q "androidemu-ui-parity" "$INDEX_HTML" 2>/dev/null; then
    cat >> "$INDEX_HTML" << 'INJECT_EOF'
<script id="androidemu-ui-parity">
(function(){
  try{
    var css = "@media(max-width:768px){body,html{overflow-x:auto!important;-webkit-overflow-scrolling:touch!important;}"
      + "div[style*='position:fixed'][style*='bottom'],div[class*='bottom-panel'],div[class*='terminal-panel'],div[class*='tool-panel'],div[class*='drawer']{max-width:100vw!important;overflow-x:auto!important;overflow-y:hidden!important;}"
      + "div[class*='window'],div[class*='modal'],div[class*='dialog']{max-width:100vw!important;left:0!important;right:auto!important;}"
      + "button[class*='close'],button[aria-label*='close'],button[title*='关闭']{position:sticky!important;left:0!important;z-index:9999!important;}"
      + ".web-fullscreen .share-header,.web-fullscreen .conn-meta,.web-fullscreen .top-bar,.web-fullscreen .header{display:none!important;}"
      + ".web-fullscreen .share-main,.web-fullscreen .main{height:100vh!important;margin:0!important;padding:0!important;}"
      + ".web-fullscreen .share-page-container,.web-fullscreen .page-container{background:#000!important;margin:0!important;padding:0!important;}"
      + ".web-fullscreen .share-aside,.web-fullscreen .share-sidebar,.web-fullscreen .side-control,.web-fullscreen .control-bar,.web-fullscreen .action-bar,.web-fullscreen .tool-bar,.web-fullscreen .right-panel,.web-fullscreen .left-panel,.web-fullscreen .panel{display:none!important;}"
      + ".web-fullscreen .video-container,.web-fullscreen .screen-container,.web-fullscreen .player-container,.web-fullscreen .video-wrap,.web-fullscreen .screen-wrap,.web-fullscreen .player-wrap,.web-fullscreen .display-container{width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;max-width:100vw!important;max-height:100vh!important;}"
      + ".web-fullscreen .share-content,.web-fullscreen .main-content,.web-fullscreen .content-wrap,.web-fullscreen .content{width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;}"
      + ".web-fullscreen{margin:0!important;padding:0!important;overflow:hidden!important;background:#000!important;}"
      + "@media(min-width:768px){.web-fullscreen video,.web-fullscreen canvas,.web-fullscreen img{object-fit:contain!important;width:100%!important;height:100%!important;max-width:100vw!important;max-height:100vh!important;}}"
      + "@media(max-width:767px){.web-fullscreen video,.web-fullscreen canvas,.web-fullscreen img{object-fit:cover!important;width:100vw!important;height:100vh!important;}}"
      + ".gw-fs-active ._gw_hidden{display:none!important;}"
      + ".gw-fs-active body{margin:0!important;padding:0!important;overflow:hidden!important;}";
    var st = document.createElement("style");
    st.id = "androidemu-ui-parity-style";
    st.textContent = css;
    (document.head||document.documentElement).appendChild(st);
    var hidden=[];
    function isMedia(e){return e.tagName&&(e.tagName==="VIDEO"||e.tagName==="CANVAS"||e.tagName==="IMG");}
    function hasMedia(e){if(isMedia(e))return true;for(var i=0;i<e.children.length;i++){if(hasMedia(e.children[i]))return true;}return false;}
    function enterFs(){hidden=[];var all=document.querySelectorAll("body *");for(var i=0;i<all.length;i++){var el=all[i];var cs=getComputedStyle(el);if((cs.position==="fixed"||cs.position==="sticky")&&!hasMedia(el)){el.classList.add("_gw_hidden");hidden.push(el);}}document.documentElement.classList.add("gw-fs-active");}
    function exitFs(){for(var i=0;i<hidden.length;i++){hidden[i].classList.remove("_gw_hidden");}hidden=[];document.documentElement.classList.remove("gw-fs-active");}
    document.addEventListener("fullscreenchange",function(){if(document.fullscreenElement){enterFs();}else{exitFs();}});
    document.addEventListener("webkitfullscreenchange",function(){if(document.webkitFullscreenElement){enterFs();}else{exitFs();}});
  }catch(e){}
})();
</script>
INJECT_EOF
    echo "已注入 UI 一致性样式/全屏处理 JS 到 ${INDEX_HTML}"
fi

if [ -f "$INDEX_HTML" ] && ! grep -q "androidemu-no-paste" "$INDEX_HTML" 2>/dev/null; then
    cat >> "$INDEX_HTML" << 'INJECT_EOF'
<script id="androidemu-no-paste">
(function(){
  try{
    var css = "html,body{-webkit-touch-callout:none!important;}"
      + "*:not(input):not(textarea){-webkit-user-select:none!important;user-select:none!important;}"
      + "input,textarea{-webkit-user-select:text!important;user-select:text!important;-webkit-touch-callout:none!important;}";
    var st=document.createElement("style");
    st.id="androidemu-no-paste-style";
    st.textContent=css;
    (document.head||document.documentElement).appendChild(st);
    var isField=function(t){return t&&(t.tagName==="INPUT"||t.tagName==="TEXTAREA"||t.isContentEditable);};
    document.addEventListener("contextmenu",function(e){e.preventDefault();return false;},true);
    document.addEventListener("selectstart",function(e){if(isField(e.target))return;e.preventDefault();return false;},true);
    document.addEventListener("dblclick",function(e){if(isField(e.target))return;var s=window.getSelection&&window.getSelection();if(s)s.removeAllRanges();},true);
  }catch(e){}
})();
</script>
INJECT_EOF
    echo "已注入禁用粘贴气泡/右键菜单脚本到 ${INDEX_HTML}"
fi

# 6. 启动 webrtc-signaling 信令服务进程（降权到 appuser）
echo "Starting webrtc-signaling server (as appuser, env inherited from export)..."
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
