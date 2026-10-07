#!/bin/bash
### tune_compose.sh — 按宿主【实际能力】校准 docker-compose.yaml（x86 / ARM 全架构通用）。
###
### 用法：bash tune_compose.sh <compose.yaml 路径> [--force-software]
###
### 2.0.78 关键变化：不再"按架构一刀切"。旧版是「ARM 一律软件渲染」，后果是
### 所有本来具备 DRM 渲染节点的 ARM 机器（RK3588/RK3568/已启用 panfrost 的机器）
### 也被一起降级成软件渲染 —— 一份包在不同 ARM 机器上表现不一致，不符合"一份包通用"。
### 现在改为【能力检测】，判定与架构无关：
###   · 存在 DRM 渲染节点（/dev/dri/renderD*，退而求其次 /dev/dri/card*）
###   · 且存在与宿主架构匹配、且确实含 *_dri.so 的 Mesa DRI 目录
###   → 两者齐备才启用 GPU 直通（redroid_gpu_mode=host + 挂 /dev/dri + 挂 DRI 目录）；
###   缺任一项 → 软件渲染，并把画面服务同步降档（30fps / 长边960 / 6Mbps）。
### 两个方向都【自动补齐或自动移除】对应行，因此同一台机器反复执行结果一致（幂等），
### 从软件档升到 GPU 档、或从 GPU 档退回软件档都不会残留配置。
###
### 可测试/可覆盖（排障用）：
###   ANDROIDEMU_DRM_NODE=/dev/dri/renderD128              指定渲染节点
###   ANDROIDEMU_DRI_DIR=/usr/lib/aarch64-linux-gnu/dri    指定 DRI 目录
###   --force-software                                     强制软件渲染（GPU 直通失败时由守护调用）
###
### 注意：PUBLIC_IP 的填充由调用方负责（与本脚本解耦）。

set -u

FORCE_SOFTWARE=0
COMPOSE=""
for _a in "$@"; do
    case "$_a" in
        --force-software) FORCE_SOFTWARE=1 ;;
        *) [ -z "$COMPOSE" ] && COMPOSE="$_a" ;;
    esac
done
[ -n "$COMPOSE" ] && [ -f "$COMPOSE" ] || { echo "tune_compose: compose 文件不存在：$COMPOSE" >&2; exit 0; }

ARCH="$(uname -m 2>/dev/null)"

### ── 能力检测 1：智能选择 DRM 渲染节点（核显/独显自动识别+优先级） ─────────
### 3.8.3：不再按 renderD128→renderD129 顺序盲选，而是枚举所有渲染节点、
### 读取 PCI 厂商 ID，按「渲染兼容性 + VAAPI 编码能力」综合排序：
###   Intel (0x8086) > AMD (0x1002) > NVIDIA (0x10de) > 未知
### 理由：Intel 核显 Mesa/GBM 兼容性最好且 QSV 硬编成熟；AMD 次之
### （VAAPI 编码支持好但老 APU 可能只解不编）；NVIDIA 专有驱动对
### Mesa/GBM 支持有限且 VAAPI 需 nvidia-vaapi-driver，放最后。
### 双 GPU 机器（如笔记本核显+独显）自动选核显，避免独显兼容问题。
### 可通过 ANDROIDEMU_DRM_NODE 环境变量强制指定。
DRM_NODE="${ANDROIDEMU_DRM_NODE:-}"
GPU_VENDOR=""
if [ -z "$DRM_NODE" ]; then
    ### 收集所有 renderD* 节点，按厂商优先级排序
    _best_node=""
    _best_score=0
    for N in /dev/dri/renderD*; do
        [ -e "$N" ] || continue
        _name="$(basename "$N")"
        ### 通过 sysfs 读取厂商 ID（renderD 节点的 device 软链接指向 PCI 设备）
        _vendor=""
        for _syspath in "/sys/class/drm/$_name/device/vendor" \
                        "/sys/class/drm/$_name/device/../vendor"; do
            if [ -r "$_syspath" ]; then
                _vendor="$(cat "$_syspath" 2>/dev/null)"
                break
            fi
        done
        ### 评分：Intel=3, AMD=2, NVIDIA=1, 未知=0
        _score=0
        case "$_vendor" in
            0x8086|*8086*) _score=3; GPU_VENDOR="Intel" ;;
            0x1002|*1002*) _score=2; GPU_VENDOR="AMD" ;;
            0x10de|*10de*) _score=1; GPU_VENDOR="NVIDIA" ;;
            *) _score=0; GPU_VENDOR="Unknown" ;;
        esac
        if [ "$_score" -gt "$_best_score" ]; then
            _best_score="$_score"
            _best_node="$N"
        fi
    done
    ### 如果没有 renderD*，退而求其次用 card*
    if [ -z "$_best_node" ]; then
        for N in /dev/dri/card*; do
            [ -e "$N" ] && _best_node="$N" && break
        done
    fi
    DRM_NODE="$_best_node"
