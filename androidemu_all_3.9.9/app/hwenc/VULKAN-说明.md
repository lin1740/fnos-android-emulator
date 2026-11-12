# Vulkan 支持现状说明（实验）

> 对应 v3.9.2。与视频硬编解码（见同目录 BUILD-说明.md）并列的另一个加速项。

## 当前状态

**Vulkan 与 OpenGL ES 是两套独立通道**：GPU 直通（host 模式）同时为两者布线，
但镜像里各厂商的驱动文件覆盖不同。

redroid 镜像自带的 Vulkan HAL（`/vendor/lib64/hw/`）：

```
vulkan.panfrost.so   ← ARM Mali（panfrost 驱动）
vulkan.freedreno.so  ← Qualcomm Adreno（msm_drm/freedreno）
vulkan.radeon.so     ← AMD（RADV，需要 amdgpu 内核驱动）
vulkan.broadcom.so   ← Broadcom VideoCore（树莓派）
vulkan.nouveau.so    ← NVIDIA（nouveau 开源驱动 / NVK）
vulkan.virtio.so     ← virtio-gpu（虚拟机场景）
vulkan.lvp.so        ← lavapipe（软件实现）
vulkan.pastel.so     ← 软件实现（guest 模式回退）
```

host 模式下，redroid 的 `gpu_config.sh` 会按宿主内核驱动自动设置
`ro.hardware.vulkan`（intel/radeon/virtio/broadcom/freedreno/panfrost）。

## 各平台实测/推断状态

| 宿主 GPU | 状态 | 依据 |
|------|------|------|
| ARM Mali（panfrost） | ✅ 硬件 Vulkan 已激活 | 真机验证：`ro.hardware.vulkan=panfrost`，HAL 文件在 |
| Intel（i915/xe） | ❌ 镜像缺 `vulkan.intel.so`（ANV） | 镜像文件清单证实；GLES 渲染不受影响 |
| AMD（amdgpu 驱动） | ✅ 应可用（RADV），未实测 | HAL 在，机制与 panfrost 相同 |
| AMD（legacy radeon 驱动，老 APU） | ⚠️ 大概率回退软件 | RADV 需要 amdgpu 内核驱动 |
| NVIDIA 专有驱动 | ⚠️ 未验证 | 镜像带 nouveau（NVK），但 NVK 较新且无测试机 |

## 一键检测

```sh
bash scripts/vulkan_check.sh
```

只读检查，输出：宿主 GPU 驱动 → 容器内 HAL → 激活状态 → 按平台的结论。

## 与视频硬解的关系

Vulkan 和视频编解码是**两套独立通道**：Vulkan 管游戏/应用的 3D 渲染 API，
视频硬解需要的是 Codec2/OMX 解码 HAL（见同目录 BUILD-说明.md）。
Vulkan 硬件加速不等于视频硬解；视频硬解的路线见评估文档
（app/docs/GPU加速与视频硬解码评估.md）。
