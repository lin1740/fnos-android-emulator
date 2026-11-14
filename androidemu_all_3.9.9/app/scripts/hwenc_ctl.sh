#!/bin/bash
### 3.9.9-r2：补齐 /usr/sbin（runuser 所在目录），避免飞牛回调/看护 PATH 缺失时
### "setsid -f runuser" 报 No such file or directory，硬编 daemon 起不来。
case ":${PATH:-}:" in
    *:/usr/sbin:*) ;;
    *) export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/sbin:/sbin" ;;
esac

### ============================================================================
### androidemu 硬件视频编码控制脚本（redroid-hwenc v0.2.0 / Codec2 HIDL + 宿主 daemon）
### 用法：hwenc_ctl.sh {status|enable|disable|repair|check}
###
### 设计原则（重要，改动前先读完）：
###   1. 默认不启用。未启用时容器 ccodec=0 走 OMX 软件编码，与本功能加入前完全一致。
###   2. 启用顺序严格：dma_heap 权限 → 容器注入 → HIDL 注册 → 属性 → 验证。
###      顺序错的后果：ccodec 已置 4 但硬件组件不可用 → mediaserver 卡死在 Codec2
###      枚举（dumpsys 超时）→ cloudphone-agent 掉线 → 投屏中断（实测踩过）。
###   3. 任何一步失败立即回退到 OMX 软件编码，投屏优先于硬编。
###   4. /dev/dma_heap/system 必须 chmod 666：redroid 默认 0444，会导致
###      c2.android.* 软件编码器 "fetch linear block err=14" 直接失败。
###      改 666 后超限分辨率（手机/平板）才能安全退回软件编码。
###   5. 容器重启会重置 ccodec=0 和 dma_heap 0444，boot_guard 调用 repair 恢复。
### ============================================================================

set +e

APP_DIR="${TRIM_APPDEST:-/vol1/@appcenter/androidemu}"
VAR_DIR="${TRIM_PKGVAR:-/vol1/@appdata/androidemu/var}"
RUN_USER="${TRIM_RUN_USERNAME:-docker-androidemu}"
CT="androidemu-android"
ART="$APP_DIR/hwenc/artifacts/android11-hidl"
DAEMON_BIN="$APP_DIR/hwenc/bin/daemon"
### 3.9.9：硬件解码为**独立可选档**。原有 daemon 是 HWDEC=0（只编码）编译的；
### daemon-hwdec 是同一份源码加 -DHAVE_HWDEC、静态链精简 libavcodec 编出来的，
### 由 GitHub Actions 生成。两者并存，默认仍用旧 daemon —— 硬解没验证出图之前，
### 绝不替换现有编码链路。开启方式：hwenc_ctl.sh decode on。
DAEMON_HWDEC="$APP_DIR/hwenc/bin/daemon-hwdec"
DECODE_CONF="$VAR_DIR/hwenc.decode"
LOG="$VAR_DIR/hwenc.log"
STATUS="$VAR_DIR/hwenc.status"
BK="$VAR_DIR/hwenc/backup"
### 3.9.9：共享目录必须按「容器 /data 的真实挂载点」推导，不能写死路径。
### 实测 2026-11-09：容器 /data 绑的是 /vol1/@appdata/androidemu/vol-data/androidemu-data，
### 而早期实现写的是 $VAR_DIR/vol-data/... （多一层 var），socket 建在了容器看不到的位置
### → 组件连不上、列表里没有硬件编码器，而 ccodec 已被设为 4，软件编码也跟着坏。
SHARED="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$CT" 2>/dev/null)"
if [ -n "$SHARED" ]; then
    SHARED="$SHARED/vaapi-helper"
else
    SHARED="$VAR_DIR/vol-data/androidemu-data/vaapi-helper"
fi
FORCE="${ANDROIDEMU_HWENC_FORCE:-0}"

mkdir -p "$VAR_DIR/hwenc" 2>/dev/null

log() {
    local m="[$(date '+%F %T')] $*"
    echo "$m"
    echo "$m" >> "$LOG" 2>/dev/null
}

### 防止日志无限增长
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ] && tail -c 131072 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"

dex() { docker exec "$CT" sh -c "$1" 2>/dev/null; }