fi
if [ -n "$DRM_NODE" ]; then
    echo "tune_compose[$ARCH]: 选择 GPU 节点 $DRM_NODE${GPU_VENDOR:+（$GPU_VENDOR）}"
fi

### ── 能力检测 2：与架构匹配、且真的含 Mesa DRI 驱动的目录 ───────────────
DRI_DIR="${ANDROIDEMU_DRI_DIR:-}"
if [ -z "$DRI_DIR" ]; then
    ### 2.0.80：回退 2.0.79 新增的通用 DRI 路径——/usr/lib64/dri、/usr/lib/dri、
    ### /vendor/lib64/dri 在 x86 飞牛 OS 上可能存在但与 redroid 容器 glibc/Mesa 不兼容，
    ### 误命中后 host 模式 surfaceflinger 崩溃→redroid 无限重启。只保留多架构标准路径。
    for D in /usr/lib/x86_64-linux-gnu/dri /usr/lib/aarch64-linux-gnu/dri \
             /usr/lib/arm-linux-gnueabihf/dri /usr/lib/aarch64-linux-gnu/dri-panfrost; do
        if [ -d "$D" ] && ls "$D"/*_dri.so >/dev/null 2>&1; then
            DRI_DIR="$D"
            break
        fi
    done
fi
[ -n "$DRI_DIR" ] && ! ls "$DRI_DIR"/*_dri.so >/dev/null 2>&1 && DRI_DIR=""

GPU_OK=0
if [ "$FORCE_SOFTWARE" = "0" ] && [ -n "$DRM_NODE" ] && [ -n "$DRI_DIR" ]; then
    GPU_OK=1
fi

### ── 能力检测 3：NVIDIA GPU（NVENC 硬编需 nvidia-vaapi-driver） ───────────
### 3.8.3：检测 NVIDIA 设备节点，存在则直通并挂载驱动库。
### redroid FFmpeg 仅支持 VAAPI，NVIDIA 需宿主机安装 nvidia-vaapi-driver
### 才能通过 VAAPI 接口调用 NVENC；未安装时自动回退软件编码，不影响渲染。
NVIDIA_DEVICES=""
NVIDIA_LIBS=""
if [ -e /dev/nvidiactl ]; then
    for N in /dev/nvidiactl /dev/nvidia0 /dev/nvidia1 /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
        [ -e "$N" ] && NVIDIA_DEVICES="$NVIDIA_DEVICES $N"
    done
    ### 检测 NVIDIA 驱动库目录
    for D in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
        if ls "$D"/libnvidia-encode.so* >/dev/null 2>&1 || ls "$D"/libcuda.so* >/dev/null 2>&1; then
            NVIDIA_LIBS="$D"
            break
        fi
    done
    if [ -n "$NVIDIA_DEVICES" ]; then
        echo "tune_compose[$ARCH]: 检测到 NVIDIA GPU${NVIDIA_LIBS:+，驱动库 $NVIDIA_LIBS}（NVENC 硬编需 nvidia-vaapi-driver）"
    fi
fi

### ── 只动与 GPU/binder 相关的行，其它配置（镜像名、端口、卷、网络）一律不碰 ──
if [ "$GPU_OK" = "1" ]; then
    ### ① 设备直通：确保 devices: 块里有 /dev/dri
    if ! grep -qE '^[[:space:]]*-[[:space:]]*/dev/dri[[:space:]]*$' "$COMPOSE"; then
        if grep -qE '^[[:space:]]*devices:[[:space:]]*$' "$COMPOSE"; then
            sed -i '0,/^[[:space:]]*devices:[[:space:]]*$/s//&\n      - \/dev\/dri/' "$COMPOSE"
        else
            sed -i '0,/^[[:space:]]*privileged:[[:space:]]*true[[:space:]]*$/s//&\n    devices:\n      - \/dev\/dri/' "$COMPOSE"
        fi
        echo "tune_compose[$ARCH]: 补齐 /dev/dri 设备直通（$DRM_NODE）"
    fi
    ### ①-NVIDIA：直通 NVIDIA 设备节点（NVENC 硬编所需）
    if [ -n "$NVIDIA_DEVICES" ]; then
        for N in $NVIDIA_DEVICES; do
            N_BASENAME="$(basename "$N")"
            if ! grep -qE "^[[:space:]]*-[[:space:]]*${N}[[:space:]]*$" "$COMPOSE"; then
                sed -i "0,/^[[:space:]]*-[[:space:]]*\/dev\/dri[[:space:]]*$/s//&\n      - ${N}/" "$COMPOSE"
            fi
        done
        echo "tune_compose[$ARCH]: 已直通 NVIDIA 设备${NVIDIA_DEVICES}"
    fi
    ### ①-NVIDIA驱动库：挂载 NVIDIA 用户态驱动（libcuda/libnvidia-encode）
    if [ -n "$NVIDIA_LIBS" ]; then
        if ! grep -qE 'libnvidia|libcuda' "$COMPOSE"; then
            sed -i "0,\#^[[:space:]]*-[[:space:]].*:/.*/dri:ro[[:space:]]*$#s//&\n      - ${NVIDIA_LIBS}/libcuda.so.1:${NVIDIA_LIBS}/libcuda.so.1:ro\n      - ${NVIDIA_LIBS}/libnvidia-encode.so.1:${NVIDIA_LIBS}/libnvidia-encode.so.1:ro/" "$COMPOSE"
            echo "tune_compose[$ARCH]: 已挂载 NVIDIA 驱动库（$NVIDIA_LIBS）"
        fi
    fi
    ### ② DRI 目录挂载：路径按宿主实际目录校正
    if grep -qE '/dri:' "$COMPOSE"; then
        sed -i "s#- /usr/lib/[a-z0-9_-]*/dri:/usr/lib/[a-z0-9_-]*/dri:ro#- $DRI_DIR:$DRI_DIR:ro#" "$COMPOSE"
    else
        ### 注意：路径里全是 /，必须换分隔符（用 #），否则 sed 会因 "unknown option to `s'" 静默失败
        sed -i "0,\#^[[:space:]]*volumes:[[:space:]]*\$#s##&\n      - $DRI_DIR:$DRI_DIR:ro#" "$COMPOSE"
        echo "tune_compose[$ARCH]: 补齐宿主 DRI 目录挂载（$DRI_DIR）"
    fi
    ### ③ 启动参数：GPU 直通 + 60fps + 指定 GPU 节点
    if grep -qE 'androidboot\.redroid_gpu_mode=' "$COMPOSE"; then
        sed -i 's/androidboot\.redroid_gpu_mode=[a-z]*/androidboot.redroid_gpu_mode=host/' "$COMPOSE"
    else
        sed -i '0,/^[[:space:]]*-[[:space:]]*androidboot\.redroid_fps=.*$/s//&\n      - androidboot.redroid_gpu_mode=host/' "$COMPOSE"
    fi
    ### 3.8.3：指定 redroid 使用的 GPU 渲染节点（智能选择后的结果）
    if [ -n "$DRM_NODE" ]; then
        if grep -qE 'androidboot\.redroid_gpu_node=' "$COMPOSE"; then
            sed -i "s#androidboot\.redroid_gpu_node=[^ ]*#androidboot.redroid_gpu_node=$DRM_NODE#" "$COMPOSE"
        else
            sed -i "0,/androidboot\.redroid_gpu_mode=host/s//&\n      - androidboot.redroid_gpu_node=$DRM_NODE/" "$COMPOSE"
        fi
    fi
    sed -i 's/androidboot\.redroid_fps=[0-9]*/androidboot.redroid_fps=60/' "$COMPOSE"
    ### ④ 画面服务回升到 GPU 档（此前可能被软件档降过）
    sed -i 's/"fps":30/"fps":60/g' "$COMPOSE"
    sed -i 's/"size":960/"size":1280/g' "$COMPOSE"
    sed -i 's/"maxBitrate":6/"maxBitrate":10/g' "$COMPOSE"
    ### 3.8.3 VAAPI硬件编码能力检测：仅当宿主 GPU 真正支持 VAAPI 编码时才启用，
    ### 避免老 GPU（如 AMD Kaveri 只解不编）启用后 OMX.redroid.h264.encoder 异常导致黑屏。
    VAAPI_ENCODE_OK=0
    if command -v vainfo >/dev/null 2>&1 && [ -n "$DRM_NODE" ]; then
        if vainfo --display drm --device "$DRM_NODE" 2>/dev/null | grep -qE 'VAEntrypointEnc(Slice|Picture|SliceLP)'; then
            VAAPI_ENCODE_OK=1
        fi
    fi
    if [ "$VAAPI_ENCODE_OK" = "1" ]; then
        if ! grep -q 'androidboot.use_redroid_vaapi=1' "$COMPOSE"; then
            sed -i '0,/androidboot\.redroid_gpu_node=/s//&\n      - androidboot.use_redroid_vaapi=1\n      - androidboot.use_redroid_omx=1/' "$COMPOSE"
        fi
        echo "tune_compose[$ARCH]: VAAPI 硬编已启用（$GPU_VENDOR 支持编码）"
    else
        sed -i '/^[[:space:]]*-[[:space:]]*androidboot\.use_redroid_vaapi=1/d' "$COMPOSE"
        sed -i '/^[[:space:]]*-[[:space:]]*androidboot\.use_redroid_omx=1/d' "$COMPOSE"
        echo "tune_compose[$ARCH]: VAAPI 硬编未启用（$GPU_VENDOR 不支持编码或无 vainfo，使用 Google 软件编码器）"
    fi
    echo "tune_compose[$ARCH]: GPU 直通 host（节点 $DRM_NODE，DRI $DRI_DIR），画面 60fps/长边1280/10Mbps"
