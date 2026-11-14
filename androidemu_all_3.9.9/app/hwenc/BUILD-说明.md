# 视频硬编解码实验组件（redroid-hwenc）构建与状态说明

> **实验组件，默认不启用。** 本目录是上游开源项目 redroid-hwenc
> （github.com/fogelmanjg/redroid-hwenc，Apache-2.0）v0.2.0 的产物与源码。
> 用户在安装向导中选择「启用」时才会部署；未启用时不影响应用任何正常功能。

## 一、这是什么

一个跑在**宿主侧**（普通 glibc 进程、普通用户身份）的守护 daemon：安卓侧的
Codec2 组件通过 AF_UNIX 套接字（`/dev/vaapi-helper/socket`）把画面 dma-buf 发给它，
由它调用宿主 GPU 的 VAAPI 完成硬件编码后回传。

上游已真机验证：
- **硬件编码**：scrcpy 经正式框架路径录制硬件 H.264，在 AMD Renoir、AMD RX 480、
  Intel Iris Xe 三台真机全流水线通过；
- **硬件解码（v0.2.0 / 5.15）**：`hwdec.c` 走 libavcodec + VA-API，AMD/Intel 通用，
  向 Android 侧提供 h264/hevc/vp9 解码，能力不足时由调用方回落软件解码；
- **硬件解码（Tier 7）**：NVDEC 经 VA-API，GTX 1050 Ti 与软解逐位一致（NVIDIA 专用路径）。

> **3.9.9 更正**：本文件早期写的是「Intel/AMD 的解码后端尚未实现」，那是 v0.1.0
> 的结论，v0.2.0 已经补上。能力在源码里，但**必须用 `make HWDEC=1` 编译 daemon**
> 才会带进去（`HWDEC ?= 0` 是默认值）；且 `media_codecs.xml` 要登记 `<Decoders>`。
> 本包此前发布时两点都没做，所以实际只跑硬编 —— 详见 `scripts/hwenc_ctl.sh decode`。

## 二、目录内容

| 路径 | 说明 |
|---|---|
| `artifacts/android11-hidl/` | v0.2.0 的 HIDL 变体产物（Android 11/12/13 通用），15 个文件 |
| `bin/daemon` | 宿主 VA-API 编码 daemon（x86_64 预编译，普通用户运行） |
| `daemon.c` / `decode_h264.c` / `ffmpeg_encode.c` / `hwdec.c` | v0.2.0 完整源码 |
| `Makefile` | 构建入口（`make` = legacy 后端；`make HWDEC=1` = 加 ffmpeg 后端） |
| `artifacts/.../apex-swcodec-lib64/libion.so` | 上游补丁版 libion，**本项目不注入**（见"已知坑"） |
| `artifacts/.../system-lib64/libion.so` | 同上，不注入 |

## 三、注入位置（只动 /vendor）

`scripts/hwenc_ctl.sh enable` 执行：

1. `chmod 666 /dev/dma_heap/system`（容器内，兼容部分内核组合）
2. `bin/hw/android.hardware.media.c2@1.1-vaapi-service` → `/vendor/bin/hw/`
3. `lib64/*.so` → `/vendor/lib64/`
4. `etc/init/*.rc`、`etc/vintf/manifest/*.xml`、`etc/seccomp_policy/*` → 对应目录
5. 在 `/vendor/etc/media_codecs.xml` 的 `<Encoders>` 登记
   `c2.hardware.encoder.h264`（`size max=1920x1088`）
6. `setprop ctl.restart hwservicemanager`（重读 VINTF，否则注册被拒）
7. 以普通用户启动 daemon，socket 走容器共享卷 + `/dev/vaapi-helper` 软链接
8. 设 `debug.stagefright.ccodec=4` 并在 media 启动窗口内触发列表构建

**不注入 `/system` 与 `/apex` 的 libion** —— 实测在 Android 12 上替换这两处会让
软件编码器 `c2.android.avc.encoder` 直接失败（`fetch linear block err = 14`）。
只保留 `/vendor` 那一份（HIDL 服务自身依赖闭包需要它）。

## 四、daemon 重新编译

```sh
sudo apt-get install -y libva-dev libdrm-dev libegl1-mesa-dev gcc make pkg-config
# libgbm-dev 若与系统 Mesa 版本冲突，用 apt-get download + dpkg-deb -x 取 gbm.h/gbm.pc
# Vulkan Video 头（vk_video/*.h）Debian 12 的 libvulkan-dev 未提供，
# 需从 KhronosGroup/Vulkan-Headers 的 include/vk_video/ 取 5 个文件
make            # legacy 后端（AMD 用这个）
make HWDEC=1    # 额外编入 ffmpeg 后端（Intel 必须）
```

**Intel 必须用 ffmpeg 后端**，否则码流畸形、ffprobe 每帧报 `Overread SPS by 3 bits`：
编译 `make HWDEC=1` + 运行 `REDROID_FORGE_ENCODE_BACKEND=ffmpeg`。
**AMD 一律用 legacy**（Polaris 用 ffmpeg 后端会 GPU hang）。

### 3.9.9 实际交付状态（重要）

