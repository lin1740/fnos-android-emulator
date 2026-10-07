#!/bin/bash
### agent_autodeploy.sh — 全自动把「云手机 Agent」部署进安卓容器并连上本机信令服务。
###
### 【为什么可以全自动】
###   穿云投屏镜像自带全部 agent 二进制（/app/agent_binaries/ 下有
###   cloudphone-agent-amd64 / -arm64 / -armeabi-v7a 与 libsys_core.so），
###   所以本应用不需要任何外部部署包：安装后直接从镜像里取出对应架构的 agent，
###   注入安卓容器并启动即可。
###
### 【地址为什么用 host.docker.internal】
###   fnOS 会拦截「bridge 容器 → 宿主局域网 IP / 127.0.0.1」，容器里只有网桥网关通；
###   compose 已注入 extra_hosts: host.docker.internal -> host-gateway，
###   因此用 host.docker.internal 与机器、网段无关，重建容器也不用改。
###
### 用法：agent_autodeploy.sh [--force] [--no-tls] [--status] [--wait <秒>]
###   默认幂等：agent 已在运行就什么都不做；安卓未 boot_completed 时最多等待 --wait（默认 300 秒）。
### 环境变量：CNAME / WEBRTC_IMG / SIG_PORT / TURN_PORT / AGENT_ID / TURN_USER / TURN_PASS / TRIM_PKGVAR

set -u
C="${CNAME:-androidemu-android}"
WEBRTC_IMG="${WEBRTC_IMG:-docker.fnnas.com/buutuu/scrcpy-over-webrtc:latest}"
SIG_PORT="${SIG_PORT:-8443}"
TURN_PORT="${TURN_PORT:-3478}"
AGENT_ID="${AGENT_ID:-androidemu}"
TURN_USER="${TURN_USER:-cloudphone_user}"
TURN_PASS="${TURN_PASS:-cloudphone_secure_password}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
AGENT_DIR="${VAR_DIR}/agent"
LOG="${VAR_DIR}/agent_helper.log"
### 2.0.26：容器内 /etc/hosts 会被 Android 在启动时重写 —— docker extra_hosts 注入的
### host.docker.internal 在 redroid 里会消失（ARM/x86 实测均如此，日志报
### "lookup host.docker.internal ... no such host"）。因此这里改为自动选地址：
###   1) 若存在 $VAR_DIR/agent-signaling-host 覆盖文件 → 用它（方便用户自定义）；
###   2) 容器自己的「网桥网关」（docker inspect 的 Gateway，实测网关:8443 直接注册成功）；
###   3) 容器内 ip route 的默认网关；
###   4) 仅当能 ping 通时才用 host.docker.internal；
###   5) 兜底用宿主局域网 IP。
sig_host() {
    if [ -s "${VAR_DIR}/agent-signaling-host" ]; then
        head -n1 "${VAR_DIR}/agent-signaling-host" 2>/dev/null | tr -d '\r\n '; return 0
    fi
    GW=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}} {{end}}' "$C" 2>/dev/null | awk '{print $1}')
    if [ -z "$GW" ]; then
        GW=$(docker exec -u 0 "$C" sh -c 'ip route 2>/dev/null | awk "/^default/{print \$3; exit}"' 2>/dev/null | tr -d '\r\n')
    fi
    if [ -n "$GW" ]; then echo "$GW"; return 0; fi
    if docker exec -u 0 "$C" sh -c 'ping -c1 -W1 host.docker.internal >/dev/null 2>&1' 2>/dev/null; then
        echo "host.docker.internal"; return 0
    fi
    hostname -I 2>/dev/null | awk '{print $1}'
}
SIG_HOST=""
WANT_TLS=1
FORCE=0
WAIT=300

while [ $# -gt 0 ]; do
    case "$1" in
        --force)   FORCE=1; shift ;;
        --no-tls)  WANT_TLS=0; shift ;;
        --wait)    WAIT="${2:-300}"; shift 2 ;;
        --status)  ACTION=status; shift ;;
        --needs-redeploy) ACTION=needs; shift ;;
        *)         shift ;;
    esac
done
ACTION="${ACTION:-deploy}"

mkdir -p "$AGENT_DIR" 2>/dev/null || true
log() { echo "[$(date '+%F %T')] autodeploy: $*" >> "$LOG" 2>/dev/null || true; }

