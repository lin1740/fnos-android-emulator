#!/bin/bash
### 补齐系统目录，避免飞牛回调/看护 PATH 缺失时找不到系统命令。
### 3.9.9-r12 起硬编 daemon 用 setpriv（exec 语义）降权，不再依赖 /usr/sbin/runuser；
### 本段 PATH 补齐保留给其余脚本命令使用。
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
### 3.9.9-r13：硬件解码**默认开启**。daemon-hwdec 是同一份源码加 -DHAVE_HWDEC
### 编出来的，与只编码的 daemon 并存。运行时按宿主 VA-API 的真实能力决定：
### 有解码入口就换 daemon-hwdec 并登记 Decoders；缺二进制、vainfo 不可用或
### 没有解码入口时自动退回「只编码 daemon + 软件解码」，编码链路完全不受影响。
### 用户可执行 hwenc_ctl.sh decode off 显式关闭（写 hwenc.decode=off）。
DAEMON_HWDEC="$APP_DIR/hwenc/bin/daemon-hwdec"
DECODE_CONF="$VAR_DIR/hwenc.decode"
LOG="$VAR_DIR/hwenc.log"
STATUS="$VAR_DIR/hwenc.status"
### 3.9.9-r12：检测失败时把「可直接执行的修复办法」落盘，供状态页/排障读取。
HINT="$VAR_DIR/hwenc.hint"
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

### 3.9.9-r12：按实际运行的二进制名查 daemon（daemon / daemon-hwdec）。
### 旧代码写死 pgrep -x daemon，开硬解后进程名是 daemon-hwdec，会漏判并误报
### 「daemon 启动失败」→ 整个 enable 被回退，硬解链路起不来。
daemon_pids() {
    pgrep -x daemon 2>/dev/null
    pgrep -x daemon-hwdec 2>/dev/null
}

### 3.9.9-r13：硬解默认开；只有显式写入 off 才关闭。
decode_enabled() {
    [ "$(cat "$DECODE_CONF" 2>/dev/null | tr -d '\r\n')" = "off" ] && return 1
    return 0
}

### 从 vainfo 的**实际输出**识别 libva 驱动，不按 /sys/module 猜厂商。
### 返回 iHD / radeonsi / radeonsi-legacy / nvidia / unknown
va_driver_name() {
    local _v
    _v=$(vainfo 2>/dev/null | grep -m1 -i 'Driver version' | tr 'A-Z' 'a-z')
    case "$_v" in
        *nvidia*)                    echo nvidia; return 0 ;;
        *intel*|*ihd*|*i965*)        echo iHD; return 0 ;;
        *radeonsi*|*gallium*|*mesa*)
            ### 读 card* 实际绑定的内核驱动（radeon / amdgpu），不能只看模块是否加载：
            ### 实测 Kaveri 机器上 amdgpu 模块也在，但 device/driver 指向 radeon。
            local _k="" _p
            for _p in /sys/class/drm/card[0-9]*/device/driver; do
                [ -e "$_p" ] || continue
                _k=$(readlink -f "$_p" 2>/dev/null | awk -F/ '{print $NF}')
                break
            done
            case "$_k" in
                radeon) echo radeonsi-legacy ;;
                *)      echo radeonsi ;;
            esac
            return 0 ;;
        *) echo unknown; return 0 ;;
    esac
}

### 编码/解码尺寸上限按驱动分档，不再把一台 Kaveri(VCE 2.0) 的 1920x1088
### 套到所有显卡。可用 $VAR_DIR/hwenc.maxsize（如 3840x2160）显式覆盖。
### 未知驱动与 radeon 传统驱动保守取 1920x1088（有实测），现代 iHD/amdgpu
### 取 3840x2160；MediaCodecList 选不中时 verify()/do_resync() 仍会自动回退软编。
hwenc_max_size() {
    local _ov
    _ov=$(cat "$VAR_DIR/hwenc.maxsize" 2>/dev/null | tr -d '\r\n')
    case "$_ov" in [0-9]*x[0-9]*) echo "$_ov"; return 0 ;; esac
    case "$(va_driver_name)" in
        radeonsi-legacy|unknown) echo "1920x1088" ;;
        *)                      echo "3840x2160" ;;
    esac
}

