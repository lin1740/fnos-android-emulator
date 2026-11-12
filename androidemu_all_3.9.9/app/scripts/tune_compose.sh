#!/bin/bash
### tune_compose.sh — 按宿主【实际能力】校准 docker-compose.yaml（x86 / ARM 全架构通用）。
###
### 用法：bash tune_compose.sh <compose.yaml 路径> [--force-software]
###

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

### 3.9.4：画面服务对外 IP 兜底（2026-11-03 用户实测）
### 根因：compose 里 PUBLIC_IP=${ANDROIDEMU_HOST_IP:-127.0.0.1}，而全流程没有任何地方给
### ANDROIDEMU_HOST_IP 赋值（net_mode.sh 只在用户手动点「网络检测/端口设置」时才跑），
### 容器就一直拿 127.0.0.1 当对外地址：面板弹「检测到被控端仅上报 Docker 内部私有 IP」、
### TURN 候选不可达、画面反复重连（表现为桌面像在自动刷新）。
### 处理：仅在「从未配置」或「已配置但仍是 127.0.0.1/docker 网桥」时自动按 LAN 模式写入
### 真实局域网 IP；用户配过 wan/域名/自定义端口的一律不动，绝不覆盖用户设置。
_ae_netfix() {
    local _vd="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
    local _conf="$_vd/net.conf" _mode="" _host=""
    if [ -f "$_conf" ]; then
        _mode=$(sed -n 's/^MODE=//p' "$_conf" 2>/dev/null | head -n1)
        _host=$(sed -n 's/^HOST=//p' "$_conf" 2>/dev/null | head -n1)
    fi
    ### 用户配过 wan/公网且填了主机名 → 不动
    if [ "$_mode" = "wan" ] && [ -n "$_host" ]; then return 0; fi
    ### 当前 compose 里 PUBLIC_IP 的实际值（取默认分支的值）
    local _cur=""
    _cur=$(grep -o 'PUBLIC_IP=\${ANDROIDEMU_HOST_IP:-[0-9.]*}' "$COMPOSE" 2>/dev/null | head -n1 | sed 's/.*:-//; s/}//')
    case "$_cur" in
        127.*|172.1[6-9].*|172.2[0-9].*|172.3[0-9].*|"") ;;   ### 需要修
        *.*.*.*) return 0 ;;                                   ### 已是正常 IP，不动
        *) ;;                                                   ### 其它（域名等）不动后续再判
    esac
    [ -n "$_cur" ] && case "$_cur" in *[a-zA-Z]*) return 0 ;; esac
    ### 取真实局域网 IP（net_util.sh 已排除 docker 网桥）
    local _lan="" _d
    _d=$(dirname "$0")
    if [ -f "$_d/net_util.sh" ]; then
        # shellcheck disable=SC1091
        . "$_d/net_util.sh" 2>/dev/null
        if command -v ae_lan_ip >/dev/null 2>&1; then _lan="$(ae_lan_ip 2>/dev/null)"; fi
    fi
    [ -z "$_lan" ] && _lan="$(hostname -I 2>/dev/null | awk '{print $1}')"
    case "$_lan" in
        127.*|172.1[6-9].*|172.2[0-9].*|172.3[0-9].*|"") return 0 ;;
    esac
    if [ -f "$_d/net_mode.sh" ]; then
        echo "tune_compose: 对外地址当前为 ${_cur:-未设置}，自动按 LAN 模式写入 $_lan"
        bash "$_d/net_mode.sh" lan --no-restart >/dev/null 2>&1 || true
    fi

    ### 3.9.5：把宿主局域网 IP 传给容器内 Agent。
    ### 缺失时 Agent 只上报容器内网 IP（172.x），面板判定「网络物理隔离」拒绝连接
    ### （2026-11-03 用户实测）。容器环境变量会被 Agent 继承，无需改 Agent 启动脚本。
    if [ -n "$_lan" ] && ! grep -qE "CP_AGENT_EXTERNAL_ADDR=" "$COMPOSE" 2>/dev/null; then
        ### 用 awk 逐行插入（sed 的 \\n 在替换串里多次实测会写成字面 /n，把 YAML 写坏）
        _tmpc="$COMPOSE.ae_tmp"
        if awk -v ip="$_lan" '
            !done && /^[[:space:]]*devices:[[:space:]]*$/ {
                print "    environment:"
                print "      - CP_AGENT_EXTERNAL_ADDR=" ip
                done = 1
            }
            { print }
        ' "$COMPOSE" > "$_tmpc" 2>/dev/null && [ -s "$_tmpc" ]; then
            mv -f "$_tmpc" "$COMPOSE" 2>/dev/null || { cp -f "$_tmpc" "$COMPOSE" 2>/dev/null; rm -f "$_tmpc"; }
            echo "tune_compose: 已向容器注入 CP_AGENT_EXTERNAL_ADDR=$_lan（Agent 上报地址）"
        else
            rm -f "$_tmpc" 2>/dev/null || true
        fi
    fi
}
_ae_netfix


### ── 3.8.9：镜像名/版本统一取自「单一可信源」runtime.conf ──────────────────────
### 换 Android 版本（9~16 任选）或上游标签，只改 app/docker/runtime.conf 一处即可；
### 本脚本负责把该配置**写进** compose 的 image: 行（幂等；默认值与模板一致，故行为不变）。
### 这样新增版本不需要改任何代码，也不会把某个版本写死在 compose 里。
_RT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$_RT_DIR/rtconf.sh" ]; then
    # shellcheck disable=SC1091
    . "$_RT_DIR/rtconf.sh"
    rtconf_load
    if [ -n "${CANON_REDROID:-}" ]; then
        sed -i -E "s#^([[:space:]]*image:[[:space:]]*).*(redroid/redroid):[^[:space:]]+#\1${CANON_REDROID}#" "$COMPOSE" 2>/dev/null || true
    fi
    if [ -n "${CANON_WEBRTC:-}" ]; then
        ### 3.9.1：镜像内容由 pull_image 按 digest 拉取后回打到 CANON tag（内容锁死），
        ### 升级流程不再刷新 latest，tag 不会被移动 —— compose 引用保持 tag 形式即可。
        ### sed 同时匹配 `repo:tag` 与 `repo@digest` 两种形态（历史包/手工改动也幂等重写）。
        sed -i -E "s#^([[:space:]]*image:[[:space:]]*)[^[:space:]]*scrcpy-over-webrtc[^[:space:]]*#\1${CANON_WEBRTC}#" "$COMPOSE" 2>/dev/null || true
    fi
    echo "tune_compose: 镜像按 runtime.conf 写入（Android ${ANDROID_VER:-?}）"