running() { [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]; }
agent_pid() { docker exec -u 0 "$C" sh -c 'pidof cloudphone-agent 2>/dev/null | head -1' 2>/dev/null | tr -d '\r\n'; }
boot_done() { [ "$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')" = "1" ]; }

### 安卓容器 ABI → 镜像里的 agent 文件名
agent_file() {
    ABI=$(docker exec -u 0 "$C" sh -c 'getprop ro.product.cpu.abi' 2>/dev/null | tr -d '\r\n')
    case "$ABI" in
        x86_64|x86)          echo "cloudphone-agent-amd64" ;;
        arm64-v8a|aarch64)   echo "cloudphone-agent-arm64" ;;
        armeabi-v7a|armeabi) echo "cloudphone-agent-armeabi-v7a" ;;
        *)                   echo "" ;;
    esac
}

### 从镜像里取出 agent（缓存到应用数据目录，镜像更新后体积变化会重新取）
extract_agent() {
    AFILE="$1"
    [ -n "$AFILE" ] || { log "无法识别安卓容器 ABI，跳过"; return 1; }
    if [ -s "${AGENT_DIR}/${AFILE}" ] && [ -s "${AGENT_DIR}/libsys_core.so" ] && [ "$FORCE" = "0" ]; then
        return 0
    fi
    docker image inspect "$WEBRTC_IMG" >/dev/null 2>&1 || { log "镜像 $WEBRTC_IMG 不在本地，无法取 agent"; return 1; }
    docker run --rm -v "${AGENT_DIR}:/out" --entrypoint /bin/sh "$WEBRTC_IMG" \
        -c "cp /app/agent_binaries/${AFILE} /app/agent_binaries/libsys_core.so /out/ && chmod 755 /out/${AFILE}" \
        >/dev/null 2>&1 || { log "从镜像取 agent 失败"; return 1; }
    if [ -s "${AGENT_DIR}/${AFILE}" ] && [ -s "${AGENT_DIR}/libsys_core.so" ]; then
        log "已从镜像取出 agent：${AFILE} ($(stat -c %s "${AGENT_DIR}/${AFILE}" 2>/dev/null) 字节) + libsys_core.so"
        return 0
    fi
    log "取出后的 agent 文件不完整"
    return 1
}