else
    sed -i '/^[[:space:]]*-[[:space:]]*androidboot\.redroid_gpu_mode=host/d' "$COMPOSE"
    sed -i '/^[[:space:]]*-[[:space:]]*androidboot\.redroid_gpu_node=/d' "$COMPOSE"
    sed -i '/^[[:space:]]*-[[:space:]]*androidboot\.use_redroid_vaapi=1/d' "$COMPOSE"
    sed -i '/^[[:space:]]*-[[:space:]]*androidboot\.use_redroid_omx=1/d' "$COMPOSE"
    sed -i '\#^[[:space:]]*-[[:space:]]*/dev/dri[[:space:]]*$#d' "$COMPOSE"
    ### 移除任意 "宿主目录:宿主目录/dri 目录:ro" 形式的 DRI 挂载（不限于 /usr/lib，避免换过目录后残留）
    sed -i '\#^[[:space:]]*-[[:space:]].*:/.*/dri:ro[[:space:]]*$#d' "$COMPOSE"
    ### 3.8.3：移除 NVIDIA 设备直通与驱动库挂载（软件渲染时不需要）
    sed -i '\#^[[:space:]]*-[[:space:]]*/dev/nvidia[[:space:]]*$#d' "$COMPOSE"
    sed -i '\#^[[:space:]]*-[[:space:]].*libcuda\.so[[:space:]]*$#d' "$COMPOSE"
    sed -i '\#^[[:space:]]*-[[:space:]].*libnvidia-encode\.so[[:space:]]*$#d' "$COMPOSE"
    sed -i 's/androidboot\.redroid_fps=60/androidboot.redroid_fps=30/' "$COMPOSE"
    ### 3.4.7：无 DRM 渲染节点时必须显式 gpu_mode=guest（swiftshader），
    ### 否则 redroid 默认尝试 GPU 直通导致 SurfaceFlinger 反复重启、安卓无法 boot_completed。
    ### 有 DRM 节点但缺 Mesa DRI 驱动时不强制 guest（由 redroid 默认行为兜底，避免与部分宿主参数冲突）。
    if [ -z "$DRM_NODE" ]; then
        if ! grep -qE 'androidboot\.redroid_gpu_mode=' "$COMPOSE"; then
            sed -i '0,/^[[:space:]]*-[[:space:]]*androidboot\.redroid_fps=.*$/s//&\n      - androidboot.redroid_gpu_mode=guest/' "$COMPOSE"
            echo "tune_compose[$ARCH]: 无 DRM 节点，显式 gpu_mode=guest（swiftshader 软件渲染）"
        fi
    fi
    ### 软件渲染下【画面服务也要跟着降档】：安卓内部跑 30fps，画面服务若仍按 60fps/1280/10Mbps
    ### 编码，SwiftShader 下纯属浪费（更卡、更占带宽）。
    sed -i 's/"fps":60/"fps":30/g' "$COMPOSE"
    sed -i 's/"size":1280/"size":960/g' "$COMPOSE"
    sed -i 's/"maxBitrate":10/"maxBitrate":6/g' "$COMPOSE"
    if [ "$FORCE_SOFTWARE" = "1" ]; then
        echo "tune_compose[$ARCH]: 强制软件渲染（GPU 直通在容器内失败后的自动回退）"
    else
        echo "tune_compose[$ARCH]: 软件渲染 swiftshader（DRM 节点=${DRM_NODE:-无}，DRI=${DRI_DIR:-无}）"
    fi
    echo "tune_compose[$ARCH]: 画面服务已同步降档：30fps / 长边 960 / 6Mbps"
