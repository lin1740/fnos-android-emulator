# androidemu · 1.0.25 源文件（迭代存档）

> **项目一句话**：fnOS 的 Android 模拟器。包含本地 Android 容器和 Chuanyun Screen Casting（穿云投屏）。可作为 Docker 镜像和 SFPK 安装器提供。

> ⚠️ **本目录是 1.0.25 早期迭代存档，仅作技术研究与参考；它不是 fnOS 应用中心的正式/最新版本。**
> 其完整性、稳定性与安全性无法得到完全保障，且相对较新版本存在更多已知风险。
> **请先阅读本目录《免责声明.md》**；正式版本请以 fnOS 应用中心为准。

## 目录结构
- `manifest` / `cmd/` / `config/` / `wizard/`：fnOS 包元数据与生命周期脚本
- `app/`：应用负载（docker 编排、拉取/GPU 脚本、面板 UI、LICENSE、应用介绍）
- 配套安装包 `androidemu_1.0.25.fpk` 与其校验文件在上级目录
  （`androidemu_1.0.25.fpk` / `androidemu_1.0.25.fpk.sha256`）

## 重打包（如需复现）
1. 用 fnOS 官方 `fnpack`：`fnpack build --directory <本目录>`
2. 打包前确认 `manifest` 中 `version = 1.0.25` 保持一致；
3. 本目录根部的 `README.md`、`免责声明.md` 不影响打包（fnpack 已验证可正常构建）。

## 常见使用问题
- 安装前先装 `binder_linux` 驱动；镜像拉取失败请配置 registry-mirrors；
- 默认画面账号 `admin / admin123`，**首次登录后立即修改**；
- 画面页**不要开启音频**（该版无音频输出设备，开启可能导致断连）；
- 其它已知风险与防御措施见《免责声明.md》。