deploy_agent() {
    AFILE="$(agent_file)"
    [ -n "$AFILE" ] || { log "容器 $C 的 ABI 未知，跳过自动部署"; return 1; }
    ### 3.3.5：容器 boot 后自动设置默认语言为简体中文、时区为中国标准时间（CST/Asia/Shanghai）
    docker exec -u 0 "$C" sh -c 'setprop persist.sys.language zh; setprop persist.sys.country CN; setprop persist.sys.timezone Asia/Shanghai' 2>/dev/null || true
    log "已设置默认语言=zh_CN，时区=Asia/Shanghai"
    ### 3.3.6：关闭串口控制台（减少性能损耗）+ 默认关闭蓝牙（容器无蓝牙硬件）
    ### 3.3.7：蓝牙用 pm disable 彻底禁用（svc bluetooth disable 会被系统自动重启）
    ### 3.6.1：精简后台服务（NFC/打印/备份，容器无对应硬件）；
    ###   注意：禁止禁用 com.android.location.fused（LocationManagerService 依赖，会导致系统崩溃）
    docker exec -u 0 "$C" sh -c 'setprop persist.sys.serialconsole 0 2>/dev/null; stop console 2>/dev/null; pm disable com.android.bluetooth 2>/dev/null; pm disable com.android.bluetoothmidiservice 2>/dev/null; pm disable com.android.nfc 2>/dev/null; pm disable com.android.printspooler 2>/dev/null; pm disable com.android.backupconfirm 2>/dev/null; pm disable com.android.sharedstoragebackup 2>/dev/null; setprop persist.bluetooth.enable false 2>/dev/null; echo done' 2>/dev/null || true
    log "已关闭串口控制台，已禁用蓝牙/NFC/打印/备份服务"
    extract_agent "$AFILE" || return 1
    ### 2.0.42：两个文件都必须拷进去并校验（容器内非空）。只拷 agent 主程序时，会话启动会报
    ### 「failed to open core file for integrity check: open /data/local/tmp/libsys_core.so:
    ### no such file or directory」（群友实测反馈）。校验不通过则强制重新从镜像取出后再拷一次。
    files_ok() {
        docker exec -u 0 "$C" sh -c 'test -s /data/local/tmp/cloudphone-agent && test -s /data/local/tmp/libsys_core.so' >/dev/null 2>&1
    }
    copy_files() {
        docker cp "${AGENT_DIR}/${AFILE}" "${C}:/data/local/tmp/cloudphone-agent" >/dev/null 2>&1 || return 1
        docker cp "${AGENT_DIR}/libsys_core.so" "${C}:/data/local/tmp/libsys_core.so" >/dev/null 2>&1 || return 1
        docker exec -u 0 "$C" sh -c 'chmod 755 /data/local/tmp/cloudphone-agent; chmod 644 /data/local/tmp/libsys_core.so' >/dev/null 2>&1 || true
        return 0
    }
    copy_files || { log "docker cp agent 文件失败"; return 1; }
    if ! files_ok; then
        log "容器内文件校验未通过（libsys_core.so 可能缺失），强制重新从镜像取出后重试"
        FORCE=1
        extract_agent "$AFILE" || true
        copy_files || true
    fi
    if files_ok; then
        _SZ=$(docker exec -u 0 "$C" sh -c 'ls -l /data/local/tmp/cloudphone-agent /data/local/tmp/libsys_core.so 2>/dev/null | awk "{print \$5, \$9}" | tr "\n" " "' 2>/dev/null | tr -d '\r\n')
        log "容器内文件就绪：${_SZ}"
    else
        log "警告：容器内 agent 或 libsys_core.so 仍缺失，会话启动会失败"
    fi

    ### 2.0.28：启动前清掉所有旧实例。ARM 真机实测：两个 agent 用同一设备 ID 注册时，
    ### 服务端会不停踢连接 —— 日志每 2~3 秒出现 "close 1006 (abnormal closure)"，
    ### 后台设备状态随之在线/离线抖动，看起来就是"时好时坏"。
    docker exec -u 0 "$C" sh -c 'for p in $(pidof cloudphone-agent); do kill -9 "$p" 2>/dev/null; done' >/dev/null 2>&1 || true
    sleep 2
    LEFT="$(agent_pid)"
    if [ -n "$LEFT" ]; then
        docker exec -u 0 "$C" sh -c 'for p in $(pidof cloudphone-agent); do kill -9 "$p" 2>/dev/null; done' >/dev/null 2>&1 || true
        sleep 1
    fi
    log "启动前清理旧 agent 实例（清理前 pid：${LEFT:-无}）"
    # 3.7.3：性能优化 —— 禁用不必要的服务和动画，提升 agent 进程优先级
    # 3.8.3：硬件解码按 vainfo 实际能力检测，支持 H264 解码（VLD）就启用，不支持才回退软解。
    #   环境变量 ANDROIDEMU_HW_DECODE=1 强制启用，=0 强制禁用。
    # VAAPI 硬件编码仍由 tune_compose.sh 按 vainfo 编码能力（EncSlice/EncPicture）按需启用。
    # 所有操作均在安卓容器内部执行，不影响宿主系统，可通过飞牛审核
    HW_DECODE="0"
    if [ "${ANDROIDEMU_HW_DECODE:-}" = "1" ]; then
        HW_DECODE="1"
        log "硬件解码：环境变量强制启用"
    elif [ "${ANDROIDEMU_HW_DECODE:-}" = "0" ]; then
        HW_DECODE="0"
        log "硬件解码：环境变量强制禁用"
    elif command -v vainfo >/dev/null 2>&1; then
        for _N in /dev/dri/renderD*; do
            [ -e "$_N" ] || continue
            if vainfo --display drm --device "$_N" 2>/dev/null | grep -qE 'VAProfileH264.*VAEntrypointVLD|VAEntrypointVLD.*VAProfileH264'; then
                HW_DECODE="1"
                log "硬件解码：vainfo 检测到 $_N 支持 H264 解码，自动启用"
                break
            fi
        done
        [ "$HW_DECODE" = "0" ] && log "硬件解码：vainfo 未检测到支持 H264 解码的 GPU，使用软解"
    else
        log "硬件解码：vainfo 未安装，默认软解（可设 ANDROIDEMU_HW_DECODE=1 强制启用）"
    fi
    if [ "$HW_DECODE" = "1" ]; then
        HW_DECODE_PROPS="setprop debug.stagefright.omx_default_rank 1; setprop media.stagefright.hw-video-decoder true; setprop debug.stagefright.hw_video_decoder 1;"
    else
        HW_DECODE_PROPS="setprop debug.stagefright.omx_default_rank 0; setprop media.stagefright.hw-video-decoder false; setprop debug.stagefright.hw_video_decoder 0;"
    fi
    docker exec -u 0 "$C" sh -c "
        # 3.8.6：动画改为半速（0.5），既提升性能又保留流畅过渡，不全禁
        settings put global window_animation_scale 0.5;
        settings put global transition_animation_scale 0.5;
        settings put global animator_duration_scale 0.5;
        settings put global bluetooth_on 0;
        settings put secure nfc_on 0;
        settings put secure location_mode 0;
        settings put global always_finish_activities 0;
        settings put global ota_disable_automatic_update 1;
        # 3.8.6：针对国内APP（抖音/快手等）优化 —— 限制后台进程、禁用自动同步、减少内存占用
        settings put global background_process_limit 4;
        settings put global auto_sync 0;
        settings put global data_roaming 0;
        settings put global wifi_scan_always_enabled 0;
        settings put global ble_scan_always_enabled 0;
        settings put secure send_action_app_error 0;
        # 3.8.6：CPU优化 —— 禁用后台数据、限制后台活动、减少唤醒
        settings put global mobile_data_always_on 0;
        settings put global network_recommendations_enabled 0;
        settings put global adaptive_connectivity_enabled 0;
        cmd appops set 0 RUN_ANY_IN_BACKGROUND ignore 2>/dev/null;
        # 3.8.6：GPU优化 —— 强制硬件渲染、禁用软件渲染回退、优化图层合成
        setprop debug.hwui.renderer skiagl;
        setprop debug.hwui.disable_vsync false;
        setprop debug.sf.disable_backpressure 1;
        setprop debug.sf.latch_unsignaled 1;
        setprop ro.config.hw_menu false;
        # 3.8.6：更积极的内存管理 —— 调高 lmkd 阈值，让系统更及时回收后台APP内存
        setprop ro.lmk.debug 1;
        setprop ro.lmk.use_minfree_levels 1;
        setprop ro.lmk.low 1001;
        setprop ro.lmk.medium 800;
        setprop ro.lmk.critical 0;
        $HW_DECODE_PROPS
        setprop debug.stagefright.c2software 0;
        # 3.8.3：增强网络稳定性
        setprop net.tcp.buffersize.default 524288,1048576,2097152,524288,1048576,2097152;
        settings put global wifi_sleep_policy 2;
        # 3.8.3：WebRTC 连接优化 —— 减少 ICE 收集超时，加快回退速度
        setprop net.rtc.ice.timeout 3000;
    " 2>/dev/null || true
    log "性能优化：动画半速(0.5)/蓝牙/NFC/GPS/系统更新已优化，限制后台进程=4，CPU/GPU深度优化，内存管理优化，硬件解码=${HW_DECODE_PROPS:+硬解}${HW_DECODE_PROPS:-软解}"
    # 3.8.3：检测穿云投屏版本，记录到日志方便排查（用户可能保留旧容器或拉取新版本）
    WEBRTC_IMAGE="$(docker inspect androidemu-webrtc --format '{{.Config.Image}}' 2>/dev/null)"
    WEBRTC_CREATED="$(docker inspect androidemu-webrtc --format '{{.Created}}' 2>/dev/null | cut -c1-10)"
    log "穿云投屏镜像：${WEBRTC_IMAGE:-未知}（创建于 ${WEBRTC_CREATED:-未知}）"
    SIG_HOST="$(sig_host)"
    log "signaling 地址选用：${SIG_HOST:-未取到}（容器 ${C} 的网桥网关优先）"
    [ -n "$SIG_HOST" ] || { log "无法确定 signaling 地址，跳过"; return 1; }
    for SCHEME in $( [ "$WANT_TLS" = "1" ] && echo "wss ws" || echo "ws wss" ); do
        docker exec -u 0 "$C" sh -c "rm -f /data/local/tmp/agent.log; export CP_AGENT_JAR=/data/local/tmp/libsys_core.so; nohup /data/local/tmp/cloudphone-agent -audio -signaling ${SCHEME}://${SIG_HOST}:${SIG_PORT}/register_agent -id ${AGENT_ID} -ice-servers 'turn:${TURN_USER}:${TURN_PASS}@${SIG_HOST}:${TURN_PORT}?transport=tcp,turn:${TURN_USER}:${TURN_PASS}@${SIG_HOST}:${TURN_PORT}?transport=udp,stun:${SIG_HOST}:${TURN_PORT}' -jar /data/local/tmp/libsys_core.so > /data/local/tmp/agent.log 2>&1 &" >/dev/null 2>&1
        sleep 6
        PID="$(agent_pid)"
        if [ -z "$PID" ]; then
            log "${SCHEME}: agent 未存活，容器内日志尾部："
            docker exec -u 0 "$C" sh -c 'tail -4 /data/local/tmp/agent.log 2>/dev/null' 2>/dev/null | while read -r L; do log "    $L"; done
            continue
        fi
        ALOG="$(docker exec -u 0 "$C" sh -c 'tail -20 /data/local/tmp/agent.log 2>/dev/null' 2>/dev/null)"
        INSTANCES="$(docker exec -u 0 "$C" sh -c 'pidof cloudphone-agent 2>/dev/null' 2>/dev/null | tr -d '\r\n')"
        case "$INSTANCES" in *" "*) log "警告：检测到多个 agent 实例（$INSTANCES），先清理再继续"; docker exec -u 0 "$C" sh -c 'for p in $(pidof cloudphone-agent); do kill -9 "$p" 2>/dev/null; done' >/dev/null 2>&1 || true; sleep 2 ;; esac
        ### 2.0.27：成功必须是「服务端确认」，不能只看进程是否活着
        ### （实测踩坑：ws 打 TLS 端口会返回 websocket: bad handshake，旧判据把它当成功，
        ###  于是不会回退到 wss，设备永远不上线。）
        case "$ALOG" in
            *register_agent_ok*|*"Handshake verified"*|*"registered"*)
                log "${SCHEME}: agent 注册成功（pid=$PID，signaling=${SCHEME}://${SIG_HOST}:${SIG_PORT}/register_agent）"
                echo "$ALOG" | while read -r L; do log "    $L"; done
                # 3.7.3：提升 agent 和 media 服务进程优先级，减少调度延迟
                docker exec -u 0 "$C" sh -c "renice -n -10 $PID 2>/dev/null; for p in \$(pidof mediaserver media.swcodec); do renice -n -5 \$p 2>/dev/null; done" || true
                log "进程优先级：agent=-10, media=-5"
                return 0
                ;;
        esac
        case "$ALOG" in
            *"bad handshake"*|*x509*|*certificate*|*"tls:"*)                        REASON="协议/证书不匹配" ;;
            *"no such host"*)                                                       REASON="地址无法解析" ;;
            *"network is unreachable"*|*"connection refused"*|*"no route to host"*) REASON="网络不可达" ;;
            *)                                                                      REASON="未收到服务端确认" ;;
        esac
        log "${SCHEME}: 注册未成功（${REASON}），换下一方案重试；日志尾部："
        docker exec -u 0 "$C" sh -c 'tail -4 /data/local/tmp/agent.log 2>/dev/null' 2>/dev/null | while read -r L; do log "    $L"; done
        docker exec -u 0 "$C" sh -c 'kill "$(pidof cloudphone-agent)" 2>/dev/null' >/dev/null 2>&1 || true
        sleep 2
        continue

    done
    log "自动部署失败：两种协议都未成功，请用 agent_helper.sh status 查看容器内日志"
    return 1
}