fi

ARCH="$(uname -m 2>/dev/null)"

### ── 能力检测 1：智能选择 DRM 渲染节点（核显/独显自动识别+优先级） ─────────
DRM_NODE="${ANDROIDEMU_DRM_NODE:-}"
GPU_VENDOR=""
if [ -z "$DRM_NODE" ]; then
    ### 收集所有 renderD* 节点，按厂商优先级排序
    ### 3.9.1 修复：_best_score 初值必须为 -1。原为 0 时，未知厂商（ARM 的 Mali/panfrost、
    ### /sys/class/drm/renderD*/device/vendor 不存在）评分为 0，`0 > 0` 不成立 → renderD
    ### 永远选不上，退回 card*（显示节点，需 DRM master）→ redroid 用 card 做 GPU 渲染
    ### 是花屏/黑屏的典型成因。实测 ARM 机有 renderD128 却被跳过、选了 card0。
    _best_node=""
    _best_score=-1
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
    for D in /usr/lib/x86_64-linux-gnu/dri /usr/lib/aarch64-linux-gnu/dri \
             /usr/lib/arm-linux-gnueabihf/dri /usr/lib/aarch64-linux-gnu/dri-panfrost; do
        if [ -d "$D" ] && ls "$D"/*_dri.so >/dev/null 2>&1; then
            DRI_DIR="$D"
            break
        fi
    done
fi
[ -n "$DRI_DIR" ] && ! ls "$DRI_DIR"/*_dri.so >/dev/null 2>&1 && DRI_DIR=""

### ── 能力检测 2.5：GPU 家族识别与所需 Mesa 驱动校验（3.9.1，兼容主流 ARM GPU）──
### 目的：host 直通不只要求「有 renderD + 有 dri 目录」，还要求「该 GPU 家族对应的
###       Mesa 驱动确实存在」。缺驱动时 redroid 会走到黑屏/花屏或卡开机，因此提前判定
###       并回退软件渲染，把问题挡在开机之前。
### 覆盖：Mali(panfrost/panthor)、Adreno(msm/freedreno)、VideoCore(v3d)、Vivante(etnaviv)、
###       Tegra、Mali-4xx(lima)、Rockchip、AMD(radeonsi)、Intel(iris/i915)、NVIDIA(nouveau/专有)。
GPU_DRIVER=""; GPU_FAMILY=""; GPU_DRI_NEEDED=""
if [ -n "$DRM_NODE" ]; then
    _ue="/sys/class/drm/$(basename "$DRM_NODE")/device/uevent"
    [ -r "$_ue" ] && GPU_DRIVER="$(sed -n 's/^DRIVER=//p' "$_ue" 2>/dev/null | head -n1 | tr -d '\r')"
    ### ARM 多数平台 uevent 无 DRIVER，用设备树 compatible 兜底
    if [ -z "$GPU_DRIVER" ]; then
        _cf="/sys/class/drm/$(basename "$DRM_NODE")/device/of_node/compatible"
        if [ -r "$_cf" ]; then
            _cs="$(tr '\0' ' ' < "$_cf" 2>/dev/null)"
            case "$_cs" in
                *mali*|*panfrost*|*panthor*) GPU_DRIVER="panfrost" ;;
                *adreno*|*msm*)              GPU_DRIVER="msm" ;;
                *etnaviv*|*vivante*)         GPU_DRIVER="etnaviv" ;;
                *v3d*|*videocore*)           GPU_DRIVER="v3d" ;;
                *tegra*)                     GPU_DRIVER="tegra" ;;
                *lima*)                      GPU_DRIVER="lima" ;;
                *rockchip*)                  GPU_DRIVER="rockchip" ;;
            esac
        fi
    fi
fi
case "$GPU_DRIVER" in
    panfrost|panthor) GPU_FAMILY="ARM Mali（panfrost/panthor）"; GPU_DRI_NEEDED="panfrost_dri.so" ;;
    msm)              GPU_FAMILY="ARM Adreno（freedreno/msm）";  GPU_DRI_NEEDED="msm_dri.so" ;;
    v3d)              GPU_FAMILY="Broadcom VideoCore（v3d）";    GPU_DRI_NEEDED="v3d_dri.so" ;;
    etnaviv)          GPU_FAMILY="Vivante（etnaviv）";           GPU_DRI_NEEDED="etnaviv_dri.so" ;;
    tegra)            GPU_FAMILY="NVIDIA Tegra（mesa tegra）";   GPU_DRI_NEEDED="tegra_dri.so" ;;
    lima)             GPU_FAMILY="ARM Mali-4xx（lima）";         GPU_DRI_NEEDED="lima_dri.so" ;;
    rockchip)         GPU_FAMILY="Rockchip";                    GPU_DRI_NEEDED="rockchip_dri.so" ;;
    radeon|amdgpu)    GPU_FAMILY="AMD（radeonsi）";              GPU_DRI_NEEDED="radeonsi_dri.so" ;;
    i915|xe)          GPU_FAMILY="Intel（iris）";                GPU_DRI_NEEDED="iris_dri.so" ;;
    nouveau)          GPU_FAMILY="NVIDIA（开源 nouveau）";       GPU_DRI_NEEDED="nouveau_dri.so" ;;
    nvidia*)          GPU_FAMILY="NVIDIA（专有驱动）";           GPU_DRI_NEEDED="" ;;
esac

GPU_DRI_MISSING=0
if [ -n "$GPU_DRI_NEEDED" ] && [ -n "$DRI_DIR" ] && [ ! -f "$DRI_DIR/$GPU_DRI_NEEDED" ]; then
    ### 老平台兼容：Intel 早期只有 i915_dri.so；AMD 早期只有 r600_dri.so
    _alt=""
    case "$GPU_DRI_NEEDED" in
        iris_dri.so)     _alt="i915_dri.so" ;;
        radeonsi_dri.so) _alt="r600_dri.so" ;;
    esac
    if [ -n "$_alt" ] && [ -f "$DRI_DIR/$_alt" ]; then
        GPU_DRI_NEEDED="$_alt"
    else
        GPU_DRI_MISSING=1
        echo "tune_compose[$ARCH]: ⚠ $GPU_FAMILY 需要 $GPU_DRI_NEEDED，但 $DRI_DIR 中缺失 → 预先回退软件渲染（避免黑屏/花屏）"
    fi
fi
if [ -n "$GPU_FAMILY" ]; then
    echo "tune_compose[$ARCH]: GPU 家族 $GPU_FAMILY（内核驱动 ${GPU_DRIVER:-未知}，Mesa ${GPU_DRI_NEEDED:-通用}）"
fi

### 3.9.8：DRM 真实性预检 —— 「有 /dev/dri 节点 + 有 Mesa 目录」不等于 GPU 能用。
### 虚拟机常见虚拟显卡（virtio/vmwgfx/bochs/simpledrm）或纯占位节点，节点和 Mesa 都在，
### 但容器内 EGL 打不开设备 → surfaceflinger 无限重启 → 开机卡死（实测虚拟机卡 75 分钟、
### 面板 0 台在线，logcat 全是 "Failed to open any DRM device"）。
### 判据：读 /sys/class/drm/cardN/device/uevent 的 DRIVER 值。
### 真机是 i915 / amdgpu / radeon / nouveau / panfrost 等；虚拟显卡是
### vmwgfx(VMware SVGA) / virtio_gpu / bochs / simpledrm / vkms / qxl / cirrus 等，
### 还有「节点存在但完全没有 DRIVER」的占位设备 —— 这两类都直接预置软件渲染。
### （实测虚拟机 DRIVER=vmwgfx，节点与 Mesa 目录齐全，但容器内 EGL 完全打不开。）
if [ "$FORCE_SOFTWARE" = "0" ] && [ -n "$DRM_NODE" ] && [ "$ARCH" = "x86_64" ]; then
    _GPU_DRV=""
    for _cd in /sys/class/drm/card[0-9]*; do
        [ -e "$_cd/device/uevent" ] || continue
        _d=$(sed -n 's/^DRIVER=//p' "$_cd/device/uevent" 2>/dev/null | head -n1)
        [ -n "$_d" ] && { _GPU_DRV="$_d"; break; }
    done
    case "$_GPU_DRV" in
        ''|vmwgfx|virtio_gpu|bochs*|simpledrm|simple-framebuffer|vkms|qxl|cirrus|mgag200|vboxvideo)
            FORCE_SOFTWARE=1
            echo "tune_compose[$ARCH]: 虚拟/占位显卡（DRIVER=${_GPU_DRV:-无}，容器内 GPU 直通不可用）→ 直接预置软件渲染，避免开机卡死"
            ;;
    esac
fi

GPU_OK=0
if [ "$FORCE_SOFTWARE" = "0" ] && [ -n "$DRM_NODE" ] && [ -n "$DRI_DIR" ] && [ "$GPU_DRI_MISSING" = "0" ]; then
    GPU_OK=1
fi

### ── 能力检测 3：NVIDIA GPU（host 模式需完整用户态栈；NVENC 硬编需 nvidia-vaapi-driver） ──
NVIDIA_DEVICES=""
NVIDIA_LIBS_DIR=""
NVIDIA_IS_ONLY_GPU=0
NVIDIA_DRM_MODESET=""
if [ -e /dev/nvidiactl ] || [ "$GPU_VENDOR" = "NVIDIA" ]; then
    for N in /dev/nvidiactl /dev/nvidia0 /dev/nvidia1 /dev/nvidia2 \
             /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
        [ -e "$N" ] && NVIDIA_DEVICES="$NVIDIA_DEVICES $N"
    done
    ### 检测 NVIDIA 驱动库目录
    for D in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
        if ls "$D"/libnvidia-*.so* >/dev/null 2>&1 || ls "$D"/libcuda.so* >/dev/null 2>&1; then
            NVIDIA_LIBS_DIR="$D"
            break
        fi
    done
    ### 是否「只有 NVIDIA 一块 GPU」（无 Intel/AMD 的 DRM 节点）
    _other_gpu=0
    for N in /dev/dri/renderD* /dev/dri/card*; do
        [ -e "$N" ] || continue
        _nn="$(basename "$N")"
        _vn=""
        for _sp in "/sys/class/drm/$_nn/device/vendor" "/sys/class/drm/$_nn/device/../vendor"; do
            [ -r "$_sp" ] && _vn="$(cat "$_sp" 2>/dev/null)" && break
        done
        case "$_vn" in *10de*) : ;; *) _other_gpu=1 ;; esac
    done
    [ "$_other_gpu" = "0" ] && NVIDIA_IS_ONLY_GPU=1
    ### nvidia-drm modeset 是否开启（GBM / host 模式的前提）
    [ -r /sys/module/nvidia_drm/parameters/modeset ] && NVIDIA_DRM_MODESET="$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null | tr -d '\r\n')"
    if [ -n "$NVIDIA_DEVICES" ]; then
        _nv_note=""
        [ "$NVIDIA_IS_ONLY_GPU" = "1" ] && _nv_note="，本机唯一 GPU"
        [ -n "$NVIDIA_LIBS_DIR" ] && _nv_note="$_nv_note，驱动库 $NVIDIA_LIBS_DIR"
        [ -n "$NVIDIA_DRM_MODESET" ] && _nv_note="$_nv_note，nvidia_drm.modeset=$NVIDIA_DRM_MODESET"
        echo "tune_compose[$ARCH]: 检测到 NVIDIA GPU${_nv_note}（NVENC 硬编需 nvidia-vaapi-driver）"
    fi
fi

if [ "$GPU_OK" = "1" ] && [ "$NVIDIA_IS_ONLY_GPU" = "1" ] && [ "$NVIDIA_DRM_MODESET" != "Y" ]; then
    echo "tune_compose[$ARCH]: NVIDIA 独占且 nvidia_drm.modeset 未启用 → 回退软件渲染以保证稳定开机（如需 GPU 直通，请在内核启动参数加 nvidia-drm.modeset=1 后重启）"
    GPU_OK=0
fi
if [ "$GPU_OK" = "1" ] && [ "$NVIDIA_IS_ONLY_GPU" = "1" ] && [ -z "$NVIDIA_LIBS_DIR" ]; then
    echo "tune_compose[$ARCH]: NVIDIA 独占但未找到专有驱动用户态库（libcuda/libnvidia-*.so）→ 回退软件渲染（避免黑屏）"
    GPU_OK=0
fi

### ── 只动与 GPU/binder 相关的行，其它配置（镜像名、端口、卷、网络）一律不碰 ──
if [ "$GPU_OK" = "1" ]; then
    ### ① 设备直通：**显式列节点**，不再挂 /dev/dri 目录。
    ### 3.9.5 修复（2026-11-03 实测黑屏）：`devices: - /dev/dri` 这种目录形式在
    ### 当前 Docker 上只会把 card0 挂进容器，renderD128 丢失 → Mesa EGL 报
    ### "failed to retrieve device information / failed to get driver name for fd -1"
    ### → 画面全黑（容器内 /dev/dri 只剩 card0）。改为逐节点直通。
    _dri_nodes=""
    for N in /dev/dri/renderD* /dev/dri/card*; do
        [ -e "$N" ] && _dri_nodes="$_dri_nodes $N"
    done
    if [ -n "$_dri_nodes" ]; then
        ### 清掉旧的目录形式（含带 rw/m 后缀的写法）
        sed -i -E '/^[[:space:]]*-[[:space:]]*\/dev\/dri(:.*)?[[:space:]]*$/d' "$COMPOSE"
        for N in $_dri_nodes; do
            if ! grep -qE "^[[:space:]]*-[[:space:]]*${N}[[:space:]]*$" "$COMPOSE"; then
                if grep -qE '^[[:space:]]*devices:[[:space:]]*$' "$COMPOSE"; then
                    sed -i "0,\#^[[:space:]]*devices:[[:space:]]*\$#s##&\n      - ${N}#" "$COMPOSE"
                else
                    sed -i "0,\#^[[:space:]]*privileged:[[:space:]]*true[[:space:]]*\$#s##&\n    devices:\n      - ${N}#" "$COMPOSE"
                fi
            fi
        done
        echo "tune_compose[$ARCH]: 逐节点直通 GPU 设备${_dri_nodes}（render 节点缺失会导致黑屏）"
    fi
    ### ①-NVIDIA：直通 NVIDIA 设备节点（host 模式与 NVENC 硬编所需）
    if [ -n "$NVIDIA_DEVICES" ]; then
        for N in $NVIDIA_DEVICES; do
            if ! grep -qE "^[[:space:]]*-[[:space:]]*${N}[[:space:]]*$" "$COMPOSE"; then
                sed -i "0,\#^[[:space:]]*devices:[[:space:]]*\$#s##&\n      - ${N}#" "$COMPOSE"
            fi
        done
        echo "tune_compose[$ARCH]: 已直通 NVIDIA 设备${NVIDIA_DEVICES}"
    fi
    ### ①-NVIDIA驱动库：挂载 redroid host 模式所需的完整 NVIDIA 用户态栈
    ### （libcuda + GBM 分配器 libnvidia-allocator + EGL/GLES/GLX + 编码库；存在才挂）
    if [ -n "$NVIDIA_LIBS_DIR" ]; then
        ### 幂等：先移除上一次自动插入的挂载块（标记行不含 "/"，用 "/" 作分隔符即可）
        sed -i '/# >>> androidemu-nvidia-libs/,/# <<< androidemu-nvidia-libs/d' "$COMPOSE" 2>/dev/null || true
        _nvblock=""
        for _pat in libcuda.so.1 libnvidia-allocator.so.1 \
                    libnvidia-eglcore.so.* libnvidia-glcore.so.* libnvidia-glsi.so.* \
                    libnvidia-glvkspirv.so.* libnvidia-rtcore.so.* libnvidia-gpucomp.so.* \
                    libnvidia-encode.so.1 libnvidia-ptxjitcompiler.so.* libnvidia-nvvm.so.* \
                    libnvidia-cfg.so.* libnvidia-ml.so.* libnvidia-fbc.so.* \
                    libEGL_nvidia.so.0 libGLESv2_nvidia.so.2 libGLX_nvidia.so.0 libvdpau_nvidia.so.*; do
            for _f in "$NVIDIA_LIBS_DIR"/$_pat; do
                [ -e "$_f" ] || continue
                case "$_nvblock" in *"${_f}:"*) continue ;; esac
                _nvblock="${_nvblock}      - ${_f}:${_f}:ro
"
            done
        done
        ### nvidia-vaapi-driver（VAAPI→NVENC 桥接；存在才挂）
        for _f in "$NVIDIA_LIBS_DIR"/dri/nvidia_drv_video.so /usr/lib/x86_64-linux-gnu/dri/nvidia_drv_video.so; do
            [ -e "$_f" ] || continue
            case "$_nvblock" in *"${_f}:"*) continue ;; esac
            _nvblock="${_nvblock}      - ${_f}:${_f}:ro
"
        done
        if [ -n "$_nvblock" ]; then
            _nvtmp="$(mktemp 2>/dev/null || echo /tmp/ae_nv.$$)"
            { echo "      # >>> androidemu-nvidia-libs"; printf '%s' "$_nvblock"; echo "      # <<< androidemu-nvidia-libs"; } > "$_nvtmp" 2>/dev/null
            ### 在 DRI 挂载行之后插入（sed r 命令，避免分隔符与路径冲突）
            sed -i "\#^[[:space:]]*-[[:space:]].*:/.*/dri:ro[[:space:]]*\$#r $_nvtmp" "$COMPOSE" 2>/dev/null || true
            rm -f "$_nvtmp" 2>/dev/null || true
            echo "tune_compose[$ARCH]: 已挂载 NVIDIA 用户态驱动库（$NVIDIA_LIBS_DIR）"
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
    ### 3.8.9：修复 —— 原用 "/" 作 sed 分隔符但替换内容含 "/dev/dri/..." 路径，
    ###   现场报 "unknown option to `s'" 静默失败，导致 redroid_gpu_node 从未写入。
    ###   改用 "#" 分隔符（路径里的 "/" 不再需要转义）。
    if [ -n "$DRM_NODE" ]; then
        if grep -qE 'androidboot\.redroid_gpu_node=' "$COMPOSE"; then
            sed -i "s#androidboot\.redroid_gpu_node=[^ ]*#androidboot.redroid_gpu_node=$DRM_NODE#" "$COMPOSE"
        else
            sed -i "0,\#androidboot\.redroid_gpu_mode=host#s##&\n      - androidboot.redroid_gpu_node=$DRM_NODE#" "$COMPOSE"
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
    ### 3.9.2 修正：vainfo 有 EncSlice 不等于 redroid 的 OMX/VAAPI 编码链路能用。
    ### 实测（AMD Kaveri + 内核 radeon 传统驱动，Mesa 23.2.1）：vainfo 报告
    ### H264Main/High 都有 VAEntrypointEncSlice，但一旦写入 use_redroid_omx=1，
    ### 系统起不来 / 画面黑屏 / SurfaceEncoder 崩溃 —— 已回滚过一次。
    ### 因此：AMD 传统 radeon 驱动一律不自动启用；其它平台保留自动检测，
    ### 想强制试验可设 ANDROIDEMU_VAAPI_ENCODE=1。
    if [ "$VAAPI_ENCODE_OK" = "1" ]; then
        case "${GPU_DRIVER:-}" in
            radeon)
                if [ "${ANDROIDEMU_VAAPI_ENCODE:-0}" != "1" ]; then
                    VAAPI_ENCODE_OK=0
                    echo "tune_compose[$ARCH]: AMD 传统 radeon 驱动，VAAPI 硬编默认关闭（历史实测会黑屏）；如需试验设 ANDROIDEMU_VAAPI_ENCODE=1"
                fi
                ;;
        esac
    fi
    if [ "$VAAPI_ENCODE_OK" = "1" ]; then
        if ! grep -q 'androidboot.use_redroid_vaapi=1' "$COMPOSE"; then
            # 必须整行匹配再追加：只匹配 "redroid_gpu_node=" 前缀会把两行插到 "=" 与
            # 节点路径之间，得到 "gpu_node=" 空值 + "use_redroid_omx=1/dev/dri/renderD128"
            # 这样的畸形命令行 —— redroid 起不来、安卓永远不 boot（实测踩过）。
            sed -i '0,/^[[:space:]]*-[[:space:]]*androidboot\.redroid_gpu_node=.*$/s//&\n      - androidboot.use_redroid_vaapi=1\n      - androidboot.use_redroid_omx=1/' "$COMPOSE"
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
    ### 3.8.9 修复：原正则要求行尾正好是 "/dev/nvidia"，但真实节点都带后缀
    ###   （nvidiactl / nvidia0 / nvidia-uvm / nvidia-modeset …）→ 从未匹配、直通行残留；
    ###   切回软件渲染后 compose 仍引用宿主上不存在的设备，docker compose up 会直接创建失败。
    sed -i \
        -e '\#^[[:space:]]*-[[:space:]]*/dev/nvidia[^[:space:]]*[[:space:]]*$#d' \
        -e '\#^[[:space:]]*-[[:space:]].*libcuda\.so[^[:space:]]*[[:space:]]*$#d' \
        -e '\#^[[:space:]]*-[[:space:]].*libnvidia-[a-z-]*\.so[^[:space:]]*[[:space:]]*$#d' \
        -e '\#^[[:space:]]*-[[:space:]].*libEGL_nvidia\.so[^[:space:]]*[[:space:]]*$#d' \
        -e '\#^[[:space:]]*-[[:space:]].*libGLESv2_nvidia\.so[^[:space:]]*[[:space:]]*$#d' \
        -e '\#^[[:space:]]*-[[:space:]].*libGLX_nvidia\.so[^[:space:]]*[[:space:]]*$#d' \
        -e '\#^[[:space:]]*-[[:space:]].*libvdpau_nvidia\.so[^[:space:]]*[[:space:]]*$#d' \
        -e '\#^[[:space:]]*-[[:space:]].*nvidia_drv_video\.so[^[:space:]]*[[:space:]]*$#d' \
        "$COMPOSE"
    ### 3.8.9：移除上一版自动插入的完整 NVIDIA 用户态栈挂载块
    sed -i '/# >>> androidemu-nvidia-libs/,/# <<< androidemu-nvidia-libs/d' "$COMPOSE" 2>/dev/null || true
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
    write_render_mode "gpu" "检测到 ${GPU_FAMILY:-GPU}（节点 $DRM_NODE，Mesa $DRI_DIR）：已启用 GPU 直通（host），画面 60fps" "" "" "host"
