#!/bin/bash
### fix_audio_codec.sh — 兼容外壳（3.0.3 起）
###
### 《权限说明》5.2 节点名的脚本：在 redroid 容器内注册 c2.android.opus.encoder（仅容器内、
### 幂等、可逆）。旧版为 bash + 容器内 sed 实现；3.0.3 起改由 scripts/androidemu_daemon.sh 实现
### （Python 直接读写 XML，不依赖容器内 sed 方言）。
set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
exec bash "$APP_DIR/scripts/androidemu_daemon.sh" fix
