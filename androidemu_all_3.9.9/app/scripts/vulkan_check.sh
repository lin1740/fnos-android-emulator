#!/bin/bash
### vulkan_check.sh — Vulkan 硬件加速状态一键检测（实验工具，只读不改任何配置）
###
### 用法：bash scripts/vulkan_check.sh
### 输出：宿主 GPU 驱动 → 容器内 Vulkan HAL → 激活状态 → 结论
### 说明：redroid 镜像自带 8 个厂商 Vulkan HAL；host 模式按宿主内核驱动自动选择。
###       本脚本只做状态检查，不做任何修改。

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
C="${ANDROIDEMU_CONTAINER:-androidemu-android}"

echo "===== 宿主侧 ====="
if [ -d /sys/class/drm ]; then
    for n in /sys/class/drm/card[0-9]/device/uevent; do
        [ -f "$n" ] || continue
        d=$(dirname "$n" | xargs basename)
        drv=$(grep '^DRIVER=' "$n" | cut -d= -f2)
        echo "  ${d}: 内核驱动 ${drv:-未知}"
    done
else
    echo "  宿主无 /sys/class/drm（无 GPU 或未直通）"
fi

echo "===== 容器内 ====="
if ! docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null | grep -q true; then
    echo "  容器未运行，无法检查容器内状态"
    exit 0
fi
echo "  ro.hardware.egl     = $(docker exec -u 0 "$C" sh -c 'getprop ro.hardware.egl' 2>/dev/null | tr -d '\r\n')"
echo "  ro.hardware.vulkan  = $(docker exec -u 0 "$C" sh -c 'getprop ro.hardware.vulkan' 2>/dev/null | tr -d '\r\n')"
echo "  ro.hardware.gralloc = $(docker exec -u 0 "$C" sh -c 'getprop ro.hardware.gralloc' 2>/dev/null | tr -d '\r\n')"
echo "  容器内 Vulkan HAL 文件："
docker exec -u 0 "$C" sh -c 'ls /vendor/lib64/hw/ 2>/dev/null | grep -i vulkan; ls /system/lib64/hw/ 2>/dev/null | grep -i vulkan' 2>/dev/null | sed 's/^/    /'

echo "===== 结论 ====="
_vv=$(docker exec -u 0 "$C" sh -c 'getprop ro.hardware.vulkan' 2>/dev/null | tr -d '\r\n')
_drv=$(grep '^DRIVER=' /sys/class/drm/card0/device/uevent 2>/dev/null | cut -d= -f2)
case "${_drv:-}" in
    panfrost|freedreno|msm_drm)
        if [ "$_vv" = "$_drv" ] || [ -n "$_vv" ]; then
            echo "  ✅ ${_drv:-} 平台：硬件 Vulkan 已由镜像内置 HAL 支持（${_vv:-已配置}）"
        else
            echo "  ⚠ ${_drv:-} 平台：宿主驱动为 ${_drv:-}，但容器内 Vulkan HAL 未激活"
        fi
        ;;
    amdgpu)
        echo "  ✅ AMD amdgpu 平台：镜像带 vulkan.radeon.so（RADV），硬件 Vulkan 可用"
        ;;
    radeon)
        echo "  ⚠ AMD legacy radeon 驱动：RADV 需要 amdgpu 内核驱动，"
        echo "    此类老卡（GCN1/2 时代 APU）大概率无法创建硬件 Vulkan 设备，将回退软件实现"
        ;;
    i915|xe)
        echo "  ❌ Intel 平台：redroid 镜像当前未包含 vulkan.intel.so（ANV），"
        echo "    Intel 核显暂无硬件 Vulkan（GLES 渲染不受影响）；后续插件包可补"
        ;;
    nvidia*)
        echo "  ⚠ NVIDIA 专有驱动：镜像带 vulkan.nouveau.so（NVK），但 NVK 较新且未验证"
        ;;
    nouveau)
        echo "  ⚠ NVIDIA（nouveau 开源驱动）：镜像带 vulkan.nouveau.so，NVK 较新，未验证"
        ;;
    "")
        echo "  未能检测到宿主 GPU 驱动"
        ;;
    *)
        echo "  未知驱动 $_drv，请结合上方容器内 HAL 文件人工判断"
        ;;
esac
echo "（本工具为只读检查，不做任何修改；GLES 渲染与 Vulkan 是两套独立通道）"