elif [ "$FORCE_SOFTWARE" = "1" ]; then
    write_render_mode "software" "GPU 直通在本机容器内未能正常工作，已自动回退软件渲染（swiftshader），画面降到 30fps/长边960" "30" "960"
elif [ "$GPU_DRI_MISSING" = "1" ]; then
    write_render_mode "software" "检测到 ${GPU_FAMILY}，但本机缺少对应 Mesa 驱动（$GPU_DRI_NEEDED）：已预先软件渲染（swiftshader），画面降到 30fps/长边960" "30" "960"
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
FAILED_FLAG="${TRIM_PKGVAR:-/var/apps/androidemu/var}/translation_houdini_failed.flag"
### 3.9.1：翻译层应用名单（两份翻译层并存、按应用各取所长）
###   用法：在 var/translation_apps.conf 里每行写一个包名（# 为注释），例如 com.trim.app。
###   语义：名单内的应用只要已安装 → 本容器用 Intel houdini；名单为空或无匹配 → 谷歌 ndk。
###   与 auto 的关系：名单优先于崩溃启发式；名单命中且 libhoudini 不可用时回退 ndk 并记警告。
APPS_CONF="${TRIM_PKGVAR:-/var/apps/androidemu/var}/translation_apps.conf"

### auto模式：先看应用名单（确定性强），再看崩溃记录
if [ "$TRANSLATION" = "auto" ]; then
    _tt_choice="ndk"
    _tt_reason="默认谷歌翻译层（ndk）"
    if [ -f "$APPS_CONF" ] && [ -s "$APPS_CONF" ]; then
        _tt_hit=""
        for _pkg in $(grep -vE '^\s*#|^\s*$' "$APPS_CONF" 2>/dev/null); do
            if docker exec androidemu-android pm path "$_pkg" >/dev/null 2>&1; then
                _tt_hit="$_pkg"
                break
            fi
        done
        if [ -n "$_tt_hit" ]; then
            _tt_choice="houdini"
            _tt_reason="名单应用已安装：$_tt_hit → 使用 Intel houdini（其余应用同样受用）"
        else
            _tt_reason="名单内应用均未安装 → 保持 ndk（$APPS_CONF）"
        fi
    elif [ -f "$CRASH_FLAG" ] && [ ! -f "$FAILED_FLAG" ]; then
        _tt_choice="houdini"
        _tt_reason="检测到翻译层崩溃记录 → 使用 houdini"
    fi
    if [ "$_tt_choice" = "houdini" ] && [ -f "$FAILED_FLAG" ]; then
        _tt_choice="ndk"
        _tt_reason="houdini 曾崩溃且已标记失败 → 强制回退 ndk（rm $FAILED_FLAG 可重新启用）"
    fi
    TRANSLATION="$_tt_choice"
    echo "tune_compose[$ARCH]: 翻译层决策（auto）：$_tt_reason"