### 宿主侧守护：容器重建或 agent 退出后自动重新拉起（幂等，不会重复起）
### 3.2.6 改进：启动时先清理所有旧守护实例（历史残留会互相干扰），检查间隔从60s缩短到30s。
ensure_watchdog() {
    PIDFILE="${VAR_DIR}/agent_watchdog.pid"
    ### 3.2.6：先清理所有旧守护实例（不只是 PIDFILE 里的那个）
    for _p in $(ps -eo pid,args 2>/dev/null | grep -F "$0" | grep -E 'while|sleep [0-9]' | grep -v grep | awk '{print $1}'); do
        [ "$_p" = "$$" ] && continue
        kill -9 "$_p" 2>/dev/null || true
    done
    rm -f "$PIDFILE" 2>/dev/null || true
    sleep 1
    SELF="${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/agent_autodeploy.sh"
    setsid nohup bash -c '
        while :; do
            if bash "'"$SELF"'" --needs-redeploy; then
                TRIM_PKGVAR="'"$VAR_DIR"'" bash "'"$SELF"'" >/dev/null 2>&1
            fi
            sleep 30
        done
    ' >/dev/null 2>&1 < /dev/null &
    echo $! > "$PIDFILE" 2>/dev/null || true
    log "已安装 agent 守护（pid=$(cat "$PIDFILE" 2>/dev/null)，每30s检查一次）"
}
### 2.0.42：守护用判定 —— 需要重新部署时返回 0
### 2.0.52：服务端（穿云投屏）认为设备离线时也应重新部署 —— 实测存在"agent 进程还在、
### 但设备已离线"的僵死态，表现为用户"用一会儿就断连、要手动重连"。
### 3.2.6：移除了基于日志时间的僵死检测（会误判导致反复重启）。
server_says_offline() {
    _j=$(docker exec androidemu-webrtc sh -c 'cat /app/data/devices.json 2>/dev/null' 2>/dev/null)
    [ -n "$_j" ] || return 1
    _seen=$(printf '%s' "$_j" | sed -n 's/.*"last_seen": *"\([^"]*\)".*/\1/p')
    _off=$(printf '%s' "$_j" | sed -n 's/.*"last_offline": *"\([^"]*\)".*/\1/p')
    [ -n "$_seen" ] || return 1
    [ -n "$_off" ] || return 1
    ### ISO 8601 可按字典序比较：离线时间晚于最后在线时间 → 服务端认为已离线
    [ "$_off" \> "$_seen" ]
}

