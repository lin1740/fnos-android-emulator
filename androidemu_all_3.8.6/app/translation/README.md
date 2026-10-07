# 翻译层目录

## 说明
本目录用于存放可选的ARM翻译层，支持在x86_64设备上运行ARM应用。

## ndk（默认）
容器内已内置Google libndk_translation，无需额外文件。
- 优点：稳定，redroid官方默认
- 缺点：不支持ARMv8.1+指令，部分新应用（如使用Go 1.16+的应用）可能SIGILL崩溃

## houdini（可选）
Intel libhoudini翻译层，对较新ARM指令支持更好。
- 优点：支持ARMv8.1+指令，兼容性更好
- 缺点：体积较大，可能不如ndk稳定

### 如何获取houdini
1. 从Android-x86或BlissOS镜像中提取
2. 或从可信第三方来源下载
3. 将libhoudini.so及依赖库放入对应目录：
   - 64位库：houdini/lib64/
   - 32位库：houdini/lib/

### 如何启用
在飞牛应用中心的环境变量中设置：
ANDROIDEMU_TRANSLATION=houdini

然后重启应用即可。