fi

### houdini模式：自动下载libhoudini（如不存在）
if [ "$TRANSLATION" = "houdini" ]; then
    if [ ! -f "$HOUDINI_DIR/lib64/libhoudini.so" ] && [ ! -f "$HOUDINI_DIR/lib/libhoudini.so" ]; then
        echo "tune_compose[$ARCH]: 未找到libhoudini，尝试自动下载..."
        bash "${SCRIPT_DIR}/download_houdini.sh" "$HOUDINI_DIR" 2>&1 || echo "tune_compose[$ARCH]: 自动下载失败，将回退ndk" >&2
    fi
fi

### 先移除可能存在的旧翻译层挂载（幂等；含 libnb/bin/arm64 全部形态）
sed -i '\#^[[:space:]]*-[[:space:]]*.*translation/houdini#d; \#^[[:space:]]*-[[:space:]]*.*armlibs#d; \#^[[:space:]]*-[[:space:]]*.*system/lib/arm#d; \#^[[:space:]]*-[[:space:]]*.*nb32#d' "$COMPOSE"
sed -i '\#^[[:space:]]*-[[:space:]]*.*translation/ndk.*libnb\.so#d' "$COMPOSE"

# 3.9.1：向 redroid 服务的 volumes: 列表追加一行挂载（幂等）。
# 历史 bug：旧实现用 sed 的 "container_name 到下一个键" 范围定位 volumes:，
# 而 restart: 就在 container_name 下一行，范围覆盖不到几十行外的 volumes:
# → 静默无操作却打印"已挂载"，houdini 从未真正生效。
_ae_add_volume() {
    local line="$1" tmp
    grep -qF -- "$line" "$COMPOSE" 2>/dev/null && return 0
    tmp="$(mktemp)"
    awk -v ins="$line" '
        /^  redroid:/ {svc=1}
        /^  webrtc:/ {svc=0}
        svc && /^    volumes:/ && !done {print; print ins; done=1; next}
        {print}' "$COMPOSE" > "$tmp" 2>/dev/null && mv -f "$tmp" "$COMPOSE"
    grep -qF -- "$line" "$COMPOSE" 2>/dev/null
}

