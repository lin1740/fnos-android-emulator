#!/bin/bash
### fix_audio_codec.sh — 兼容外壳（3.8.9 修复版）
###
### 在 redroid 容器内启用 Codec2 并注册 c2.android.opus.encoder（仅容器内、幂等、可逆）。
set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
exec python3 "$APP_DIR/server/audio_fix.py" fix
