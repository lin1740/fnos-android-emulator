# GPU 加速与视频硬解码评估说明

> 本文档对应 v3.9.2，记录本应用在各硬件平台上的 GPU 加速能力全景、视频硬解码的
> 技术现状、以及后续路线。面向关心性能与解码方式的用户与排查人员。

## 一、GPU 加速能力全景

| 加速项 | 状态 | 说明 |
|------|------|------|
| OpenGL ES 渲染（UI/游戏画面） | ✅ 硬件加速 | host 模式 + Mesa，经 /dev/dri/renderD128 直连宿主 GPU，唯一走 GPU 的项，也是收益最大的项 |
| Vulkan | ⚠️ 按驱动而定 | 镜像自带 8 个厂商 Vulkan HAL（panfrost/radeon/broadcom/freedreno/nouveau/virtio/lvp/pastel），host 模式按内核驱动自动激活；**缺 vulkan.intel.so（ANV）**，Intel 核显暂无硬件 Vulkan |
| 视频解码 | ❌ 软件解码 | redroid 镜像不含硬件视频解码 HAL（见下文），所有播放器均为软解 |
| 视频编码（推流） | ❌ 软件编码 | 同上，镜像内无 VAAPI/编解码组件 |
| 音频编解码 | 软件 | CPU 占用可忽略，无硬件加速价值 |
| AI / NNAPI | ❌ 无 | 容器无 NPU 通道；x86 核显亦无 NPU 硬件 |
| Widevine DRM | 仅 L3（软件） | L1 需要硬件 TEE，容器架构上不可实现 |
| JPEG / 图像编解码 | 软件 | CPU 占用低 |

## 二、为什么视频播放提示「硬解失败，已切换为软解」

这是**正常现象，不是故障**：

1. 容器化安卓（redroid）的 GPU 直通只覆盖 **OpenGL/Vulkan 渲染**；视频解码需要
   容器内有「MediaCodec 硬件解码 HAL」（Codec2/OMX 硬件编解码组件），
   而 redroid 官方镜像内**只有 OMX.google.* 软件编解码器，没有任何硬件编解码组件**。
2. 播放器（如飞牛影视）启动时查询系统解码器列表，发现没有硬件解码器，
   即提示「硬解失败」并自动切换软解——播放从一开始就是软解，提示只是告知。
3. GPU 面板显示「Video 引擎 0%」正是宿主硬解单元从未被调用的直接证据；
   软解在主流核显设备上可达 40-60fps，播放流畅不受影响。

建议：如播放器设置中有「解码方式」选项，直接固定软解，可省去每次播放前
尝试硬解失败的等待；没有该选项则忽略提示即可。

## 三、Vulkan 支持现状

redroid 镜像自带以下 Vulkan HAL，host 模式下按宿主内核驱动自动选择：

| 宿主 GPU / 驱动 | Vulkan HAL | 状态 |
|------|------|------|
| ARM Mali（panfrost） | vulkan.panfrost.so | ✅ 已激活（真机验证） |
| AMD（amdgpu 驱动，Polaris 之后） | vulkan.radeon.so | ✅ 应可用（未实测） |
| AMD（legacy radeon 驱动，老 APU） | vulkan.radeon.so | ⚠️ RADV 需要 amdgpu 内核驱动，legacy 驱动的老卡可能无法创建硬件设备 |
| Intel | 无 | ❌ 镜像未包含 vulkan.intel.so（ANV） |
| NVIDIA | vulkan.nouveau.so | 未验证（NVK 较新，且无测试机） |

## 四、视频硬件编解码的可行性评估（2026-10）

唯一在做此事的开源项目：**redroid-hwenc**（github.com/fogelmanjg/redroid-hwenc，
Apache-2.0）。redroid 官方仓库的相关需求挂了 4 年无人实现。

已完成并真机验证：

- **硬件编码全流水线**：真实未修改应用通过正式框架路径录制硬件 H.264，
  在 AMD Renoir(GFX9)、AMD RX 480(GFX8)、Intel Iris Xe(Gen12) 三台真机验证通过；
- **硬件解码（仅 NVIDIA）**：NVDEC 经 VA-API，c2.hardware.decoder.h264 Codec2
  组件 + 守护进程，GTX 1050 Ti 上 PSNR 位精确验证；
- 4 年无解的核心难题「gralloc dma-buf 能否导入 VAAPI surface」已被该项目验证可行。

尚未完成（我们最需要的部分）：

- **Intel / AMD 的解码后端**——当前解码仅接了 NVIDIA（NVDEC），
  Intel/AMD 的 libva 解码后端尚待开发；
- 组件尚未打包为可直接部署的稳定版本（研究阶段，分七层难度阶梯推进）。

## 四点五、宿主侧实测记录（2026-10-23，AMD Kaveri + fnOS）

在本 NAS（AMD Kaveri，内核 legacy radeon 驱动）上编译并运行了 redroid-hwenc 的
宿主侧 daemon 与 test-client，结果：**daemon 初始化失败**——系统 VAAPI 驱动
（r600/radeonsi）只导出 `__vaDriverInit_1_20` 符号，与所装 libva 1.17 运行时
ABI 不匹配；同时发现上游 test-client 硬编码 `/dev/dri/card1`（单卡宿主打不开），
本仓库副本已改为 card0。

结论：老旧/混合驱动环境存在真实的 ABI 适配成本，这正是上游项目只声称
「现代 amdgpu / iHD 环境」可用的原因；这不影响该路线在主流硬件上的可行性。

## 五、结论与路线

1. **现阶段（v3.9.2）**：软件解码是容器化安卓的正常且唯一工作方式，
   GPU 已用于唯一能用的加速项（渲染）；不引入实验性组件，保证稳定性。
2. **跟踪**：redroid-hwenc 项目的 Codec2 组件成型后（含 Intel/AMD 解码后端），
   以「可选插件包」形式接入——安装时探测 GPU 厂商（VAAPI 入口检测）→
   下载对应插件 → 挂载注入容器 → 失败自动回退软解，不影响任何现有功能。
3. **不做**：将实验性组件打进锁定的上游镜像本体（违反稳定性约束）。