### ---------------------------------------------------------------------------
### 能力检测：输出原因，返回 0=可用 1=不可用
### ---------------------------------------------------------------------------
detect() {
    _ARCH=$(uname -m 2>/dev/null)
    _WHY=""

    if [ "$_ARCH" != "x86_64" ]; then
        _WHY="架构 $_ARCH 无预编译产物（本组件仅 x86_64）"
        return 1
    fi

    if ! command -v vainfo >/dev/null 2>&1; then
        _WHY="宿主缺少 vainfo（libva-utils），无法判定 GPU 编码能力"
        return 1
    fi

    if ! vainfo >/dev/null 2>&1; then
        _WHY="vainfo 执行失败，VA-API 不可用"
        return 1
    fi

    if ! vainfo 2>/dev/null | grep -qE 'VAEntrypointEnc(Slice|Picture|SliceLP)'; then
        _WHY="GPU 无 VA-API 硬件编码入口（只有解码，如 NVIDIA 走 nvidia-vaapi-driver）"
        return 1
    fi

    _GPU=$(vainfo 2>/dev/null | grep -m1 -i 'Driver version' | sed 's/.*driver: //' | cut -c1-90)
    _ENC=$(vainfo 2>/dev/null | grep -cE 'EncSlice')

    ### AMD 传统 radeon 内核驱动（GCN 1.0/2.0 老卡）。
    ### 注意：redroid 自带的 OMX-VAAPI 链路在这类机器上会黑屏（3.9.2 已回滚），
    ### 但本组件走 Codec2 HIDL + 宿主 daemon，是另一套机制 —— 实测在 AMD Kaveri
    ### (A8-7500 / VCE 2.0) 上可用，上限 1920x1088。故这里只警告不拒绝，
    ### 但要在启用结果里明确告知：竖屏分辨率（手机/平板）用不上硬件编码。
    _KDRV=""
    [ -d /sys/module/amdgpu ] && _KDRV="amdgpu"
    [ -d /sys/module/radeon ] && _KDRV="radeon"
    if [ "$_KDRV" = "radeon" ]; then
        _WARN_RADEON="AMD 传统 radeon 驱动（GCN 1.0/2.0）：硬件编码上限约 1920x1088，仅横屏可用"
    fi

    if ! docker inspect "$CT" >/dev/null 2>&1; then
        _WHY="容器 $CT 不存在"
        return 1
    fi

    if [ ! -x "$DAEMON_BIN" ]; then
        _WHY="缺少 daemon 二进制 $DAEMON_BIN"
        return 1
    fi

    if [ ! -d "$ART" ]; then
        _WHY="缺少组件产物目录 $ART"
        return 1
    fi

    ### daemon 动态库依赖自检（宿主库缺失时提前失败，不要等运行时）
    if ! ldd "$DAEMON_BIN" 2>/dev/null | grep -q 'not found' ; then
        :
    else
        _WHY="daemon 依赖缺失：$(ldd "$DAEMON_BIN" 2>/dev/null | grep 'not found' | head -2 | tr '\n' ' ')"
        return 1
    fi

    return 0
}

### 当前分辨率里最高的两个维度，用于提示（不影响启用）
res_summary() {
    local f="$VAR_DIR/resolution.conf" s
    if [ -f "$f" ]; then
        s=$(grep -E '^(PC|PHONE|TABLET)=' "$f" 2>/dev/null | tr '\n' ' ')
        [ -n "$s" ] && { echo "$s"; return; }
    fi
    ### 3.9.9：配置文件缺失（安装回调未执行到底时会这样）时退回读容器实际分辨率，
    ### 不要只回「未知」——那会让状态输出失去参考价值。
    s=$(current_wh)
    echo "无配置文件，当前实际 ${s:-未知}"
}

