#!/bin/bash
### 复现构建 app/hwenc/bin/daemon-hwdec（x86_64，fnOS / Debian 12）
###
### 背景：上游 redroid-hwenc v0.2.0 自带通用硬件解码（5.15，hwdec.c），但它不是
### release tarball 里的产物，而是 daemon 的编译开关 HAVE_HWDEC。本包此前只用
### `make`（HWDEC=0）编了 daemon，硬解能力因此没被编进去。
###
### 产物与原有 bin/daemon 并存；默认仍跑旧的只编码 daemon，硬解通过
### `hwenc_ctl.sh decode on` 手动开启（失败自动回退，不影响现有编码链路）。
###
### 不需要 root：dev 头文件用 apt-get download + dpkg-deb -x 解到临时目录。
### 目标机器与构建机同为 Debian 12 用户态，libavcodec.so.59 / libavutil.so.57
### 为系统自带（实测 0 未解析），所以采用动态链，二进制仅 ~72KB。
set -eu

SRC="${1:-$(cd "$(dirname "$0")/../androidemu_all_3.9.9/app/hwenc" 2>/dev/null && pwd)}"
[ -f "$SRC/daemon.c" ] || { echo "找不到 hwenc 源码：$SRC"; exit 1; }
OUT="${2:-$SRC/bin/daemon-hwdec}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/debs" "$WORK/sysroot" "$WORK/src"

echo "==> 取 dev 头文件（不装系统包）"
( cd "$WORK/debs" && apt-get download libavcodec-dev libavutil-dev libgbm-dev )
for d in "$WORK"/debs/*.deb; do dpkg-deb -x "$d" "$WORK/sysroot"; done

INC="-I$WORK/sysroot/usr/include/x86_64-linux-gnu -I$WORK/sysroot/usr/include"
[ -f "$WORK/sysroot/usr/include/x86_64-linux-gnu/libavcodec/avcodec.h" ] || {
    echo "缺 libavcodec 头文件"; exit 1; }

echo "==> 编译（-DHAVE_HWDEC）"
gcc -O2 -Wall -D_FORTIFY_SOURCE=0 -DHAVE_HWDEC \
    -DAV_PROFILE_H264_CONSTRAINED_BASELINE=FF_PROFILE_H264_CONSTRAINED_BASELINE \
    $INC $(pkg-config --cflags libdrm 2>/dev/null) \
    -o "$OUT" \
    "$SRC/daemon.c" "$SRC/decode_h264.c" "$SRC/hwdec.c" "$SRC/ffmpeg_encode.c" \
    -lavcodec -lavutil -lva -lva-drm -lgbm -lEGL -ldl -lm -lpthread
strip "$OUT"
chmod 755 "$OUT"

echo "==> 产物"
ls -lh "$OUT"
_MISSING=$(ldd "$OUT" 2>/dev/null | grep -c "not found" || true)
echo "未解析依赖: ${_MISSING:-0}"
strings "$OUT" | grep -m1 "hwdec: session open" || { echo "缺少硬解标记"; exit 1; }
echo "完成。把该文件放到 app/hwenc/bin/ 后重新打包 fpk（包内需保留 0755）。"