fi

### binderfs 形态：无 /dev/binder 静态节点则移除其设备直通（容器内自建 binderfs）
if [ ! -e /dev/binder ]; then
    sed -i '\#^[[:space:]]*-[[:space:]]*/dev/binder[[:space:]]*$#d' "$COMPOSE"
    echo "tune_compose[$ARCH]: 宿主无 /dev/binder，按 binderfs 形态处理（移除 /dev/binder 直通）"
fi

### 2.0.5 边界修复：若 devices 下的条目被全部移除，必须连 devices: 键一起删，
### 否则 YAML 残留 devices: 空值，docker compose 直接拒绝启动。
if ! grep -qE '^[[:space:]]+-[[:space:]]*/dev/' "$COMPOSE"; then
    sed -i '\#^[[:space:]]*devices:[[:space:]]*$#d' "$COMPOSE"
    echo "tune_compose[$ARCH]: devices 已无宿主机节点条目，一并移除 devices: 键（避免空值导致 compose 校验失败）"
fi

### ── 渲染模式与原因写入 ${VAR_DIR}/render-mode（面板展示） ───────────────
RENDER_VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
mkdir -p "$RENDER_VAR_DIR" 2>/dev/null || true
write_render_mode() {
    ### $1=MODE $2=REASON [$3=FPS] [$4=SIZE] [$5=GPU_MODE]
    {
        echo "MODE=$1"
        echo "REASON=$2"
        [ -n "${3:-}" ] && echo "FPS=$3"
        [ -n "${4:-}" ] && echo "SIZE=$4"
        [ -n "${5:-}" ] && echo "GPU_MODE=$5"
        echo "UPDATED=$(date '+%F %T')"
    } > "$RENDER_VAR_DIR/render-mode" 2>/dev/null || true
}
if [ "$GPU_OK" = "1" ]; then
    write_render_mode "gpu" "检测到 DRM 渲染节点 $DRM_NODE 与 Mesa DRI 目录 $DRI_DIR：已启用 GPU 直通（host），画面 60fps" "" "" "host"
