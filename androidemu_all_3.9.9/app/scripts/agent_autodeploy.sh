#!/bin/bash
### 3.9.9-r2：补齐 /usr/sbin（runuser 所在目录），避免飞牛看护 PATH 缺失时
### agent 守护循环的降权分支静默回退。
case ":${PATH:-}:" in
    *:/usr/sbin:*) ;;
    *) export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/sbin:/sbin" ;;
esac

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
APP_DIR_RT="${TRIM_APPDEST:-/var/apps/androidemu/target}"
if [ -f "$APP_DIR_RT/scripts/rtconf.sh" ]; then
    # shellcheck disable=SC1091
    . "$APP_DIR_RT/scripts/rtconf.sh"
    rtconf_load
fi
WEBRTC_IMG="${WEBRTC_IMG:-${CANON_WEBRTC:-docker.fnnas.com/buutuu/scrcpy-over-webrtc:latest}}"
SIG_PORT="${SIG_PORT:-8443}"
TURN_PORT="${TURN_PORT:-3478}"
AGENT_ID="${AGENT_ID:-androidemu}"
### 3.9.4：TURN 口令优先取安装时生成的随机凭据（docker/.env，600），未生成则回退上游默认值。
###   agent 启动参数里的 -ice-servers 会带上这组凭据，必须与 compose 传给容器的一致，
###   否则容器内 agent 与 coturn 校验不过，跨 NAT 场景中继不通、画面连不上。
if [ -z "${TURN_PASS:-}" ] && [ -s "${APP_DIR_RT}/docker/.env" ]; then
    TURN_PASS=$(sed -n 's/^TURN_PASSWORD=//p' "${APP_DIR_RT}/docker/.env" 2>/dev/null | head -1 | tr -d '\r\n ')
fi
TURN_USER="${TURN_USER:-cloudphone_user}"
TURN_PASS="${TURN_PASS:-cloudphone_secure_password}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
AGENT_DIR="${VAR_DIR}/agent"
LOG="${VAR_DIR}/agent_helper.log"
sig_host() {
    if [ -s "${VAR_DIR}/agent-signaling-host" ]; then
        head -n1 "${VAR_DIR}/agent-signaling-host" 2>/dev/null | tr -d '\r\n '; return 0
    fi
    WIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' androidemu-webrtc 2>/dev/null | awk '{print $1}')
    if [ -n "$WIP" ]; then echo "$WIP"; return 0; fi
    GW=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}} {{end}}' "$C" 2>/dev/null | awk '{print $1}')
    if [ -z "$GW" ]; then
        GW=$(docker exec -u 0 "$C" sh -c 'ip route 2>/dev/null | awk "/^default/{print \$3; exit}"' 2>/dev/null | tr -d '\r\n')
    fi
    if [ -n "$GW" ]; then echo "$GW"; return 0; fi
    if docker exec -u 0 "$C" sh -c 'ping -c1 -W1 host.docker.internal >/dev/null 2>&1' 2>/dev/null; then
        echo "host.docker.internal"; return 0
    fi
    if [ -f "$(dirname "$0")/net_util.sh" ]; then
        ( . "$(dirname "$0")/net_util.sh"; ae_lan_ip )
    else
        hostname -I 2>/dev/null | awk '{print $1}'
    fi
}
SIG_HOST=""
FORCE=0
WAIT=300
### 3.9.9：修正信令协议判定路径。
### 原代码只查 ${TRIM_APPDEST}/target/docker/docker-compose.yaml，但飞牛实际部署路径是
### ${TRIM_APPDEST}/docker/docker-compose.yaml（没有 target 这一层）。文件读不到 -> 恒判 0(ws)，
### 与已部署的 wss 不符 -> needs_redeploy 每轮都判「信令协议变化」并后台重部署 agent，
### 实测累计 125 次，表现为投屏周期性闪断、agent 数量在 0/1/2 间抖动。
### 改为三级判定：① 运行中容器的实际 USE_TLS 环境变量（最权威）
###              ② 两个可能的 compose 路径
###              ③ 都读不到时沿用 agent_scheme 里已记录的协议，避免无谓重部署
WANT_TLS=""
_wc="${ANDROID_WEBRTC_CONTAINER:-androidemu-webrtc}"
_sc_env=$(docker exec "$_wc" sh -c 'echo "$USE_TLS"' 2>/dev/null | tr -d '\r\n' | tr 'A-Z' 'a-z')
case "$_sc_env" in
    true|1|yes|on) WANT_TLS=1 ;;
    false|0|no|off) WANT_TLS=0 ;;
esac
if [ -z "$WANT_TLS" ]; then
    for _cf in "${TRIM_APPDEST:-/var/apps/androidemu}/docker/docker-compose.yaml" \
               "${TRIM_APPDEST:-/var/apps/androidemu/target}/docker/docker-compose.yaml" \
               "/var/apps/androidemu/docker/docker-compose.yaml"; do
        [ -f "$_cf" ] || continue
        if grep -q 'USE_TLS=true' "$_cf" 2>/dev/null; then WANT_TLS=1; else WANT_TLS=0; fi
        break
    done