### 3.9.1 热修：ARM 系统库集挂载（/system/lib/arm + /system/lib64/arm64）
### 背景：libndk 只翻译应用安装目录；微信等 Tinker 类应用运行时把 ARM 库解压到数据目录
### 再 dlopen —— 缺 32 位 ARM 库集时必报 "EM_ARM instead of EM_386"。补齐后微信可正常启动。
ARM_SET=""
for _d in "${SCRIPT_DIR}/../translation/houdini" "${TRIM_PKGVAR:-/var/apps/androidemu/var}/armlibs"; do
    if [ -d "$_d/lib/arm" ]; then
        if [ -n "$(ls "$_d/lib/arm"/*.so 2>/dev/null | head -1)" ]; then ARM_SET="$_d"; break; fi
        if [ -n "$(ls "$_d/lib/arm/arm"/*.so 2>/dev/null | head -1)" ]; then ARM_SET="$_d|nested"; break; fi
    fi
done
if [ -z "$ARM_SET" ]; then
    echo "tune_compose[$ARCH]: 未找到 ARM 系统库集，尝试自动获取（约 100MB，用于微信等 Tinker 应用）..." >&2
    bash "${SCRIPT_DIR}/download_houdini.sh" "${SCRIPT_DIR}/../translation/houdini" >/dev/null 2>&1 || true
    _d="${SCRIPT_DIR}/../translation/houdini"
    if [ -n "$(ls "$_d/lib/arm"/*.so 2>/dev/null | head -1)" ]; then ARM_SET="$_d"; fi
    if [ -n "$(ls "$_d/lib/arm/arm"/*.so 2>/dev/null | head -1)" ]; then ARM_SET="$_d|nested"; fi