needs_redeploy() {
    running || return 1
    boot_done || return 1
    [ -n "$(agent_pid)" ] || return 0
    docker exec -u 0 "$C" sh -c 'test -s /data/local/tmp/libsys_core.so' >/dev/null 2>&1 || return 0
    server_says_offline && return 0
    return 1
}

case "$ACTION" in
    needs)
        if needs_redeploy; then exit 0; else exit 1; fi
        ;;
    status)
        echo "容器 $C：$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null || echo 未知)"
        echo "ABI：$(docker exec -u 0 "$C" sh -c 'getprop ro.product.cpu.abi' 2>/dev/null | tr -d '\r\n')"
        echo "boot_completed：$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')"
        echo "agent pid：$(agent_pid)"
        echo "本地已缓存 agent：$(ls -1 "$AGENT_DIR" 2>/dev/null | tr '\n' ' ')"
        echo "容器内文件：$(docker exec -u 0 "$C" sh -c 'ls -l /data/local/tmp/cloudphone-agent /data/local/tmp/libsys_core.so 2>/dev/null | awk "{print \$5, \$9}" | tr "\n" " "' 2>/dev/null | tr -d '\r\n')"
        echo "signaling 地址（自动选择）：$(sig_host)"
        echo "--- 容器内 agent 日志尾部 ---"
        docker exec -u 0 "$C" sh -c 'tail -8 /data/local/tmp/agent.log 2>/dev/null' 2>/dev/null || echo "(无)"
        ;;
    *)
        running || { log "容器 $C 未运行，稍后由守护重试"; exit 0; }
        if [ "$FORCE" = "0" ] && [ -n "$(agent_pid)" ]; then exit 0; fi
        WAITED=0
        while [ "$WAITED" -lt "$WAIT" ]; do
            boot_done && break
            sleep 10; WAITED=$((WAITED+10))
        done
        if ! boot_done; then log "安卓尚未 boot_completed（等待 ${WAITED}s），本轮跳过，守护会继续重试"; exit 0; fi
        # 3.8.3：启动优化（lmkd阈值调高、dex2oat优化、关键进程优先级）
        if [ -f "${TRIM_APPDEST:-/vol1/@appcenter/androidemu}/scripts/optimize_boot.sh" ]; then
            bash "${TRIM_APPDEST:-/vol1/@appcenter/androidemu}/scripts/optimize_boot.sh" >/dev/null 2>&1 || true
        fi
        deploy_agent && ensure_watchdog
        ;;
esac
exit 0