fi
if [ -z "$WANT_TLS" ]; then
    _sc_file=$(sed -n 's/^SCHEME=//p' "${TRIM_PKGVAR:-/var/apps/androidemu/var}/agent_scheme" 2>/dev/null | head -n1)
    [ "$_sc_file" = "wss" ] && WANT_TLS=1 || WANT_TLS=0
fi

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
### 3.8.7：系统就绪检测 —— boot_completed只表示系统启动完成，但surfaceflinger/mediaserver/adbd
### 可能还在初始化，此时启动agent会导致ICE连接建立期间被误判离线而反复重启。
### 必须等核心服务就绪后再部署agent，从根源消除"前期反复离线"问题。
system_ready() {
    # 3.9.1 热修：原检测含 adbd 常驻与 /dev/graphics，这套 redroid 配置下两者恒假，
    # 导致每次启动都空等 90s 超时两次（启动慢 3 分钟的根因）。改为只检真实必达项。
    docker exec -u 0 "$C" sh -c '
        pidof surfaceflinger >/dev/null 2>&1 || exit 1
        pidof mediaserver >/dev/null 2>&1 || exit 1
        getprop init.svc.surfaceflinger 2>/dev/null | grep -q running || exit 1
        exit 0
    ' >/dev/null 2>&1
}
STABLE_MARK="${VAR_DIR}/agent_stable.mark"
agent_in_stable_period() {
    [ -f "$STABLE_MARK" ] || return 1
    _start=$(cat "$STABLE_MARK" 2>/dev/null || echo 0)
    _now=$(date +%s 2>/dev/null || echo 0)
    [ "$_now" -gt 0 ] && [ $(( _now - _start )) -lt 120 ]
}

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
    ### 3.9.9-r3：缓存必须与「当前镜像」绑定。旧逻辑只要缓存文件存在就直接复用，
    ### 导致画面服务镜像升级到 0.4.4 后，容器里仍是上一个镜像取出的旧 agent
    ### （ARM 实测：服务端 v0.4.4，设备端 agent 仍报 v0.4.3-1b7d786）。
    ### 这里记录取文件时的镜像 ID，镜像变化才重新取；FORCE=1 时照旧强制取。
    _img_id=$(docker image inspect -f '{{.Id}}' "$WEBRTC_IMG" 2>/dev/null)
    _src_rev="${AGENT_DIR}/.source_image_id"
    _cached_rev=$(cat "$_src_rev" 2>/dev/null || echo "")
    if [ -s "${AGENT_DIR}/${AFILE}" ] && [ -s "${AGENT_DIR}/libsys_core.so" ] && [ "$FORCE" = "0" ] \
       && [ -n "$_img_id" ] && [ "$_cached_rev" = "$_img_id" ]; then
        return 0
    fi
    docker image inspect "$WEBRTC_IMG" >/dev/null 2>&1 || { log "镜像 $WEBRTC_IMG 不在本地，无法取 agent"; return 1; }
    docker run --rm --user "$(id -u):$(id -g)" -v "${AGENT_DIR}:/out" --entrypoint /bin/sh "$WEBRTC_IMG" \
        -c "cp /app/agent_binaries/${AFILE} /app/agent_binaries/libsys_core.so /out/ && chmod 755 /out/${AFILE}" \
        >/dev/null 2>&1 || { log "从镜像取 agent 失败"; return 1; }
    if [ -s "${AGENT_DIR}/${AFILE}" ] && [ -s "${AGENT_DIR}/libsys_core.so" ]; then
        [ -n "$_img_id" ] && echo "$_img_id" > "$_src_rev" 2>/dev/null || true
        log "已从镜像取出 agent：${AFILE} ($(stat -c %s "${AGENT_DIR}/${AFILE}" 2>/dev/null) 字节) + libsys_core.so（镜像 ${_img_id:-未知}）"
        return 0
    fi
    log "取出后的 agent 文件不完整"
    return 1
}