fi
if [ -n "$ARM_SET" ]; then
    _base="${ARM_SET%%|*}"
    if [ "${ARM_SET##*|}" = "nested" ]; then
        _a32="$_base/lib/arm/arm"; _a64="$_base/lib64/arm64/arm64"
    else
        _a32="$_base/lib/arm"; _a64="$_base/lib64/arm64"
    fi
    [ -d "$_a32" ] && _ae_add_volume "      - ${_a32}:/system/lib/arm:ro" \
        && echo "tune_compose[$ARCH]: ARM32 系统库集已挂载（$(ls "$_a32"/*.so 2>/dev/null | wc -l) 个）"
    ### 3.9.1 热修（重要）：**不可**把外部 ARM64 库集覆盖挂到 /system/lib64/arm64。
    ### 镜像原生的 59 个 ARM64 库集中含 ndk_translation 必需的 libnative_bridge_vdso.so，
    ### 外部（houdini 来源）库集没有该文件，覆盖后 ndk_translation 报
    ### "native_bridge_initialize: unable to open .../libnative_bridge_vdso.so"，
    ### 导致高德、网易云等 ARM64 应用全部启动失败。故 ARM64 一律使用镜像原生库集。
else
    echo "tune_compose[$ARCH]: 警告：ARM 系统库集不可用（微信等 Tinker 类应用将无法运行）" >&2
fi