### ---------------------------------------------------------------------------
### 容器内注入（幂等）
### ---------------------------------------------------------------------------
inject() {
    log "注入组件到容器 /vendor"
    docker cp "$ART/." "$CT:/data/local/tmp/hwenc-pkg/" >/dev/null 2>&1 || {
        dex "mkdir -p /data/local/tmp/hwenc-pkg" >/dev/null
        docker cp "$ART/." "$CT:/data/local/tmp/hwenc-pkg/" >/dev/null 2>&1
    }

    dex '
set -e
P=/data/local/tmp/hwenc-pkg
mkdir -p /vendor/bin/hw /vendor/lib64 /vendor/etc/init /vendor/etc/vintf/manifest /vendor/etc/seccomp_policy
cp -f $P/bin/hw/android.hardware.media.c2@1.1-vaapi-service /vendor/bin/hw/
chmod 755 /vendor/bin/hw/android.hardware.media.c2@1.1-vaapi-service
cp -f $P/lib64/*.so /vendor/lib64/
chmod 644 /vendor/lib64/*.so
cp -f $P/etc/init/*.rc /vendor/etc/init/
cp -f $P/etc/vintf/manifest/*.xml /vendor/etc/vintf/manifest/
cp -f $P/etc/seccomp_policy/* /vendor/etc/seccomp_policy/
' || { log "注入失败"; return 1; }

    ### media_codecs.xml 登记（必须，否则 Codec2InfoBuilder 报 not found in xml）
    dex '
set -e
BK=/data/local/tmp/hwenc-backup
mkdir -p $BK
[ -f /vendor/etc/media_codecs.xml ] && [ ! -f $BK/media_codecs.xml.orig ] && cp -f /vendor/etc/media_codecs.xml $BK/media_codecs.xml.orig
if ! grep -q "c2.hardware.encoder.h264" /vendor/etc/media_codecs.xml; then
  cat > /data/local/tmp/hwenc-frag.xml <<"FRAG"
        <MediaCodec name="c2.hardware.encoder.h264" type="video/avc">
            <Limit name="size" min="32x32" max="1920x1088" />
            <Limit name="alignment" value="2x2" />
            <Limit name="block-size" value="16x16" />
            <Limit name="blocks-per-second" range="1-489600" />
            <Limit name="bitrate" range="1-40000000" />
            <Feature name="intra-refresh" />
        </MediaCodec>
FRAG
  sed -i "/<Encoders>/r /data/local/tmp/hwenc-frag.xml" /vendor/etc/media_codecs.xml
else
  ### 已存在条目时纠正 size 声明：旧写法 max="4096x4096" 会让 MediaCodecList 误以为
  ### 能编 1080x2340，结果选中硬件编码器后在 daemon 侧被拒（vaCreateContext failed），
  ### 整条编码失败且不会退回软件 —— 实测踩过。声明值必须与真实能力一致。
  sed -i "s|name=\"size\" min=\"32x32\" max=\"[0-9]*x[0-9]*\"|name=\"size\" min=\"32x32\" max=\"1920x1088\"|" /vendor/etc/media_codecs.xml
fi
' || { log "media_codecs.xml 登记失败"; return 1; }

    ### 3.9.9：可选硬件解码。注入的 C2 VAAPI 服务本身已经实现了
    ### c2.hardware.decoder.{h264,hevc,vp9}（二进制内可查），缺的只是 XML 声明；
    ### 默认不写，只有 `decode on` 时才登记。声明上限取 1920x1088（与编码侧一致，
    ### 大于此尺寸不会被选中，自动回落软件解码，避免误选导致黑屏）。
    if [ "$(cat "$DECODE_CONF" 2>/dev/null | tr -d '\r\n')" = "on" ]; then
        dex '
set -e
if ! grep -q "c2.hardware.decoder.h264" /vendor/etc/media_codecs.xml; then
  cat > /data/local/tmp/hwdec-frag.xml <<"FRAG"
        <MediaCodec name="c2.hardware.decoder.h264" type="video/avc">
            <Limit name="size" min="32x32" max="1920x1088" />
            <Limit name="alignment" value="2x2" />
            <Limit name="block-size" value="16x16" />
            <Feature name="adaptive-playback" />
        </MediaCodec>
        <MediaCodec name="c2.hardware.decoder.hevc" type="video/hevc">
            <Limit name="size" min="32x32" max="1920x1088" />
            <Limit name="alignment" value="2x2" />
            <Limit name="block-size" value="16x16" />
            <Feature name="adaptive-playback" />
        </MediaCodec>
        <MediaCodec name="c2.hardware.decoder.vp9" type="video/x-vnd.on2.vp9">
            <Limit name="size" min="32x32" max="1920x1088" />
            <Limit name="alignment" value="2x2" />
            <Limit name="block-size" value="16x16" />
            <Feature name="adaptive-playback" />
        </MediaCodec>
FRAG
  sed -i "/<Decoders>/r /data/local/tmp/hwdec-frag.xml" /vendor/etc/media_codecs.xml
fi
' || { log "硬件解码器登记失败（保持编码链路不变）"; }
        log "已登记 3 个硬件解码器（h264/hevc/vp9）"
    fi

    ### dma_heap 权限：实测在 libion 未被替换的前提下，0444 也能正常分配（c2.android
    ### 多帧编码通过）。这里保留放宽为 666，仅为兼容部分内核/驱动组合，
    ### 不影响宿主，属容器内权限。容器重启后会恢复 0444，由 repair 重新放开。
    dex 'chmod 666 /dev/dma_heap/system 2>/dev/null; ls -l /dev/dma_heap/system' | while read -r l; do log "  dma_heap: $l"; done

    ### hwservicemanager 重读 VINTF（否则注册被拒 "must be in VINTF manifest"）
    dex 'setprop ctl.restart hwservicemanager' >/dev/null
    sleep 4
    return 0
}

### ---------------------------------------------------------------------------
### 宿主 daemon 启动（普通用户，不引入 高权限常驻）
### ---------------------------------------------------------------------------
daemon_start() {
    pkill -x daemon >/dev/null 2>&1
    sleep 1
    mkdir -p "$SHARED"
    chown "$RUN_USER" "$SHARED" >/dev/null 2>&1
    chmod 755 "$SHARED"
    rm -f "$SHARED/socket"

    ### 硬解开启时换用带 HAVE_HWDEC 的 daemon；缺失该文件则保持旧 daemon 并打日志，
    ### 不会因为一个可选组件没构建好就把编码链路弄坏。
    _run_daemon="$DAEMON_BIN"
    if [ "$(cat "$DECODE_CONF" 2>/dev/null | tr -d '\r\n')" = "on" ]; then
        if [ -x "$DAEMON_HWDEC" ]; then
            _run_daemon="$DAEMON_HWDEC"
            log "硬件解码：已启用，使用 daemon-hwdec"
        else
            log "硬件解码：标记已开但缺少 daemon-hwdec，本次仍用只编码 daemon"
        fi
    fi
    cd "$APP_DIR/hwenc/bin" || return 1
    ### 3.9.9：显式指定 libva 驱动。实测 2026-11-09 daemon 继承了宿主环境里的
    ### LIBVA_DRIVER_NAME=nvidia，日志报「vaInitialize failed / No NVIDIA VA-API decode」。
    ### 编码走 legacy 后端不受影响，但解码初始化会白跑一次；这里按实际内核模块纠正。
    local _drv=""
    if [ -d /sys/module/amdgpu ] || [ -d /sys/module/radeon ]; then
        _drv=radeonsi
    elif [ -d /sys/module/i915 ] || [ -d /sys/module/xe ]; then
        _drv=iHD
    fi
    ### setsid -f 彻底脱离会话，否则 SSH/回调结束时被回收（实测）
    ### 上游 v0.2.0 release 明写：Intel 上默认 legacy 编码后端会产生畸形 P 帧，
    ### 必须走 REDROID_FORGE_ENCODE_BACKEND=ffmpeg；AMD 用 ffmpeg 后端反而会 GPU hang。
    ### ffmpeg 后端与硬解共用一个 HAVE_HWDEC 开关，所以只在 Intel + decode on 时启用。
    _extra_env=""
    if [ "$_run_daemon" = "$DAEMON_HWDEC" ] && { [ -d /sys/module/i915 ] || [ -d /sys/module/xe ]; }; then
        _extra_env="REDROID_FORGE_ENCODE_BACKEND=ffmpeg"
        log "检测到 Intel 显卡：同时启用 ffmpeg 编码后端（避开 legacy 的 P 帧畸形码流）"
    fi
    setsid -f runuser -u "$RUN_USER" -- env \
        REDROID_FORGE_VAAPI_SOCKET="$SHARED/socket" \
        ${_drv:+LIBVA_DRIVER_NAME=$_drv} \
        $_extra_env \
        "$_run_daemon" >> "$VAR_DIR/hwenc/daemon.log" 2>&1 < /dev/null
    sleep 5

    pgrep -x daemon >/dev/null || { log "daemon 启动失败"; return 1; }
    [ -S "$SHARED/socket" ] || { log "daemon socket 未创建"; return 1; }
    log "daemon 已启动（用户 $(ps -o user= -p "$(pgrep -x daemon | head -1)" | tr -d ' ')）"
    return 0
}

### ---------------------------------------------------------------------------
### HIDL 服务启动
### ---------------------------------------------------------------------------
service_start() {
    dex '
for p in $(ps -A -o PID,NAME 2>/dev/null | awk "\$2 ~ /vaapi/ {print \$1}"); do kill -9 $p 2>/dev/null; done
rm -rf /dev/vaapi-helper
ln -sfn /data/vaapi-helper /dev/vaapi-helper
sleep 1
export LD_LIBRARY_PATH=/vendor/lib64:/system/lib64
setsid /vendor/bin/hw/android.hardware.media.c2@1.1-vaapi-service >/data/local/tmp/hwenc-svc.log 2>&1 </dev/null &
sleep 5
' 
    dex 'lshal 2>/dev/null | grep -c "media.c2@1.1::IComponentStore/default"'
}

### ---------------------------------------------------------------------------
### 属性与验证
### ---------------------------------------------------------------------------
apply_props() {
    ### 时序同 do_resync：restart 后 8 秒补设并立即 dumpsys 触发列表构建，
    ### 抢在系统约 19 秒的 ccodec 重置之前把列表按 4 建好。
    dex '
setprop debug.stagefright.ccodec 4
setprop debug.stagefright.c2software 0
setprop ctl.restart media
' >/dev/null
    sleep 8
    dex '
setprop debug.stagefright.ccodec 4
setprop debug.stagefright.c2software 0
dumpsys media.player >/dev/null 2>&1
' >/dev/null
    sleep 3
}

verify() {
    local hw cnt try
    ### 3.9.9：改为最多重试 4 次。实测（2026-11-09 18:27）在手机分辨率下启用时，
    ### media 重启后列表构建与组件注册有先后差，单次校验会误判成失败并回退，
    ### 结果就是「手机分辨率下永远启用不了」。这里给足重试窗口。
    for try in 1 2 3 4; do
        ### dumpsys 是否卡（卡 = 媒体栈已坏，必须立刻回退）
        cnt=$(dex 'dumpsys media.player 2>&1 | grep -c "DUMP TIMEOUT"')
        if [ "${cnt:-0}" != "0" ]; then
            log "验证失败：dumpsys media.player 超时（Codec2 枚举卡死）"
            return 1
        fi
        hw=$(dex 'dumpsys media.player 2>/dev/null | grep -c "c2.hardware.encoder.h264"')
        if [ "${hw:-0}" -ge 1 ]; then
            log "验证通过：列表含硬件编码器（关键字命中 $hw，第 $try 次）"
            return 0
        fi
        if [ "$try" -lt 4 ]; then
            log "第 $try 次未见硬件编码器，3 秒后重试"
            sleep 3
            dex 'dumpsys media.player >/dev/null 2>&1' >/dev/null
        fi
    done
    log "验证失败：列表里没有 c2.hardware.encoder.h264（已重试 4 次）"
    return 1
}

### ---------------------------------------------------------------------------
### 禁用 / 回退
### ---------------------------------------------------------------------------
do_disable() {
    log "开始禁用硬件编码，回退到 OMX 软件编码"

    ### 1) 属性回到 1（Codec2 软件编码，容器原生运行值；实测稳定、dumpsys 正常、
    ###    c2.android 多帧编码通过）。0=OMX 也可用，这里取 1 更贴近原生状态。
    dex '
setprop debug.stagefright.ccodec 1
setprop debug.stagefright.c2software 1
' >/dev/null
    sleep 1

    ### 2) 停 HIDL 服务与 daemon
    dex '
for p in $(ps -A -o PID,NAME 2>/dev/null | awk "\$2 ~ /vaapi/ {print \$1}"); do kill -9 $p 2>/dev/null; done
' >/dev/null
    pkill -x daemon >/dev/null 2>&1

    ### 3) 撤注入（只删我们加的东西）
    dex '
BK=/data/local/tmp/hwenc-backup
[ -f $BK/media_codecs.xml.orig ] && cp -f $BK/media_codecs.xml.orig /vendor/etc/media_codecs.xml
rm -f /vendor/bin/hw/android.hardware.media.c2@1.1-vaapi-service
rm -f /vendor/lib64/libavservices_minijail.so /vendor/lib64/libcodec2.so \
      /vendor/lib64/libcodec2_hidl@1.0.so /vendor/lib64/libcodec2_hidl@1.1.so \
      /vendor/lib64/libcodec2_soft_common.so /vendor/lib64/libcodec2_vndk.so \
      /vendor/lib64/libsfplugin_ccodec_utils.so /vendor/lib64/libstagefright_bufferpool@2.0.1.so \
      /vendor/lib64/libion.so
rm -f /vendor/etc/init/android.hardware.media.c2@1.1-vaapi-service.rc
rm -f /vendor/etc/vintf/manifest/manifest_media_c2_vaapi.xml
rm -f /vendor/etc/seccomp_policy/android.hardware.media.c2-vaapi-seccomp_policy
rm -rf /dev/vaapi-helper /data/vaapi-helper
rm -rf /data/local/tmp/hwenc-pkg /data/local/tmp/hwenc-frag.xml /data/local/tmp/hwdec-frag.xml /data/local/tmp/hwenc-svc.log
' >/dev/null
    rm -rf "$SHARED"

    ### 4) 重启媒体栈回默认
    dex 'setprop ctl.restart media' >/dev/null
    sleep 10
    dex 'for p in $(ps -A -o PID,NAME | awk "\$2 ~ /swcodec/ {print \$1}"); do kill -9 $p 2>/dev/null; done' >/dev/null
    sleep 6

    echo "disabled" > "$STATUS"
    log "已禁用：ccodec=1（软件编码），硬件组件已撤回、daemon 已停"
    return 0
}

### ---------------------------------------------------------------------------
### 启用
### ---------------------------------------------------------------------------
do_enable() {
    log "===== 启用硬件视频编码 ====="
    log "分辨率配置：$(res_summary)"

    if ! detect; then
        log "前置检测未通过：$_WHY"
        echo "unsupported" > "$STATUS"
        echo "$_WHY"
        return 1
    fi
    log "检测通过：$_ARCH / $_GPU / ${_ENC} 个编码入口"
    [ -n "${_WARN_RADEON:-}" ] && log "注意：$_WARN_RADEON；手机/平板分辨率会退回软件编码"

    ### 记录原始状态，便于 disable 精准还原
    mkdir -p "$BK"
    dex 'cp -f /vendor/etc/media_codecs.xml /data/local/tmp/hwenc-backup/media_codecs.xml.orig 2>/dev/null' >/dev/null

    inject || { log "注入失败，回退"; do_disable; return 1; }

    daemon_start || { log "daemon 失败，回退"; do_disable; return 1; }

    local inst
    inst=$(service_start)
    if [ "${inst:-0}" -lt 1 ]; then
        log "HIDL 服务未注册，回退"
        do_disable
        return 1
    fi
    log "HIDL 服务已注册 default 实例"

    ### 先验证服务端能列出组件，再动属性（顺序关键）
    local traits
    traits=$(dex 'logcat -d 2>/dev/null | grep -c "listComponents: encTraits name=c2.hardware.encoder.h264"')
    log "服务端已列出编码组件（日志命中 ${traits:-0}）"

    apply_props

    if ! verify; then
        log "验证未通过，自动回退"
        do_disable
        return 1
    fi

    echo "enabled" > "$STATUS"
    log "启用成功：≤1920x1088 走硬件编码，更高分辨率退回软件编码"
    ### 立刻按当前实际分辨率校准一次（避免启用时正处在手机/平板分辨率而错选硬件编码器）
    do_resync
    log "提示：容器重启后需 repair（boot_guard 会自动执行）；分辨率切换后需 resync"
    return 0
}

### ---------------------------------------------------------------------------
### 修复（容器重建/重启后恢复注入与属性）
### ---------------------------------------------------------------------------
do_repair() {
    [ "$(cat "$STATUS" 2>/dev/null)" = "enabled" ] || { log "未启用，无需修复"; return 0; }
    log "检测到已启用状态，检查注入完整性"

    ### 3.9.9：ccodec 的期望值取决于当前分辨率（超限时本来就该是 0）。
    ### 早期实现固定期望 4，手机分辨率下每 300 秒都会被判「缺失」并重跑 enable，
    ### 表现为 media 反复重启、投屏卡顿。
    local need=0 cur w h want
    cur=$(current_wh)
    w=${cur%x*}; h=${cur#*x}
    if [ "${w:-0}" -le 1920 ] && [ "${h:-9999}" -le 1088 ]; then want=4; else want=0; fi

    [ "$(dex 'ls /vendor/bin/hw/android.hardware.media.c2@1.1-vaapi-service 2>/dev/null | wc -l')" -lt 1 ] && need=1
    [ "$(dex 'grep -c "c2.hardware.encoder.h264" /vendor/etc/media_codecs.xml 2>/dev/null')" -lt 1 ] && need=1
    pgrep -x daemon >/dev/null || need=1
    [ "$(dex 'lshal 2>/dev/null | grep -c "media.c2@1.1::IComponentStore/default"')" -lt 1 ] && need=1
    [ "$(dex 'getprop debug.stagefright.ccodec')" != "$want" ] && need=1

    if [ "$need" = "0" ]; then
        log "注入完整（当前 ${cur:-未知}，ccodec 期望 $want），无需修复"
        return 0
    fi

    log "注入缺失（当前 ${cur:-未知}，ccodec 期望 $want），重新应用"
    do_enable
    do_resync
    return 0
}

### ---------------------------------------------------------------------------
### 按当前分辨率同步 ccodec（关键）
### 背景：组件的 encTraits 自己声明了较大尺寸能力，media_codecs.xml 的 <Limit> 管不住
### MediaCodecList 的选择 —— 超限分辨率（手机 1080x2340 / 平板 1200x2000）仍会选中
### c2.hardware.encoder.h264，然后在 daemon 侧被 vaCreateContext 拒绝，整条编码失败
### 且不会自动退回软件编码（MediaCodec 不做运行时 fallback），投屏直接黑。
### 结论：只能按当前实际分辨率切换 ccodec —— ≤1920x1088 用 4（Codec2 硬件优先），
### 超限用 0（OMX 软件），每次切换后重启 media 使其生效。
### ---------------------------------------------------------------------------
current_wh() {
    local raw ov
    raw=$(dex 'wm size 2>/dev/null')
    ov=$(echo "$raw" | grep -oE 'Override size: [0-9]+x[0-9]+' | grep -oE '[0-9]+x[0-9]+' | tail -1)
    [ -n "$ov" ] && { echo "$ov"; return; }
    echo "$raw" | grep -oE '[0-9]+x[0-9]+' | tail -1
}

### 3.9.9：等媒体栈真正就绪再返回。实测（2026-11-09 分辨率矩阵）切换后立刻录制
### 偶发失败：ccodec 已回到 0/1，但 mediaserver 尚未完成枚举，此时编码会报
### work failed to complete:14。用 dumpsys 行数判断就绪（正常约 587~1240 行，
### 卡住时只有个位数）。
wait_media_ready() {
    local i l
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        l=$(dex 'dumpsys media.player 2>&1 | wc -l' 2>/dev/null | tr -d ' \r\n')
        [ "${l:-0}" -gt 100 ] && return 0
        sleep 2
    done
    log "警告：媒体栈在 40 秒内未就绪（dumpsys 行数 ${l:-0}）"
    return 1
}

do_resync() {
    [ "$(cat "$STATUS" 2>/dev/null)" = "enabled" ] || return 0

    local cur w h target now
    cur=$(current_wh)
    [ -z "$cur" ] && { log "resync：取不到当前分辨率，跳过"; return 0; }
    w=${cur%x*}; h=${cur#*x}

    if [ "${w:-0}" -le 1920 ] && [ "${h:-9999}" -le 1088 ]; then
        target=4
    else
        target=0
    fi

    now=$(dex 'getprop debug.stagefright.ccodec')
    if [ "$now" = "$target" ]; then
        log "resync：当前 ${cur}，ccodec 已是 $target，无需变更"
        return 0
    fi

    log "resync：分辨率 ${cur} → ccodec=$target（4=硬件优先 0=OMX 软件）"
    dex "setprop debug.stagefright.ccodec $target
[ \"$target\" = \"4\" ] && setprop debug.stagefright.c2software 0
setprop ctl.restart media" >/dev/null

    ### 关键时序（实测）：media 重启后约 19 秒，系统会把 ccodec 重置为 1，
    ### 而 MediaCodecList 只在 media 启动后的早期窗口内构建一次（之后固定）。
    ### 所以必须在 8 秒左右补设 4 并**立即 dumpsys 触发列表构建**，抢在重置之前。
    ### 列表一旦按 4 构建好，之后属性再被重置也不影响已缓存的列表。
    if [ "$target" = "4" ]; then
        sleep 8
        dex "setprop debug.stagefright.ccodec 4
setprop debug.stagefright.c2software 0
dumpsys media.player >/dev/null 2>&1" >/dev/null
        sleep 3
    else
        sleep 10
        wait_media_ready
    fi

    log "resync 完成：ccodec=$(dex 'getprop debug.stagefright.ccodec')，硬件编码器 $(dex 'dumpsys media.player 2>/dev/null | grep -c "c2.hardware.encoder.h264"') 处"
    return 0
}

do_status() {
    echo "===== androidemu 硬件视频编码状态 ====="
    echo "状态文件     : $(cat "$STATUS" 2>/dev/null || echo '未启用')"
    echo "架构         : $(uname -m)"
    echo "分辨率配置   : $(res_summary)"
    if detect; then
        echo "能力检测     : 通过"
        echo "GPU          : $_GPU"
        echo "编码入口数   : $_ENC"
        [ -n "${_WARN_RADEON:-}" ] && echo "限制         : $_WARN_RADEON"
    else
        echo "能力检测     : 未通过 —— $_WHY"
    fi
    if docker inspect "$CT" >/dev/null 2>&1; then
        echo "容器 ccodec  : $(dex 'getprop debug.stagefright.ccodec')   (0=OMX软件 4=Codec2)"
        echo "dma_heap     : $(dex 'ls -l /dev/dma_heap/system 2>/dev/null | awk "{print \$1}"')"
        echo "HIDL default : $(dex 'lshal 2>/dev/null | grep -c "media.c2@1.1::IComponentStore/default"') 个"
        echo "硬件编码器   : $(dex 'dumpsys media.player 2>/dev/null | grep -c "c2.hardware.encoder.h264"') 处"
        echo "硬件解码器   : $(dex 'dumpsys media.player 2>/dev/null | grep -c "c2.hardware.decoder"') 处"
    fi
    echo "硬件解码开关 : $(cat "$DECODE_CONF" 2>/dev/null || echo 'off（默认）')"
    echo "hwdec daemon : $([ -x "$DAEMON_HWDEC" ] && echo 已安装 || echo '未安装（先在 CI 构建）')"
    echo "daemon 进程  : $(pgrep -x daemon >/dev/null && echo 运行中 || echo 未运行)"
    echo "daemon 用户  : $(pgrep -x daemon >/dev/null && ps -o user= -p "$(pgrep -x daemon | head -1)" | tr -d ' ' || echo -)"
    echo "日志         : $LOG"
}

### ---------------------------------------------------------------------------
### 硬件解码开关（3.9.9，默认关闭）
### 必须成对待办：①换 daemon ②登记/撤销 Decoders 声明 ③重启媒体栈。
### 走 disable→enable 是为了让 media_codecs.xml 回到 orig 再按新标记重建，
### 避免只删本脚本加的条目时误伤镜像原有内容。
### ---------------------------------------------------------------------------
do_decode() {
    local act="${1:-status}"
    case "$act" in
        on)
            if [ ! -x "$DAEMON_HWDEC" ]; then
                echo "硬件解码不可用：缺少 $DAEMON_HWDEC（需先用 CI 构建该二进制）"
                return 1
            fi
            if ! detect; then
                echo "宿主 VA-API 检测未通过（$_WHY），硬解通常也不可用；开关未改动"
                return 1
            fi
            echo on > "$DECODE_CONF" || return 1
            log "硬件解码开关：on（h264 / hevc / vp9）"
            ;;
        off)
            echo off > "$DECODE_CONF" || return 1
            log "硬件解码开关：off（回到纯硬编 + 软解）"
            ;;
        status|*)
            echo "硬件解码：$(cat "$DECODE_CONF" 2>/dev/null || echo off)   daemon-hwdec：$([ -x "$DAEMON_HWDEC" ] && echo 已安装 || echo 未安装)"
            return 0
            ;;
    esac
    if [ "$(cat "$STATUS" 2>/dev/null)" = "enabled" ]; then
        do_disable
        do_enable || { log "按新开关重新启用失败，已回退到软件编解码"; return 1; }
        echo "已生效。用 $0 status 查看硬件解码器数量"
    else
        echo "已记录，当前硬件编码未启用；下次 enable 时生效"
    fi
}

case "${1:-status}" in
    status)  do_status ;;
    decode)  do_decode "${2:-status}" ;;
    enable)  do_enable ;;
    disable) do_disable ;;
    repair)  do_repair ;;
    resync)  do_resync ;;
    check)   if detect; then echo "支持：$_ARCH / $_GPU"; else echo "不支持：$_WHY"; fi ;;
    *)       echo "用法：$0 {status|enable|disable|repair|resync|check}" ;;
esac