elif [ "$FORCE_SOFTWARE" = "1" ]; then
    write_render_mode "software" "GPU 直通在本机容器内未能正常工作，已自动回退软件渲染（swiftshader），画面降到 30fps/长边960" "30" "960"
elif [ -n "$DRM_NODE" ] && [ -z "$DRI_DIR" ]; then
    ### 2.0.80：回退 2.0.79 的 guest 模式分支——插入 androidboot.redroid_gpu_mode=guest
    ### 在部分宿主上与 redroid 启动参数冲突导致无限重启。恢复为纯 software 渲染（swiftshader），
    ### 不插入任何 gpu_mode 参数，由 redroid 默认行为处理。
    write_render_mode "software" "有 DRM 渲染节点（$DRM_NODE）但缺少匹配的 Mesa DRI 驱动目录：已软件渲染（swiftshader），画面降到 30fps/长边960" "30" "960"
elif [ -e /dev/mali0 ] && [ -z "$DRM_NODE" ]; then
    write_render_mode "software" "本机为专有 Mali 驱动（/dev/mali0），内核未提供 DRM 渲染节点（如未启用 panfrost）：已自动软件渲染（swiftshader），并把画面降到 30fps/长边960 以减少卡顿" "30" "960"
elif [ -z "$DRM_NODE" ]; then
    write_render_mode "software" "本机无 DRM 渲染节点（/dev/dri）：已自动软件渲染（swiftshader），并把画面降到 30fps/长边960" "30" "960"