### 3.9.4：32 位 ARM 原生桥（ndk_translation 32 位）
### 背景：镜像自带 64 位 ARM 翻译（/system/lib64/libndk_translation.so 与 /system/bin/arm64/），
### 但 32 位侧只有「声明」没有实体：/system/lib/libndk_translation.so 缺失、/system/bin/arm/
### 目录不存在。后果是系统 abilist 里写着支持 armeabi-v7a，装 32 位 ARM 应用一启动就崩：
###   native_bridge_initialize: unable to open the file "/system/bin/arm/app_process"
### 处置：把 32 位桥本体、EGL/GLES 代理库、32 位 ARM 入口（app_process/linker）挂进镜像。
### 文件放在包内 translation/nb32（约 3.4MB），缺失时只提示不阻断启动。
NB32_DIR="${SCRIPT_DIR}/../translation/nb32"
if [ -f "${NB32_DIR}/lib/libndk_translation.so" ]; then
    _ae_add_volume "      - ${NB32_DIR}/lib/libndk_translation.so:/system/lib/libndk_translation.so:ro" >/dev/null 2>&1 \
        && echo "tune_compose[$ARCH]: 32 位 ARM 桥已挂载 -> /system/lib/libndk_translation.so" \
        || echo "tune_compose[$ARCH]: 32 位 ARM 桥挂载写入失败" >&2
    _n32=1
    for _p in "${NB32_DIR}"/lib/libndk_translation_proxy_*.so; do
        [ -f "$_p" ] || continue
        _ae_add_volume "      - ${_p}:/system/lib/${_p##*/}:ro" >/dev/null 2>&1 || true
    done
    ### 32 位 ARM 的 vdso：缺它时桥会在 app_process 之后停下，
    ### 报 unable to open the file "/system/lib/arm/libnative_bridge_vdso.so"。
    ### 注意：不能给它单独做 bind-mount —— /system 是只读的，Docker 无法在
    ### 「由另一条挂载创建出来的目录」上再建挂载点，会直接导致容器创建失败
    ### （实测：create mountpoint ... read-only file system）。改为把它复制进
    ### ARM 系统库集目录，随目录挂载一起生效。
    if [ -f "${NB32_DIR}/lib/libnative_bridge_vdso.so" ] && [ -n "${_a32:-}" ] && [ -d "${_a32}" ]; then
        if cp -f "${NB32_DIR}/lib/libnative_bridge_vdso.so" "${_a32}/" 2>/dev/null; then
            echo "tune_compose[$ARCH]: 32 位 ARM vdso 已并入 ARM 系统库集"
        else
            echo "tune_compose[$ARCH]: 注意：32 位 ARM vdso 复制失败（32 位应用可能无法启动）" >&2
        fi
    fi
    ### ARM ELF 直接 exec 时由内核 binfmt 转交给它（兜底路径，缺失不阻断应用启动）
    if [ -f "${NB32_DIR}/bin/ndk_translation_program_runner_binfmt_misc" ]; then
        _ae_add_volume "      - ${NB32_DIR}/bin/ndk_translation_program_runner_binfmt_misc:/system/bin/ndk_translation_program_runner_binfmt_misc:ro" >/dev/null 2>&1 || true
    fi
    for _e in app_process linker; do
        [ -f "${NB32_DIR}/bin/${_e}" ] || continue
        if _ae_add_volume "      - ${NB32_DIR}/bin/${_e}:/system/bin/arm/${_e}:ro"; then
            _n32=$((_n32 + 1))
        fi
    done
    echo "tune_compose[$ARCH]: 32 位 ARM 运行器已挂载（${_n32} 项，armeabi-v7a 应用可启动）"
else
    echo "tune_compose[$ARCH]: 注意：未找到 32 位 ARM 桥（translation/nb32），32 位 ARM 应用将无法启动" >&2
fi

if [ "$TRANSLATION" = "houdini" ]; then
    HOUDINI64="${HOUDINI_DIR}/lib64/libhoudini.so"
    HOUDINI32="${HOUDINI_DIR}/lib/libhoudini.so"
    if [ -f "$HOUDINI64" ] || [ -f "$HOUDINI32" ]; then
        # 3.9.2 修正：镜像内 /system/lib*/libnb.so 是指向 libndk_translation.so 的
        # 符号链接 —— 把文件 bind-mount 到符号链接路径，Docker 会挂到链接**目标**上，
        # 直接把 ndk 库覆盖成 houdini（符号解析两不像，zygote 报
        # "cannot locate symbol android_get_application_target_sdk_version"）。
        # 正确做法：直接覆盖真实文件 libndk_translation.so，libnb.so 软链自然生效。
        if [ -f "$HOUDINI64" ]; then
            if _ae_add_volume "      - ${HOUDINI64}:/system/lib64/libndk_translation.so:ro"; then
                echo "tune_compose[$ARCH]: 翻译层=houdini(64位)，已挂载 -> /system/lib64/libndk_translation.so（经 libnb.so 软链加载）"
            else
                echo "tune_compose[$ARCH]: 挂载写入失败(64位)" >&2
            fi
        fi
        if [ -f "$HOUDINI32" ]; then
            if _ae_add_volume "      - ${HOUDINI32}:/system/lib/libndk_translation.so:ro"; then
                echo "tune_compose[$ARCH]: 翻译层=houdini(32位)，已挂载 -> /system/lib/libndk_translation.so"
            else
                echo "tune_compose[$ARCH]: 挂载写入失败(32位)" >&2
            fi
        fi
        # 3.9.2：houdini 三件套的另外两件 —— 缺任一则 ARM 应用翻译必失败
        #（libhoudini 运行时需 exec 翻译器并读取 ARM 库映射集）。
        if [ -f "${HOUDINI_DIR}/bin/houdini64" ]; then
            _ae_add_volume "      - ${HOUDINI_DIR}/bin/houdini64:/system/bin/houdini64:ro" \
                && echo "tune_compose[$ARCH]: 翻译器已挂载 -> /system/bin/houdini64" || true
        else
            echo "tune_compose[$ARCH]: 注意：未找到 bin/houdini64（旧版包布局），ARM64 翻译可能不完整" >&2
        fi
        if [ -f "${HOUDINI_DIR}/bin/houdini" ]; then
            _ae_add_volume "      - ${HOUDINI_DIR}/bin/houdini:/system/bin/houdini:ro" >/dev/null 2>&1 || true
        fi
        if [ -d "${HOUDINI_DIR}/lib64/arm64" ] && [ -n "$(ls "${HOUDINI_DIR}/lib64/arm64" 2>/dev/null | head -1)" ]; then
            _ae_add_volume "      - ${HOUDINI_DIR}/lib64/arm64:/system/lib64/arm64:ro" \
                && echo "tune_compose[$ARCH]: ARM64 库集已挂载 -> /system/lib64/arm64" || true
        else
            echo "tune_compose[$ARCH]: 注意：未找到 ARM64 库集（arm64/），部分 ARM 应用可能链接失败" >&2
        fi
        # 3.9.2：supremegamers 完整版（blob 仓库布局）—— 32 位库集 + ARM linker
        if [ -d "${HOUDINI_DIR}/lib/arm" ] && [ -n "$(ls "${HOUDINI_DIR}/lib/arm" 2>/dev/null | head -1)" ]; then
            _ae_add_volume "      - ${HOUDINI_DIR}/lib/arm:/system/lib/arm:ro" >/dev/null 2>&1 \
                && echo "tune_compose[$ARCH]: ARM32 库集已挂载 -> /system/lib/arm" || true
        fi
        [ -f "${HOUDINI_DIR}/bin/arm64/linker64" ] && _ae_add_volume "      - ${HOUDINI_DIR}/bin/arm64/linker64:/system/bin/arm64/linker64:ro" >/dev/null 2>&1 || true
        [ -f "${HOUDINI_DIR}/bin/arm/linker" ] && _ae_add_volume "      - ${HOUDINI_DIR}/bin/arm/linker:/system/bin/arm/linker:ro" >/dev/null 2>&1 || true
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