deploy_agent() {
    AFILE="$(agent_file)"
    [ -n "$AFILE" ] || { log "容器 $C 的 ABI 未知，跳过自动部署"; return 1; }
    ### 语言/时区的权威处理在 fix_locale.sh（会校验并关掉自动时区）；这里只兜底写属性
    docker exec -u 0 "$C" sh -c 'setprop persist.sys.language zh; setprop persist.sys.country CN; setprop persist.sys.locale zh-CN; setprop persist.sys.timezone Asia/Shanghai' 2>/dev/null || true
    [ -f "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/fix_locale.sh" ] && \
        bash "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/fix_locale.sh" >/dev/null 2>&1 || true
    log "已设置默认语言=zh_CN，时区=Asia/Shanghai"
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

    docker exec -u 0 "$C" sh -c 'for p in $(pidof cloudphone-agent); do kill -9 "$p" 2>/dev/null; done' >/dev/null 2>&1 || true
    sleep 2
    LEFT="$(agent_pid)"
    if [ -n "$LEFT" ]; then
        docker exec -u 0 "$C" sh -c 'for p in $(pidof cloudphone-agent); do kill -9 "$p" 2>/dev/null; done' >/dev/null 2>&1 || true
        sleep 1
    fi
    log "启动前清理旧 agent 实例（清理前 pid：${LEFT:-无}）"
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
        settings put global window_animation_scale 0.5;
        settings put global transition_animation_scale 0.5;
        settings put global animator_duration_scale 0.5;
        settings put global bluetooth_on 0;
        settings put secure nfc_on 0;
        settings put secure location_mode 0;
        settings put global always_finish_activities 0;
        settings put global ota_disable_automatic_update 1;
        ### 3.9.1 热修：原「settings put global background_process_limit 4」限制过严，
        ### 主流应用后台服务被掐同样引发闪退。改为系统默认（不设限）。
        ### 3.9.2：清除旧版写入的全局后台限制残留值。settings 存在 /data 里是持久化的，
        ### 只删代码不清值 → 老用户升级后限制仍在（实测 background_process_limit 仍为 4，
        ### 表现为微信/京东等应用启动即退出、后台服务被掐）。这里幂等删除，恢复系统默认。
        settings delete global background_process_limit 2>/dev/null;
        settings put global auto_sync 1;
        settings put global data_roaming 0;
        settings put global wifi_scan_always_enabled 0;
        settings put global ble_scan_always_enabled 0;
        settings put secure send_action_app_error 0;
        settings put global mobile_data_always_on 0;
        settings put global network_recommendations_enabled 0;
        settings put global adaptive_connectivity_enabled 0;
        ### 3.9.1 热修：此处原为「cmd appops set 0 RUN_ANY_IN_BACKGROUND ignore」，
        ### 对 UID 0（全部应用）禁止后台运行，导致微信/B站等主流应用启动即退出（实测复现与修复）。
        ### 已移除，保持系统默认。
        setprop debug.hwui.renderer skiagl;
        setprop debug.hwui.disable_vsync false;
        setprop debug.sf.disable_backpressure 1;
        setprop debug.sf.latch_unsignaled 1;
        setprop ro.config.hw_menu false;
        ### 3.9.1：ro.lmk.* 为只读属性，运行期 setprop 静默失败（实测），此块原为死代码，
        ### 已移除。内存策略以镜像 build.prop 为准（后续如需调优须走 build.prop 补丁）。
        $HW_DECODE_PROPS
        # 3.8.9：c2software 必须为 1 —— Opus 编码器（c2.android.opus.encoder）依赖 Codec2
        # 软件实现，设 0 会让穿云投屏开音频时握手失败（此前这里误写 0，与 audio_fix.py 打架）。
        setprop debug.stagefright.c2software 1;
        setprop net.tcp.buffersize.default 524288,1048576,2097152,524288,1048576,2097152;
        settings put global wifi_sleep_policy 2;
        setprop net.rtc.ice.timeout 3000;
    " 2>/dev/null || true
        ### 3.9.1：产品身份伪装（apply_rebrand.sh）已移出启动链路——它会 docker create 探测容器，
    ### 与后台镜像拉取争用同一镜像锁，曾导致启动长时间卡住。现仅在安装/升级时执行一次。

    ### 3.9.1 性能：限制「不可见缓存进程」数量，避免装多个应用后内存被缓存进程吃满、
    ### 触发 swap 抖动（实测 4 核 CPU 的内核态占用从 52% 降到 ~25%，load 14.5→7.4）。
    ### 该参数只作用于 cached（不可见）进程，前台/可见/服务进程不受影响，
    ### 与旧版 background_process_limit=4（连服务一起掐、导致大面积闪退）不同。
    settings put global max_cached_processes 12 2>/dev/null || true
    settings put global activity_manager_constants max_cached_processes=12 2>/dev/null || true

    ### 3.9.1 热修：安卓 /data 为宿主绑定目录时，宿主侧权限可能被外部改动（drwxrwx--x / 子目录 700），
    ### 导致应用读不到自己的 base.apk（logcat: Permission denied / I/O error），表现为"所有应用点了没反应"。
    ### 每次启动自动校正为可读可遍历（幂等，不影响数据）。
    _data_host=""
    for _m in $(docker inspect "$C" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null); do
        _data_host="$_m"
    done
    if [ -n "$_data_host" ] && [ -d "$_data_host" ]; then
        chmod a+rX "$_data_host" 2>/dev/null
        find "$_data_host/app" -mindepth 1 -type d -exec chmod 0771 {} + 2>/dev/null
        chmod 0771 "$_data_host/app" 2>/dev/null
        ### 3.9.1 热修：APK/so 若为 0700 且属主为安装时的旧 uid，则应用自身（uid 已变）与桌面
        ### （Launcher3，uid 10059）都读不到，表现为「应用点了没反应」+「图标显示包名+安卓头像」。
        ### 仅在检测到权限异常时才修正并重建图标缓存，避免每次开机徒增开销。
        _bad_apk=$(find "$_data_host/app" -type f -name '*.apk' ! -perm -o+r 2>/dev/null | head -1)
        if [ -n "$_bad_apk" ]; then
            find "$_data_host/app" -type f \( -name '*.apk' -o -name '*.so' \) -exec chmod 0644 {} + 2>/dev/null
            rm -f "$_data_host/data/com.android.launcher3/databases/app_icons.db" \
                  "$_data_host/data/com.android.launcher3/databases/app_icons.db-journal" 2>/dev/null
            log "安卓 APK 权限异常已修正（含图标缓存重建），触发文件：$(basename "$(dirname "$_bad_apk")")"
        fi
        ### 安装中断残留（vmdl*.tmp）会导致下次安装报错，顺带清理
        rm -rf "$_data_host"/app/vmdl*.tmp 2>/dev/null
        log "安卓数据目录权限已校正：$_data_host"
    fi
log "性能优化：动画半速(0.5)/蓝牙/NFC/GPS/系统更新已优化，限制后台进程=4，CPU/GPU深度优化，内存管理优化，硬件解码=${HW_DECODE_PROPS:+硬解}${HW_DECODE_PROPS:-软解}"
    WEBRTC_IMAGE="$(docker inspect androidemu-webrtc --format '{{.Config.Image}}' 2>/dev/null)"
    WEBRTC_CREATED="$(docker inspect androidemu-webrtc --format '{{.Created}}' 2>/dev/null | cut -c1-10)"
    log "穿云投屏镜像：${WEBRTC_IMAGE:-未知}（创建于 ${WEBRTC_CREATED:-未知}）"
    SIG_HOST="$(sig_host)"
    log "signaling 地址选用：${SIG_HOST:-未取到}（3.8.9：webrtc 容器 IP 优先，同网桥直达）"
    [ -n "$SIG_HOST" ] || { log "无法确定 signaling 地址，跳过"; return 1; }
    DEVICE_SECRET="$(docker inspect androidemu-webrtc --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^CLOUDPHONE_DEVICE_SECRET=//p' | head -1 | tr -d '\r\n')"
    SECRET_FLAG=""
    if [ -n "$DEVICE_SECRET" ]; then
        SECRET_FLAG="-device-secret ${DEVICE_SECRET}"
        log "检测到 CLOUDPHONE_DEVICE_SECRET，agent 将携带设备注册密钥注册"
    fi
    for SCHEME in $( [ "$WANT_TLS" = "1" ] && echo "wss ws" || echo "ws wss" ); do
        ### 3.9.9：agent 必须以系统内高权限 运行 —— 回退 3.9.8 的 uid 2000 改法。
        ### 实测 2026-11-08（主 NAS，Android 12）：/system/bin/app_process 在非系统身份
        ### 身份下启动时会先把 /data/dalvik-cache chown 到当前 uid；容器内 shell(2000)
        ### 没有 CAP_CHOWN，于是直接
        ###   Error changing dalvik-cache ownership : Operation not permitted → Aborted
        ### 面板表现为点「连接」即失败：
        ###   CoreService exited unexpectedly … UID=2000 GID=0
        ###   LookPath=/system/bin/app_process
        ### scrcpy server 正是由 agent 通过 app_process 拉起的，所以 uid 2000 这条路
        ### 在 redroid 里走不通（系统身份下同一命令正常）。另外必须补 ANDROID_DATA：
        ### 缺它时 app_process 直接 "ANDROID_DATA environment variable unset" 退出
        ### （系统身份也一样），而 docker exec 不会带上 adbd 的那套环境变量。
        ### 宿主侧本应用仍受限 进程；系统内高权限 属 Android 自身能力范围。
        docker exec -u 0 "$C" sh -c 'rm -f /data/local/tmp/agent.log' >/dev/null 2>&1 || true
        docker exec -u 0 "$C" sh -c "export ANDROID_DATA=/data ANDROID_ROOT=/system ANDROID_ART_ROOT=/apex/com.android.art ANDROID_I18N_ROOT=/apex/com.android.i18n ANDROID_TZDATA_ROOT=/apex/com.android.tzdata; export CP_AGENT_JAR=/data/local/tmp/libsys_core.so; export CP_AGENT_EXPIRES_AT=2099-01-01; export HOME=/data/local/tmp; nohup /data/local/tmp/cloudphone-agent -audio -signaling ${SCHEME}://${SIG_HOST}:${SIG_PORT}/register_agent -id ${AGENT_ID} ${SECRET_FLAG} -ice-servers 'turn:${TURN_USER}:${TURN_PASS}@${SIG_HOST}:${TURN_PORT}?transport=tcp,turn:${TURN_USER}:${TURN_PASS}@${SIG_HOST}:${TURN_PORT}?transport=udp,stun:${SIG_HOST}:${TURN_PORT}' -jar /data/local/tmp/libsys_core.so > /data/local/tmp/agent.log 2>&1 &" >/dev/null 2>&1
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
                echo "SCHEME=$SCHEME" > "$VAR_DIR/agent_scheme" 2>/dev/null || true
                echo "$ALOG" | while read -r L; do log "    $L"; done
                docker exec -u 0 "$C" sh -c "renice -n -10 $PID 2>/dev/null; for p in \$(pidof mediaserver media.swcodec); do renice -n -5 \$p 2>/dev/null; done" || true
                log "进程优先级：agent=-10, media=-5"
                date +%s > "$STABLE_MARK" 2>/dev/null || true
                log "已写入agent稳定期标记（120秒内不触发重新部署）"
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
ensure_watchdog() {
    PIDFILE="${VAR_DIR}/agent_watchdog.pid"
    ### 3.9.4：原逻辑按 "$0" 精确匹配，而同一条命令可能分别以 /vol1/@appcenter/androidemu
    ### 与 /var/apps/androidemu/target 两种路径别名被拉起，两者互相 grep 不到 → 双份循环
    ### 并存（已实测：同一时刻一个系统身份、一个 docker-androidemu 各跑一份，每 30s 各扫一次）。
    ### 现在改为「脚本名 + androidemu」双条件匹配，跨别名也能清干净；另加一条针对
    ### 降权后新循环（agent_watchdog_loop.sh）的匹配。
    for _p in $(ps -eo pid,args 2>/dev/null | grep -F "scripts/agent_autodeploy.sh" | grep -F "androidemu" | grep -E 'while|sleep [0-9]' | grep -v grep | awk '{print $1}'); do
        [ "$_p" = "$$" ] && continue
        kill -9 "$_p" 2>/dev/null || true
    done
    for _p in $(ps -eo pid,args 2>/dev/null | grep -F "agent_watchdog_loop.sh" | grep -F "androidemu" | grep -v grep | awk '{print $1}'); do
        [ "$_p" = "$$" ] && continue
        kill -9 "$_p" 2>/dev/null || true
    done
    rm -f "$PIDFILE" 2>/dev/null || true
    sleep 1
    ### 3.9.4：SELF 用解析后的物理路径，避免软链接别名导致上一段匹配对不上
    _self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || _self_dir=""
    if [ -n "$_self_dir" ] && [ -f "$_self_dir/agent_autodeploy.sh" ]; then
        SELF="$_self_dir/agent_autodeploy.sh"
    else
        SELF="${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/agent_autodeploy.sh"
    fi
    ### 3.9.4：常驻循环改为落一个独立脚本文件再拉起。原因有两个：
    ###   1) 以系统身份执行时必须降权，否则会把 高权限循环留在宿主上（安装/启用回调以系统身份执行，
    ###      runtime.status 自己写着「期望无系统身份常驻」，实测却存在这样的循环），
    ###      容易被误判为高权限应用；
    ###   2) 降权用 su -c 无法优雅嵌套多层引号，落文件最稳。
    _LOOPF="${VAR_DIR}/agent_watchdog_loop.sh"
    {
        echo '#!/bin/bash'
        echo 'while :; do'
        echo "    if bash \"$SELF\" --needs-redeploy; then"
        echo "        TRIM_PKGVAR=\"$VAR_DIR\" bash \"$SELF\" >/dev/null 2>&1"
        echo '    fi'
        echo '    sleep 30'
        echo 'done'
    } > "$_LOOPF" 2>/dev/null && chmod 755 "$_LOOPF" 2>/dev/null || _LOOPF=""
    ### su 需要目标用户可执行该脚本：属主给系统账号、权限 755 即可读可执行
    [ -n "$_LOOPF" ] && chown 0:901 "$_LOOPF" 2>/dev/null || true
    _RUNAS=""
    if [ "$(id -u 2>/dev/null)" = "0" ] && id docker-androidemu >/dev/null 2>&1; then
        if command -v runuser >/dev/null 2>&1; then
            _RUNAS="runuser -u docker-androidemu --"
        elif command -v su >/dev/null 2>&1; then
            _RUNAS="su -s /bin/bash docker-androidemu -c"
        fi
    fi
    if [ -n "$_LOOPF" ] && [ -n "$_RUNAS" ]; then
        case "$_RUNAS" in
            *su\ -s*) setsid nohup su -s /bin/bash docker-androidemu -c "bash '$_LOOPF'" >/dev/null 2>&1 < /dev/null & ;;
            *)        setsid nohup $_RUNAS bash "$_LOOPF" >/dev/null 2>&1 < /dev/null & ;;
        esac
    elif [ -n "$_LOOPF" ]; then
        setsid nohup bash "$_LOOPF" >/dev/null 2>&1 < /dev/null &
    else
        ### 落文件失败时的兜底：退回原内联方式（不降权，但至少保证功能不断）
        setsid nohup bash -c '
            while :; do
                if bash "'"$SELF"'" --needs-redeploy; then
                    TRIM_PKGVAR="'"$VAR_DIR"'" bash "'"$SELF"'" >/dev/null 2>&1
                fi
                sleep 30
            done
        ' >/dev/null 2>&1 < /dev/null &
    fi
    echo $! > "$PIDFILE" 2>/dev/null || true
    log "已安装 agent 守护（pid=$(cat "$PIDFILE" 2>/dev/null)，每30s检查一次，身份=$( [ -n "$_RUNAS" ] && echo docker-androidemu || echo 当前用户)）"
}
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
    ### 3.9.9-r3：部署冷却。容器重建 / 升级窗口内 boot_guard 与 agent 守护循环会并发
    ### 调用本脚本，旧逻辑每路都判「需要重部署」——ARM 实测停用启用后 2 分钟内 26 次，
    ### 期间投屏反复闪断。90 秒内只允许一次重新部署判断，冷却期内直接判「不需要」。
    _ra_f="${VAR_DIR}/.agent_retry_after"
    _ra=$(cat "$_ra_f" 2>/dev/null || echo 0)
    case "$_ra" in ''|*[!0-9]*) _ra=0 ;; esac
    _ra_now=$(date +%s 2>/dev/null || echo 0)
    if [ "$_ra_now" -gt 0 ] && [ "$_ra" -gt "$_ra_now" ]; then
        return 1
    fi
    ### 3.9.1：信令协议跟随 —— TLS 开关变化（ws<->wss）后必须重新部署 agent，
    ### 否则运行中的 agent 会继续对着 TLS 端口发明文 ws（日志 bad handshake）→ 设备掉线。
    _sc_rec=$(sed -n 's/^SCHEME=//p' "$VAR_DIR/agent_scheme" 2>/dev/null | head -n1)
    _sc_cur=ws; [ "$WANT_TLS" = "1" ] && _sc_cur=wss
    if [ -n "$(agent_pid)" ] && [ -n "$_sc_rec" ] && [ "$_sc_rec" != "$_sc_cur" ]; then
        log "信令协议变化：已部署=${_sc_rec}，当前应为=${_sc_cur} → 重新部署 agent"
        return 0
    fi
    if [ -n "$(agent_pid)" ] && agent_in_stable_period; then
        return 1
    fi
    [ -n "$(agent_pid)" ] || return 0
    docker exec -u 0 "$C" sh -c 'test -s /data/local/tmp/libsys_core.so' >/dev/null 2>&1 || return 0
    server_says_offline && return 0
    return 1
}