### 解码能力：NVIDIA 的 nvidia-vaapi-driver 通常只报 VAEntrypointVLD(NVDEC)，
### 没有 EncSlice；硬解不该被「硬编入口」挡住。
detect_decode() {
    _WHY=""
    [ -x "$DAEMON_HWDEC" ] || { _WHY="缺少 daemon-hwdec 二进制"; return 1; }
    command -v vainfo >/dev/null 2>&1 || { _WHY="宿主缺少 vainfo"; return 1; }
    local _va
    _va=$(vainfo 2>/dev/null) || { _WHY="包用户无法运行 vainfo（检查 video/render 组）"; return 1; }
    echo "$_va" | grep -qE 'VAEntrypoint(VLD|EncSlice|EncPicture|EncSliceLP)' \
        || { _WHY="VA-API 未报告任何解码入口"; return 1; }
    return 0
}

### 本次 enable 是否真的启用硬解；能力不足只降级硬解，不影响硬编。
decode_capable() {
    decode_enabled || { log "硬件解码：用户已关闭"; return 1; }
    [ -x "$DAEMON_HWDEC" ] || { log "硬件解码默认开启，但缺少 daemon-hwdec → 本次回退软解"; return 1; }
    detect_decode || { log "硬件解码默认开启，但 $_WHY → 本次回退软解"; return 1; }
    return 0
}