# 3.9.2 注：binfmt_misc 切换功能撤回（toybox echo 转义差异曾致坏条目，
# 待改用 printf 二进制安全写法后在 3.9.2/4.0.0 重新引入；houdini 挂载链不受影响，
# 仅 ARM 程序 exec 走 binfmt 的场景暂由 ndk 原生注册兜底）。

# 3.9.1：compose 必须全局可读 —— 网关以 docker-androidemu 身份运行，
# 读不到 compose 会导致 USE_TLS 回退 true、上游握手失败（503）。
# 3.9.4：本脚本全程用 sed -i 改写 compose，而 sed -i 是「写临时文件再 mv」，
# 以系统身份执行时会把属主变成系统账号 → 应用用户读不到 → 守护每轮报 PermissionError、
# 网关也起不来。这里统一把属主还给应用用户（已在安装脚本里定义，取不到就跳过）。
chmod 644 "$COMPOSE" 2>/dev/null || true
if [ -n "${TRIM_APPDEST:-}" ]; then
    chown docker-androidemu:docker "$COMPOSE" 2>/dev/null || true
fi

### 3.9.4 核查记录（结论：不改 compose，此处仅留档防止后人重复添加）
### 曾计划用 `-v /dev/null:/sys/power/state:ro` 封堵「容器让宿主 NAS 休眠」的通道。
### 2026-11-01 实测后否决，原因为 redroid 镜像已自带隔离：
###   /vendor/etc/init/redroid.common.rc:66
###       mount none /data/.empty /sys/power/state bind
### 即 Android 的 system_suspend 写入落在数据卷的 /data/.empty，不会触达宿主内核节点。
### 实测佐证：容器内 /proc/self/mountinfo 只存在
###   `/@appdata/androidemu/vol-data/androidemu-data/.empty → /sys/power/state (btrfs)`
### 一层；Docker 侧再叠加的 bind 会被该层覆盖（先挂后覆盖），既无效又多一条写入路径，
### 故不注入。若要确认真实状态请用 `selfcheck.sh` 第七节，不要单看 test -w
### （系统身份有 CAP_DAC_OVERRIDE，对只读挂载仍返回「可写」，属假阳性）。

### 3.9.2：seccomp 配置改成「真实安装目录」的绝对路径。
### 原因：模板里写死 /var/apps/<app>/target/... 是飞牛给的软链路径，个别机器上该软链
### 在首次启用那一刻还没建立，dockerd 解析 seccomp 文件失败 → compose 创建容器失败 →
### 应用中心只显示「compose或者container异常」。改用 readlink 解析后的真实路径即可绕开。
_SEC_FILE=""
_COMP_DIR="$(cd "$(dirname "$COMPOSE")" 2>/dev/null && pwd)"
_COMP_REAL="$(readlink -f "$(dirname "$COMPOSE")" 2>/dev/null)"
for _cand in "$_COMP_REAL/androidemu-redroid-seccomp.json" "$_COMP_DIR/androidemu-redroid-seccomp.json"; do
    [ -n "$_cand" ] && [ -f "$_cand" ] && { _SEC_FILE="$_cand"; break; }
done
if [ -n "$_SEC_FILE" ]; then
    sed -i -E "s#^([[:space:]]*-[[:space:]]*seccomp=).*#\1${_SEC_FILE}#" "$COMPOSE" 2>/dev/null || true
    echo "tune_compose[$ARCH]: seccomp 配置路径 → $_SEC_FILE"
else
    sed -i '\#^[[:space:]]*-[[:space:]]*seccomp=#d' "$COMPOSE" 2>/dev/null || true
    ### 3.9.4：删掉唯一的列表项后，`security_opt:` 会变成空键（YAML 解析为 null），
    ### docker compose 直接报 "security_opt must be a array" → 容器创建失败。
    ### 这里把已经变空的 security_opt 键一并移除，避免少了 json 文件就整个起不来。
    _so_next="$(awk '/^[[:space:]]*security_opt:[[:space:]]*$/{f=1;next} f&&/^[[:space:]]*(#|$)/{next} f{print;exit}' "$COMPOSE" 2>/dev/null)"
    if ! printf '%s' "$_so_next" | grep -qE '^[[:space:]]*-[[:space:]]'; then
        sed -i '\#^[[:space:]]*security_opt:[[:space:]]*$#d' "$COMPOSE" 2>/dev/null || true
    fi
    echo "tune_compose[$ARCH]: 未找到 seccomp 配置，已移除该项（安全性略降，不影响启动）"
fi

exit 0