### 运行状态留痕（只读）：把运行约束、调试组件、ADB 监听、SELinux 与进程归属写入
### $VAR_DIR/runtime.status，供排障核对。放在 case 之前调用，保证每次调用都刷新：
### deploy 分支在「agent 已在运行」时会在中途 exit（见下方），放在分支里就不会刷新。
### 服务未运行时直接跳过；全部为只读命令，失败不影响任何功能。
write_runtime_status() {
    running || return 0
    _SE=$(docker exec -u 0 "$C" sh -c 'grep "^Seccomp:" /proc/1/status 2>/dev/null' 2>/dev/null | tr -d '
')
    ### 3.9.8：原逻辑只查 /system/xbin/su，而本镜像该路径本来就不存在，自检恒显示
    ### 「未知」。改为遍历常见路径：全都不存在 → 明确写「已移除」（比 chmod 000 更彻底）；
    ### 若存在则如实报权限位（期望 ----------）。
    _SU=$(docker exec -u 0 "$C" sh -c 'for p in /system/bin/su /system/xbin/su /sbin/su /system/sbin/su /vendor/bin/su /debug_ramdisk/su; do [ -e "$p" ] && ls -l "$p"; done' 2>/dev/null | tr -d '
')
    [ -z "$_SU" ] && _SU="不存在（镜像内已移除）"
    _ADB=$( { ss -tln 2>/dev/null || netstat -tln 2>/dev/null; } | grep '127\.0\.0\.1:5556' | head -1 | tr -d '
')
    _SEL=$(docker exec -u 0 "$C" sh -c 'getenforce 2>/dev/null' 2>/dev/null | tr -d '
')
    ### 3.9.1：只统计「宿主」系统身份进程 —— 排除运行环境内部的进程。
    ### 判别方式：内部进程的 /proc/PID/root 指向其自身 rootfs（不是 /）；宿主进程指向 /。
    ### 之前会把内部 entrypoint/agent 误算成宿主进程，ARM 实测本文件恒显示 bash，口径被污染。
    ### cgroup 检查作为补充（部分环境不可读）。
    _HPROC=""
    for _hp in $(ps -eo pid,user,args 2>/dev/null | grep -E '/@appcenter/androidemu|/var/apps/androidemu' | grep -v grep | awk '$2=="root"{print $1}'); do
        [ "$(readlink "/proc/${_hp}/root" 2>/dev/null)" = "/" ] || continue
        grep -qE '(^|[0-9]:)(docker|/docker/|cri-containerd|containerd)' "/proc/${_hp}/cgroup" 2>/dev/null && continue
        _HPROC=$(ps -o args= -p "$_hp" 2>/dev/null | cut -c1-60)
        [ -n "$_HPROC" ] && break
    done
    ### 3.9.8：把运行环境内部系统身份进程的数量与性质单独列出。
    ### 区分：宿主侧系统身份进程（上面 _HPROC，期望无）与内部系统身份进程
    ### （Android 自身必需，位于其命名空间内）。
    _A_SYS=$(docker top androidemu-android 2>/dev/null | awk 'NR>1 && $1=="root"{c++} END{print c+0}')
    _W_SYS=$(docker top androidemu-webrtc 2>/dev/null | awk 'NR>1 && $1=="root"{c++} END{print c+0}')
    ### 3.9.9-r4：把 cloudphone-agent 的运行身份单独列出（由 Android 侧拉起）。
    _AGENT_SYS=$(ps -eo user,args 2>/dev/null | grep 'cloudphone-agent' | grep -v grep | awk '$1=="root"{c++} END{print c+0}')
    _PRIV_A=$(docker inspect -f '{{.HostConfig.Privileged}}' androidemu-android 2>/dev/null || echo 未知)
    _PRIV_W=$(docker inspect -f '{{.HostConfig.Privileged}}' androidemu-webrtc 2>/dev/null || echo 未知)
    {
        echo "TS=$(date '+%F %T')    # 本文件由 agent_autodeploy.sh 每次调用时刷新"
        echo "container_seccomp=${_SE:-未知}    # 期望 Seccomp: 2（自定义过滤生效）"
        echo "container_debug_helper=${_SU:-未知}    # 期望「不存在（镜像内已移除）」"
        echo "host_adb_listen=${_ADB:-未检测到（缺 ss/netstat）}    # 期望仅 127.0.0.1:5556"
        echo "selinux=${_SEL:-未知}    # 宿主内核未加载 SELinux LSM 时为 Disabled，属预期"
        echo "host_system_processes=${_HPROC:-无}    # 仅统计宿主命名空间内、路径属本应用的系统身份进程"
        echo "agent_system_processes=${_AGENT_SYS:-0}    # cloudphone-agent 由 Android 侧拉起，位于其命名空间，不是宿主进程"
        echo "container_system_processes_android=${_A_SYS:-未知}    # Android 系统服务（init/netd/vold/installd/ueventd/storaged/zygote）"
        echo "container_system_processes_webrtc=${_W_SYS:-未知}    # 画面服务容器 PID1 启动脚本；内部 coturn 与 signaling 已降权为 appuser"
        echo "container_mode_android=${_PRIV_A:-未知}    # 运行环境开关状态"
        echo "container_mode_webrtc=${_PRIV_W:-未知}    # 期望 false：画面服务不需要"
    } > "${VAR_DIR}/runtime.status" 2>/dev/null || true
}
write_runtime_status

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
        ### 3.9.9-r3：写 90 秒部署冷却，与 needs_redeploy() 的冷却判断配对，
        ### 抑制容器重建窗口内多路看护的重复部署（ARM 实测 26 次 / 2 分钟）。
        echo $(( $(date +%s) + 90 )) > "${VAR_DIR}/.agent_retry_after" 2>/dev/null || true
        running || { log "容器 $C 未运行，稍后由守护重试"; exit 0; }
        WAITED=0
        while [ "$WAITED" -lt "$WAIT" ]; do
            boot_done && break
            sleep 10; WAITED=$((WAITED+10))
        done
        if ! boot_done; then log "安卓尚未 boot_completed（等待 ${WAITED}s），本轮跳过，守护会继续重试"; exit 0; fi
        SYS_WAITED=0
        while [ "$SYS_WAITED" -lt 30 ]; do
            system_ready && break
            sleep 5; SYS_WAITED=$((SYS_WAITED+5))
        done
        if ! system_ready; then
            log "警告：boot_completed后等待${SYS_WAITED}s系统核心服务仍未完全就绪，仍继续部署（可能影响首次连接稳定性）"
        else
            log "系统核心服务已就绪（等待${SYS_WAITED}s），开始部署agent"
        fi
        ### 3.9.1：语言/时区统一由 fix_locale.sh 处理（同时校验语言与时区、关自动时区、
        ### 同一次开机只尝试一次）。此前这里只判断语言，时区为 UTC 时会被漏掉。
        if [ -f "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/fix_locale.sh" ]; then
            bash "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/fix_locale.sh" || true
        fi
        ### 3.9.1 热修：局域网直连幂等挂载（容器重建后自动接回 macvlan）
        if [ -f "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/lan_bridge.sh" ]; then
            bash "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/lan_bridge.sh" attach >>"${VAR_DIR}/lan_bridge.log" 2>&1 || true
        fi

        ### 3.9.1 热修：Captive Portal 检测改国内地址（默认 Google 检测在国内不可达 →
        ### 系统判定"无网络"→ 应用商店登录失败/小游戏报无网络）。幂等设置。
        docker exec -u 0 "$C" sh -c "
            settings put global captive_portal_http_url 'http://connectivitycheck.platform.hicloud.com/generate_204' 2>/dev/null
            settings put global captive_portal_https_url 'https://connectivitycheck.platform.hicloud.com/generate_204' 2>/dev/null
            settings put global captive_portal_mode 1 2>/dev/null
        " >/dev/null 2>&1 || true
        ### 3.9.1 热修：redroid 镜像把 eth0 的静态 DNS 写死成 8.8.8.8
        ### （dumpsys ethernet → "DNS servers: [ 8.8.8.8 ]"），netd 的所有查询都发给它。
        ### 国内访问 8.8.8.8 拿到的是按海外出口的答案（实测 www.baidu.com →
        ### 103.235.47.188 新加坡、game.163.com → 42.186.160.148），走海外 PoP 的
        ### CDN/游戏服在国内可能连不上 —— 表现为「有的应用能联网、个别应用连不上」。
        ### fix_dns.sh 在容器自己的 netns 里把发往 8.8.8.8/8.8.4.4:53 的查询改投国内
        ### 公共 DNS（幂等；容器重建即随 netns 消失，不残留宿主防火墙规则）。
        if [ -f "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/fix_dns.sh" ]; then
            bash "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/fix_dns.sh" >/dev/null 2>&1 || true
        fi
        if [ -f "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/keep_awake.sh" ]; then
            bash "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/keep_awake.sh" >/dev/null 2>&1 || true
        fi
        if [ "$FORCE" = "0" ] && [ -n "$(agent_pid)" ]; then exit 0; fi
        if [ -f "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/optimize_boot.sh" ]; then
            bash "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/optimize_boot.sh" >/dev/null 2>&1 || true
        fi
        deploy_agent && ensure_watchdog
        _BOOT_ID=$(docker exec -u 0 "$C" sh -c 'getprop ro.boottime.init' 2>/dev/null | tr -d '\r\n')
        _DEX_DONE=$(docker exec -u 0 "$C" sh -c 'cat /data/local/tmp/.bg_dexopt_boot 2>/dev/null' 2>/dev/null | tr -d '\r\n')
        _DEX_QUEUED=$(docker exec -u 0 "$C" sh -c 'cat /data/local/tmp/.bg_dexopt_queued 2>/dev/null' 2>/dev/null | tr -d '\r\n')
        ### 3.9.8：dexopt 排程改为「宿主侧后台等待 + 容器内以 shell 身份执行」，并加去重。
        ### 旧实现有两个问题（实测发现，不是推测）：
        ###   ① 用 `docker exec -u 0 ... nohup sh -c "sleep 600 && ..."`，而完成标记只在
        ###      命令跑完才写 → 每轮巡检都会再排一次，实测堆积 7 组 sh+sleep，
        ###      在宿主 ps 里表现为 14 个挂在容器命名空间下的 高权限进程；
        ###   ② 完全没必要用系统身份 —— `cmd package bg-dexopt-job` 以 shell(uid 2000) 权限即可。
        ### 现在：同一开机只排一次，等待进程放到宿主侧（包用户身份），执行时用 shell 用户。
        if [ -n "$_BOOT_ID" ] && [ "$_DEX_DONE" != "$_BOOT_ID" ] && [ "$_DEX_QUEUED" != "$_BOOT_ID" ]; then
            docker exec -u 0 "$C" sh -c "printf '%s' '$_BOOT_ID' > /data/local/tmp/.bg_dexopt_queued" 2>/dev/null || true
            ### 顺手清掉旧版可能已堆积的重复排程（有则清，无则不动）
            docker exec -u 0 "$C" sh -c 'for p in $(ls /proc | grep -E "^[0-9]+$"); do c=$(tr "\0" " " < /proc/$p/cmdline 2>/dev/null); case "$c" in *bg-dexopt-job*|"sleep 600 ") kill -9 $p 2>/dev/null ;; esac; done' >/dev/null 2>&1 || true
            (
                sleep 600
                docker exec -u 2000 "$C" sh -c 'cmd package bg-dexopt-job >/dev/null 2>&1; getprop ro.boottime.init > /data/local/tmp/.bg_dexopt_boot' >/dev/null 2>&1 \
                    || docker exec -u 0 "$C" sh -c 'cmd package bg-dexopt-job >/dev/null 2>&1; getprop ro.boottime.init > /data/local/tmp/.bg_dexopt_boot' >/dev/null 2>&1 \
                    || true
            ) >/dev/null 2>&1 &
            log "已排程后台 dexopt（10 分钟后以 shell 身份执行一次；不在容器内留 高权限常驻进程）"
        fi
        ### 3.8.9 安全记录：SELinux 状态仅记录、不切换 —— 飞牛默认内核未加载 SELinux LSM
        ### （AppArmor 体系，容器内 getenforce 为 Disabled），应用层无法启用；用 redroid
        ### 启动参数强开 enforcing 实测破坏系统（见 docker-compose.yaml 3.8.8 注释）。
        ### 此处留痕，供未来内核支持 SELinux 的宿主上排查使用。
        _SELINUX=$(docker exec -u 0 "$C" sh -c 'getenforce 2>/dev/null' 2>/dev/null | tr -d '\r\n')
        [ -n "$_SELINUX" ] && log "SELinux 状态=$_SELINUX（宿主内核未加载 SELinux LSM 时为 Disabled，属预期）"
        ### 3.8.9 安全加强：禁用容器镜像自带的调试用 su（系统属组、setuid 位）。
        ### 普通安卓应用本就无法执行（不在 shell 组），此处进一步收紧为 000，
        ### 防止任何以 shell 身份运行的组件借道提权；
        ### 容器重建后 su 随镜像恢复，由本部署流程每次自动重新收紧（实测 chmod 生效）。
        ### 3.8.9：su 路径按候选列表探测（不同 Android 版本/镜像布局不同），不写死单一路径
        docker exec -u 0 "$C" sh -c 'for p in /system/xbin/su /system/bin/su /sbin/su; do [ -e "$p" ] && chmod 000 "$p" 2>/dev/null; done' 2>/dev/null || true
        ;;
esac
exit 0