### ---------------------------------------------------------------------------
### 能力检测：输出原因，返回 0=可用 1=不可用
### ---------------------------------------------------------------------------
detect() {
    _ARCH=$(uname -m 2>/dev/null)
    _WHY=""
    _HINT=""

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
        ### 3.9.9-r12：最常见的原因是包用户不在 video/render 组，打不开
        ### /dev/dri/card0(root:video 660) 与 renderD128(root:render 660)。
        ### 飞牛只在「创建应用用户」时应用 config/privilege 的 join-groups，
        ### 已安装的应用升级不会自动补组 —— 给出可直接执行的修复命令，
        ### 否则用户只会看到一个 unsupported，不知道该干什么。
        if [ -d /dev/dri ] && ! id -nG "$RUN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx 'render'; then
            _WHY="vainfo 执行失败：运行用户 $RUN_USER 不在 render/video 组，打不开 /dev/dri/renderD*（GPU 设备权限未授予）"
            _HINT="以 root 执行：gpasswd -a $RUN_USER video && gpasswd -a $RUN_USER render ；然后重启 NAS（或彻底重启本应用的全部常驻进程），让所有进程重新读取用户组，再执行 $0 enable。新装应用会自动获得这两个组；已安装的应用仅升级程序包不会自动补组。"
        fi
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
    if [ "$(va_driver_name)" = "radeonsi-legacy" ]; then
        _WARN_RADEON="radeon 传统驱动：尺寸上限按 1920x1088 保守处理；现代 AMD 卡可切 amdgpu，或写 $VAR_DIR/hwenc.maxsize 覆盖"
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
    local _max
    _max=$(hwenc_max_size)
    log "编解码尺寸上限：$_max（驱动 $(va_driver_name)；可用 $VAR_DIR/hwenc.maxsize 覆盖）"
    dex "echo '$_max' > /data/local/tmp/hwenc-maxsize" >/dev/null 2>&1
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
M=$(cat /data/local/tmp/hwenc-maxsize)
BK=/data/local/tmp/hwenc-backup
mkdir -p $BK
[ -f /vendor/etc/media_codecs.xml ] && [ ! -f $BK/media_codecs.xml.orig ] && cp -f /vendor/etc/media_codecs.xml $BK/media_codecs.xml.orig
if ! grep -q "c2.hardware.encoder.h264" /vendor/etc/media_codecs.xml; then
  cat > /data/local/tmp/hwenc-frag.xml <<"FRAG"
        <MediaCodec name="c2.hardware.encoder.h264" type="video/avc">
            <Limit name="size" min="32x32" max="__AE_MAX__" />
            <Limit name="alignment" value="2x2" />
            <Limit name="block-size" value="16x16" />
            <Limit name="blocks-per-second" range="1-489600" />
            <Limit name="bitrate" range="1-40000000" />
            <Feature name="intra-refresh" />
        </MediaCodec>
FRAG
  sed -i "s|__AE_MAX__|$M|g" /data/local/tmp/hwenc-frag.xml
  sed -i "/<Encoders>/r /data/local/tmp/hwenc-frag.xml" /vendor/etc/media_codecs.xml
else
  ### 已存在条目时按当前驱动上限纠正 size 声明（旧写法 4096x4096 会让
  ### MediaCodecList 误选硬编后被 daemon 拒绝且不回退，实测踩过）。
  sed -i "s|name=\"size\" min=\"32x32\" max=\"[0-9]*x[0-9]*\"|name=\"size\" min=\"32x32\" max=\"$M\"|" /vendor/etc/media_codecs.xml
fi
' || { log "media_codecs.xml 登记失败"; return 1; }

    ### 3.9.9-r13：硬解默认开启。只有本次能力探测通过（有解码入口 + daemon-hwdec
    ### 可用）才登记 Decoders；否则自动只走软件解码，编码链路完全不受影响。
    if [ "${_DECODE_ON:-0}" = "1" ]; then
        local _ndec
        ### 显式 -u 0：dex() 用容器默认用户，部分 redroid 镜像下写 /data/local/tmp
        ### 与 /vendor/etc 会静默失败；实测显式 -u 0 才能稳定登记。
        _ndec=$(docker exec -u 0 "$CT" sh -c '
set -e
M=$(cat /data/local/tmp/hwenc-maxsize)
### redroid 的 media_codecs.xml 原文件只有 <Encoders>，解码器在 Include 里，
### 没有 <Decoders> 段 —— 旧代码直接 sed "/<Decoders>/r" 什么都不会插入，
### 却无条件报「已登记 3 个」。必须先建段再插入。
if ! grep -q "<Decoders>" /vendor/etc/media_codecs.xml; then
  ### 用 printf 生成段文件再 r 插入：Android toybox sed 的替换串里 \n 不可靠。
  printf "    <Decoders>\n    </Decoders>\n" > /data/local/tmp/hwdec-section.xml
  sed -i "/<MediaCodecs>/r /data/local/tmp/hwdec-section.xml" /vendor/etc/media_codecs.xml
fi
if ! grep -q "c2.hardware.decoder.h264" /vendor/etc/media_codecs.xml; then
  cat > /data/local/tmp/hwdec-frag.xml <<"FRAG"
        <MediaCodec name="c2.hardware.decoder.h264" type="video/avc">
            <Limit name="size" min="32x32" max="__AE_MAX__" />
            <Limit name="alignment" value="2x2" />
            <Limit name="block-size" value="16x16" />
            <Feature name="adaptive-playback" />
        </MediaCodec>
        <MediaCodec name="c2.hardware.decoder.hevc" type="video/hevc">
            <Limit name="size" min="32x32" max="__AE_MAX__" />
            <Limit name="alignment" value="2x2" />
            <Limit name="block-size" value="16x16" />
            <Feature name="adaptive-playback" />
        </MediaCodec>
        <MediaCodec name="c2.hardware.decoder.vp9" type="video/x-vnd.on2.vp9">
            <Limit name="size" min="32x32" max="__AE_MAX__" />
            <Limit name="alignment" value="2x2" />
            <Limit name="block-size" value="16x16" />
            <Feature name="adaptive-playback" />
        </MediaCodec>
FRAG
  sed -i "s|__AE_MAX__|$M|g" /data/local/tmp/hwdec-frag.xml
  sed -i "/<Decoders>/r /data/local/tmp/hwdec-frag.xml" /vendor/etc/media_codecs.xml
fi
grep -c "c2.hardware.decoder" /vendor/etc/media_codecs.xml
' 2>/dev/null | tr -d '\r\n')
        if [ "${_ndec:-0}" -ge 3 ]; then
            log "已登记 $_ndec 个硬件解码器（h264/hevc/vp9）"
        else
            log "硬件解码器登记异常（实际 ${_ndec:-0} 个），播放由系统回落软解；编码链路不受影响"
        fi
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
    pkill -x daemon-hwdec >/dev/null 2>&1
    sleep 1
    ### 3.9.9-r12：$SHARED 位于容器 /data 的宿主挂载点，该目录常由容器 uid0 创建，
    ### 属主不是包用户（实测 lin3869:Administrators，权限 771），包用户在里面
    ### mkdir 会 Permission denied —— 之前只在 root 手跑 enable 才成功，应用自身的
    ### 包用户回调会卡在这里，硬编永远起不来。用一次性的 docker exec -u 0 在容器内
    ### 创建并改成包用户属主（不产生任何常驻 root 进程）。
    if ! mkdir -p "$SHARED" 2>/dev/null; then
        local _muid _mgid
        _muid=$(id -u "$RUN_USER" 2>/dev/null) || { log "无法解析运行用户 $RUN_USER"; return 1; }
        _mgid=$(id -g "$RUN_USER" 2>/dev/null) || _mgid="$_muid"
        dex "mkdir -p /data/vaapi-helper && chown $_muid:$_mgid /data/vaapi-helper && chmod 755 /data/vaapi-helper" >/dev/null 2>&1 \
            || { log "共享目录创建失败：$SHARED"; return 1; }
    fi
    chown "$RUN_USER" "$SHARED" 2>/dev/null || true
    chmod 755 "$SHARED" 2>/dev/null || true
    rm -f "$SHARED/socket" 2>/dev/null || true
    ### 日志文件若被早先的 root 操作留下 root 属主，包用户无法追加；
    ### 退回同目录的可写文件名，避免 daemon 启动被日志重定向打断。
    local _dlog="$VAR_DIR/hwenc/daemon.log"
    if [ ! -w "$_dlog" ]; then
        _dlog="$VAR_DIR/hwenc-daemon.log"
        : > "$_dlog" 2>/dev/null || _dlog=/dev/null
    fi

    ### 硬解开启时换用带 HAVE_HWDEC 的 daemon；缺失该文件则保持旧 daemon 并打日志，
    ### 不会因为一个可选组件没构建好就把编码链路弄坏。
    _run_daemon="$DAEMON_BIN"
    if [ "${_DECODE_ON:-0}" = "1" ] && [ -x "$DAEMON_HWDEC" ]; then
        _run_daemon="$DAEMON_HWDEC"
        log "硬件解码：已启用，使用 daemon-hwdec"
    else
        log "硬件解码：本次未启用，使用只编码 daemon（播放走软解）"
    fi
    cd "$APP_DIR/hwenc/bin" || return 1
    ### 3.9.9：显式指定 libva 驱动。实测 2026-11-09 daemon 继承了宿主环境里的
    ### LIBVA_DRIVER_NAME=nvidia，日志报「vaInitialize failed / No NVIDIA VA-API decode」。
    ### 编码走 legacy 后端不受影响，但解码初始化会白跑一次；这里按实际内核模块纠正。
    ### 3.9.9-r13：libva 驱动按 vainfo 实际输出识别（含 NVIDIA），不按内核模块猜；
    ### 识别不了就不设置，交给 libva 自选，避免写错驱动导致 vaInitialize 失败。
    local _drv=""
    case "$(va_driver_name)" in
        iHD)                      _drv=iHD ;;
        radeonsi|radeonsi-legacy) _drv=radeonsi ;;
        nvidia)                   _drv=nvidia ;;
        *)                        _drv="" ;;
    esac
    ### setsid -f 彻底脱离会话，否则 SSH/回调结束时被回收（实测）
    ### 上游 v0.2.0：Intel legacy 后端的 P 帧畸形，必须走 ffmpeg 后端；
    ### AMD RX 480 / Ryzen 5700G 的 legacy 后端实测正常，只有 Polaris/GFX8 老卡
    ### 用 ffmpeg 会 GPU hang —— 这是单台老卡的问题，不能推广到整个厂商。
    ### 因此 Intel 默认启用；其它厂商可写 $VAR_DIR/hwenc.backend=ffmpeg 显式启用。
    _extra_env=""
    local _backend
    _backend=$(cat "$VAR_DIR/hwenc.backend" 2>/dev/null | tr -d '\r\n')
    if [ "$_run_daemon" = "$DAEMON_HWDEC" ] && \
       { [ "$(va_driver_name)" = "iHD" ] || [ "$_backend" = "ffmpeg" ]; }; then
        _extra_env="REDROID_FORGE_ENCODE_BACKEND=ffmpeg"
        log "启用 ffmpeg 编码后端（Intel 默认 / 其它厂商由 hwenc.backend 显式指定）"
    fi
    ### 3.9.9-r12：绝不留下 root 常驻父进程。
    ### · 应用回调本身就是包用户 → 直接 exec，无需降权（在非 root 下调 setpriv
    ###   --init-groups 需要 setgroups() 权限，会直接失败，实测踩过）；
    ### · 以 root 手工执行时 → 用 setpriv(exec 语义) 降权，不用 runuser
    ###   （runuser 会 fork 并 wait，留下一个 root 父进程，宿主 ps 可见）。
    local _uid _gid _sp="" _c
    _uid=$(id -u "$RUN_USER" 2>/dev/null) || { log "无法解析运行用户 $RUN_USER"; return 1; }
    _gid=$(id -g "$RUN_USER" 2>/dev/null) || _gid="$_uid"
    local -a _launcher
    if [ "$(id -u)" = "$_uid" ]; then
        _launcher=(setsid -f env)
        log "当前已是 $RUN_USER，daemon 直接以该身份启动（不降权、不新增 root）"
    else
        for _c in /usr/bin/setpriv /bin/setpriv /usr/sbin/setpriv; do
            [ -x "$_c" ] && { _sp="$_c"; break; }
        done
        [ -n "$_sp" ] || { log "缺少 setpriv，无法以非 root 方式启动 daemon（拒绝回退到 root 父进程）"; return 1; }
        ### --init-groups 按 /etc/group 初始化附加组（video/render），否则补了组
        ### 但降权后的进程仍打不开 /dev/dri/renderD*。
        _launcher=(setsid -f "$_sp" --reuid "$_uid" --regid "$_gid" --init-groups env)
    fi
    "${_launcher[@]}" \
        REDROID_FORGE_VAAPI_SOCKET="$SHARED/socket" \
        ${_drv:+LIBVA_DRIVER_NAME=$_drv} \
        $_extra_env \
        "$_run_daemon" >> "$_dlog" 2>&1 < /dev/null
    sleep 5

    [ -n "$(daemon_pids | head -1)" ] || { log "daemon 启动失败"; return 1; }
    [ -S "$SHARED/socket" ] || { log "daemon socket 未创建"; return 1; }
    log "daemon 已启动（用户 $(ps -o user= -p "$(daemon_pids | head -1)" | tr -d ' ')）"
    return 0
}