本包里长期只放了 `make`（`HWDEC=0`）编出来的 `bin/daemon`，所以：
- 只跑硬编，v0.2.0 的 5.15 通用硬解（`hwdec.c`）没编进去；
- Intel 机器仍在用 legacy 后端，正是上面那段「码流畸形」的场景，也是
  部分机器投屏卡顿的成因之一。

现在改为**两个二进制并存**，默认行为完全不变：

| 文件 | 编译方式 | 用途 |
|---|---|---|
| `bin/daemon` | `make`（HWDEC=0） | 默认，纯硬编，AMD 用 |
| `bin/daemon-hwdec` | `-DHAVE_HWDEC`，链 libavcodec/libavutil | `hwenc_ctl.sh decode on` 时启用，带硬解；Intel 同时自动切 ffmpeg 编码后端 |

`daemon-hwdec` 在 Debian 12（fnOS 同一用户态）上编译，命令：

```sh
apt-get download libavcodec-dev libavutil-dev libgbm-dev   # 不要 root
for d in *.deb; do dpkg-deb -x "$d" sysroot; done
gcc -O2 -Wall -D_FORTIFY_SOURCE=0 -DHAVE_HWDEC \
    -DAV_PROFILE_H264_CONSTRAINED_BASELINE=FF_PROFILE_H264_CONSTRAINED_BASELINE \
    -Isysroot/usr/include/x86_64-linux-gnu -Isysroot/usr/include \
    $(pkg-config --cflags libdrm) \
    -o daemon-hwdec daemon.c decode_h264.c hwdec.c ffmpeg_encode.c \
    -lavcodec -lavutil -lva -lva-drm -lgbm -lEGL -ldl -lm -lpthread
```

`AV_PROFILE_*` 那个宏是 FFmpeg 7 → Debian 12 的 FFmpeg 5.1 兼容桥接。
产物 72KB，动态依赖 libavcodec.so.59 / libavutil.so.57（fnOS 系统自带，实测 0 未解析）。
静态链需要额外补大量 `-dev` 符号链接，收益不大，未采用。

`decode on` 会在 `media_codecs.xml` 的 `<Decoders>` 登记
`c2.hardware.decoder.{h264,hevc,vp9}`（组件二进制里本来就有），
`decode off` 走 disable→enable 还原。**默认关闭**：硬解接错会黑屏/花屏，
必须在有可用 VA-API 的机器上验证出图后才能建议用户开启。

## 五、实测数据（2026-11-09，AMD A8-7500 / Kaveri / VCE 2.0 / Android 12）

| 分辨率 | 结果 | 帧数 |
|---|---|---|
| 1920x1080 | 成功（硬件，daemon 编码） | 78 |
| 1920x1088 | 成功 | 71 |
| 1600x900 / 1440x1088 / 1088x1088 | 成功 | 25~38 |
| 1280x720 / 640x480 | 成功 | 16~36 |
| 1080x2340（手机） | 硬件拒绝（vaCreateContext），切软件编码 | — |
| 720x1280 / 1088x1920 / 1920x1200 | 同上，高度超 1088 | — |

硬件上限：**宽 ≤1920 且 高 ≤1088**（与总像素无关）。

## 六、已知坑（改动前必读）

1. `debug.stagefright.ccodec` 在 media 重启后会被系统重置为 1（实测约 7~19 秒）。
   **MediaCodecList 只在 media 启动后的早期窗口内构建一次**，所以设 4 之后必须在
   8 秒左右补设并立即 `dumpsys media.player` 触发构建，抢在重置之前。
   列表一旦按 4 构建好，之后属性变 1 也不影响已缓存的列表。
2. `ccodec=1` 是安全状态（软件编码），`0` 是 OMX。唯独媒体栈在反复重启后
   可能出现 dumpsys 超时，脚本里因此做了整体失败回退。
3. 组件自己声明的尺寸能力偏大，`media_codecs.xml` 的 `<Limit>` 管不住
   MediaCodecList 的选择 —— 超限分辨率仍会选中硬件编码器然后失败。
   所以必须按当前分辨率切换 ccodec（`hwenc_ctl.sh resync`）。
4. 宿主 socket 不能用 `nsenter -m -- mount --bind` 打通（会在容器 ns 里自己绑自己），
   要用 `REDROID_FORGE_VAAPI_SOCKET` 指向容器共享卷 + 容器内软链接。
5. daemon 必须用 `setsid -f` 启动，否则会话结束会被回收。

## 七、开关与回退

```sh
bash scripts/hwenc_ctl.sh status    # 查看状态
bash scripts/hwenc_ctl.sh enable    # 启用（含前置检测与失败回退）
bash scripts/hwenc_ctl.sh disable   # 撤注入、停 daemon、ccodec 回 1
bash scripts/hwenc_ctl.sh resync    # 分辨率变化后按需切换
bash scripts/hwenc_ctl.sh repair    # 容器重建后恢复（boot_guard 自动调用）
```

容器重启后注入保留（容器读写层），但 `ccodec` 与 `dma_heap` 恢复默认；
`boot_guard` 检测到状态为 enabled 会自动 repair（每 300 秒一次）。