else
    write_render_mode "software" "无法启用 GPU 直通：已自动软件渲染（swiftshader），并把画面降到 30fps/长边960" "30" "960"
fi

### ── 翻译层切换（3.8.3：自动下载+auto模式+崩溃自动切换） ─────────────────
### 支持通过 ANDROIDEMU_TRANSLATION 环境变量选择ARM翻译层：
###   ndk     - Google libndk_translation（默认，稳定，不支持ARMv8.1+指令）
###   houdini - Intel libhoudini（自动下载，支持较新指令）
###   auto    - 智能模式：默认ndk，检测到SIGILL/Undefined instruction崩溃自动切houdini
### 切换原理：通过bind mount把翻译层库覆盖到容器内 /system/lib*/libnb.so 位置，
### redroid默认通过libnb.so加载翻译层，覆盖后自动使用新翻译层，无需修改系统配置。
TRANSLATION="${ANDROIDEMU_TRANSLATION:-auto}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOUDINI_DIR="${SCRIPT_DIR}/../translation/houdini"
CRASH_FLAG="${TRIM_PKGVAR:-/var/apps/androidemu/var}/translation_crash.flag"

### auto模式：检查是否有崩溃记录，有则强制使用houdini
if [ "$TRANSLATION" = "auto" ]; then
    if [ -f "$CRASH_FLAG" ]; then
        TRANSLATION="houdini"
        echo "tune_compose[$ARCH]: auto模式检测到翻译层崩溃记录，自动切换到houdini"
    else
        TRANSLATION="ndk"
    fi
fi

### houdini模式：自动下载libhoudini（如不存在）
if [ "$TRANSLATION" = "houdini" ]; then
    if [ ! -f "$HOUDINI_DIR/lib64/libhoudini.so" ] && [ ! -f "$HOUDINI_DIR/lib/libhoudini.so" ]; then
        echo "tune_compose[$ARCH]: 未找到libhoudini，尝试自动下载..."
        bash "${SCRIPT_DIR}/download_houdini.sh" "$HOUDINI_DIR" 2>&1 || echo "tune_compose[$ARCH]: 自动下载失败，将回退ndk" >&2
    fi
fi

### 先移除可能存在的旧翻译层挂载（幂等）
sed -i '\#^[[:space:]]*-[[:space:]]*.*translation/houdini.*libnb\.so#d' "$COMPOSE"
sed -i '\#^[[:space:]]*-[[:space:]]*.*translation/ndk.*libnb\.so#d' "$COMPOSE"

if [ "$TRANSLATION" = "houdini" ]; then
    HOUDINI64="${HOUDINI_DIR}/lib64/libhoudini.so"
    HOUDINI32="${HOUDINI_DIR}/lib/libhoudini.so"
    if [ -f "$HOUDINI64" ] || [ -f "$HOUDINI32" ]; then
        if [ -f "$HOUDINI64" ]; then
            sed -i '/^[[:space:]]*container_name: androidemu-android/,/^[[:space:]]*[a-z_]*:/{
                /^[[:space:]]*volumes:/a\
      - '"${HOUDINI64}"':/system/lib64/libnb.so:ro
            }' "$COMPOSE"
            echo "tune_compose[$ARCH]: 翻译层=houdini(64位)，已挂载 -> /system/lib64/libnb.so"
        fi
        if [ -f "$HOUDINI32" ]; then
            sed -i '/^[[:space:]]*container_name: androidemu-android/,/^[[:space:]]*[a-z_]*:/{
                /^[[:space:]]*volumes:/a\
      - '"${HOUDINI32}"':/system/lib/libnb.so:ro
            }' "$COMPOSE"
            echo "tune_compose[$ARCH]: 翻译层=houdini(32位)，已挂载 -> /system/lib/libnb.so"
        fi
    else
        echo "tune_compose[$ARCH]: 警告：houdini不可用，回退ndk" >&2
        TRANSLATION="ndk"
    fi
fi

if [ "$TRANSLATION" = "ndk" ]; then
    echo "tune_compose[$ARCH]: 翻译层=ndk（默认，Google libndk_translation）"
    ### 清除崩溃标记（ndk模式下重置）
    rm -f "$CRASH_FLAG" 2>/dev/null || true
fi

exit 0