### ---------------------------------------------------------------------------
### HIDL 服务启动
### ---------------------------------------------------------------------------
service_start() {
    ### 3.9.9-r12：C2 HAL 绝不能以 uid0 常驻（宿主 ps 会多一条 root）。
    ### 上游 rc 声明 user mediacodec(1046) / group camera(1006) mediadrm(1031)
    ### drmrpc(1026)，但 rc 是容器启动后才注入 /vendor/etc/init 的，Android init
    ### 不会动态重读 —— 实测 ctl.start 报 "Failed to set property"，服务卡在
    ### restarting。所以由宿主 docker exec 直接按同一套 uid/gid 启动。
    ### 注意：本函数的 stdout 只用于返回 lshal 实例数，所有日志必须走 stderr。
    dex '
for p in $(ps -A -o PID,NAME 2>/dev/null | awk "\$2 ~ /vaapi-service/ {print \$1}"); do kill -9 $p 2>/dev/null; done
rm -rf /dev/vaapi-helper
ln -sfn /data/vaapi-helper /dev/vaapi-helper
' >/dev/null 2>&1
    ### 日志文件可能由早先的 root 启动留下 root 属主，mediacodec 写不进去会立刻退出。
    dex 'rm -f /data/local/tmp/hwenc-svc.log; touch /data/local/tmp/hwenc-svc.log; chmod 666 /data/local/tmp/hwenc-svc.log' >/dev/null 2>&1
    ### --group-add 是 docker run 的选项，docker exec 不支持（传了会直接报 unknown flag，
    ### 之前把 stderr 吞掉导致服务根本没启动却查不到原因）。这里只指定 uid/gid，
    ### 需要访问的设备节点由 gpu_release.sh 放权为 666，mediacodec 可直接打开。
    local _dexerr
    _dexerr=$(docker exec -d -u 1046:1046 \
        "$CT" sh -c \
        'LD_LIBRARY_PATH=/vendor/lib64:/system/lib64 exec /vendor/bin/hw/android.hardware.media.c2@1.1-vaapi-service >/data/local/tmp/hwenc-svc.log 2>&1' 2>&1) || true
    [ -n "$_dexerr" ] && log "docker exec 启动 C2 返回：$_dexerr" >&2
    sleep 6
    local _uid
    _uid=$(dex 'ps -A -o USER,NAME 2>/dev/null | awk "\$2 ~ /vaapi-service/ {print \$1; exit}"' | tr -d '\r\n')
    if [ -z "$_uid" ]; then
        log "C2 HAL 未启动，服务日志：$(dex 'tail -12 /data/local/tmp/hwenc-svc.log 2>/dev/null' | tr '\n' ' ')" >&2
    fi
    ### 硬约束：C2 HAL 绝不能以 root 常驻。宁可让 enable 失败回退，也不新增 root。
    case "${_uid:-}" in
        "")     log "C2 HAL 未启动，拒绝继续（不新增 root）" >&2; echo 0; return 1 ;;
        root|0) log "C2 HAL 以 root 运行，拒绝继续（不新增 root）" >&2; echo 0; return 1 ;;
        *)      log "C2 HAL 运行身份：$_uid（非 root）" >&2 ;;
    esac
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
    pkill -x daemon-hwdec >/dev/null 2>&1

    ### 3) 撤注入（只删我们加的东西）
    dex '
BK=/data/local/tmp/hwenc-backup
[ -f $BK/media_codecs.xml.orig ] && cp -f $BK/media_codecs.xml.orig /vendor/etc/media_codecs.xml
### 3.9.9-r15：备份可能被旧版污染，不能只靠 cp 还原。强制删掉所有注入块，
### 保证禁用后一定只剩软件编码器，否则 MediaCodec 会一直等没启动的 C2 HAL → 黑屏。
sed -i "/c2.hardware.encoder.h264/,/<\/MediaCodec>/d" /vendor/etc/media_codecs.xml 2>/dev/null
sed -i "/c2.hardware.decoder/,/<\/MediaCodec>/d" /vendor/etc/media_codecs.xml 2>/dev/null
### 停掉 init 里可能卡在 restarting 的 vaapi 服务，避免反复 ctl.interface_start 刷日志
setprop ctl.stop android-hardware-media-c2-vaapi-hal 2>/dev/null
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
    _DECODE_ON=0
    if decode_capable; then
        _DECODE_ON=1
        log "硬件解码：本次启用（h264/hevc/vp9）"
    else
        log "硬件解码：本次不启用，播放走软件解码（编码链路不受影响）"
    fi

    if ! detect; then
        log "前置检测未通过：$_WHY"
        echo "unsupported" > "$STATUS"
        ### 3.9.9-r12：把可执行的修复办法落盘，状态页与排障时直接可见。
        if [ -n "${_HINT:-}" ]; then
            printf '%s\n' "$_HINT" > "$HINT"
            log "修复提示：$_HINT"
            echo "修复提示：$_HINT"
        else
            rm -f "$HINT"
        fi
        echo "$_WHY"
        return 1
    fi
    rm -f "$HINT"
    log "检测通过：$_ARCH / $_GPU / ${_ENC} 个编码入口"
    [ -n "${_WARN_RADEON:-}" ] && log "注意：$_WARN_RADEON；手机/平板分辨率会退回软件编码"

    ### 3.9.9-r15：只在 orig 不存在时备份。旧写法每次 enable 都无条件 cp -f 覆盖，
    ### 一旦上一次 disable 没还原干净 / 中途失败，当前 XML 已带注入条目，备份就被污染；
    ### 之后 disable 永远恢复不回原始 XML，残留 c2.hardware.encoder.h264 会让
    ### MediaCodec 去找没启动的 C2 HAL（IComponentStore/default），编不出帧 → 投屏黑屏。
    ### 2026-11-14 实测踩过；现场恢复办法是重启 Android 容器。
    mkdir -p "$BK"
    dex '[ -f /data/local/tmp/hwenc-backup/media_codecs.xml.orig ] || cp -f /vendor/etc/media_codecs.xml /data/local/tmp/hwenc-backup/media_codecs.xml.orig 2>/dev/null' >/dev/null

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

    rm -f "$HINT"
    echo "enabled" > "$STATUS"
    log "启用成功：≤$(hwenc_max_size) 走硬件编码，更高分辨率退回软件编码"
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
    [ -n "$(daemon_pids | head -1)" ] || need=1
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
### 结论：按当前实际分辨率与**当前驱动的尺寸上限**（hwenc_max_size）切换 ccodec ——
### 未超限用 4（Codec2 硬件优先），超限用 0（OMX 软件），重启 media 使其生效。
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

    local _mx _mw _mh
    _mx=$(hwenc_max_size); _mw=${_mx%x*}; _mh=${_mx#*x}
    if [ "${w:-0}" -le "${_mw:-1920}" ] && [ "${h:-9999}" -le "${_mh:-1088}" ]; then
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
        [ -f "$HINT" ] && echo "修复提示     : $(cat "$HINT")"
    fi
    if docker inspect "$CT" >/dev/null 2>&1; then
        echo "容器 ccodec  : $(dex 'getprop debug.stagefright.ccodec')   (0=OMX软件 4=Codec2)"
        echo "dma_heap     : $(dex 'ls -l /dev/dma_heap/system 2>/dev/null | awk "{print \$1}"')"
        echo "HIDL default : $(dex 'lshal 2>/dev/null | grep -c "media.c2@1.1::IComponentStore/default"') 个"
        echo "硬件编码器   : $(dex 'dumpsys media.player 2>/dev/null | grep -c "c2.hardware.encoder.h264"') 处"
        echo "硬件解码器   : $(dex 'dumpsys media.player 2>/dev/null | grep -c "c2.hardware.decoder"') 处"
    fi
    echo "硬件解码开关 : $(decode_enabled && echo 'on（默认开启）' || echo off)   驱动/上限: $(va_driver_name) / $(hwenc_max_size)"
    echo "hwdec daemon : $([ -x "$DAEMON_HWDEC" ] && echo 已安装 || echo '未安装（先在 CI 构建）')"
    echo "daemon 进程  : $([ -n "$(daemon_pids | head -1)" ] && echo 运行中 || echo 未运行)"
    echo "daemon 用户  : $([ -n "$(daemon_pids | head -1)" ] && ps -o user= -p "$(daemon_pids | head -1)" | tr -d ' ' || echo -)"
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
            if ! detect_decode; then
                echo "宿主 VA-API 解码能力检测未通过（$_WHY），硬解将自动回退软解；开关未改动"
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
            echo "硬件解码：$(decode_enabled && echo 'on（默认开启）' || echo off)   daemon-hwdec：$([ -x "$DAEMON_HWDEC" ] && echo 已安装 || echo 未安装)"
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
