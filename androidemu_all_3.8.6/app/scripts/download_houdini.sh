#!/bin/bash
### download_houdini.sh — 自动下载 Intel libhoudini ARM翻译层（3.8.3新增）
###
### 功能：
###   1. 检查 app/translation/houdini/ 目录是否已有 libhoudini.so
###   2. 如无，自动从可信来源下载并解压
###   3. 支持多个镜像源，自动重试
###   4. 下载后校验文件完整性
###
### 用法：bash download_houdini.sh [houdini目录路径]
###
### 注意：libhoudini 是 Intel 专有软件，本脚本仅用于用户自行下载，
###       不内置在安装包中。使用需遵守 Intel 许可协议。

set -u

HOUDINI_DIR="${1:-}"
if [ -z "$HOUDINI_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    HOUDINI_DIR="${SCRIPT_DIR}/../translation/houdini"
fi
mkdir -p "$HOUDINI_DIR/lib64" "$HOUDINI_DIR/lib" 2>/dev/null || true

### 已存在则跳过
if [ -f "$HOUDINI_DIR/lib64/libhoudini.so" ] || [ -f "$HOUDINI_DIR/lib/libhoudini.so" ]; then
    echo "download_houdini: libhoudini 已存在，跳过下载"
    exit 0
fi

echo "download_houdini: 开始下载 Intel libhoudini (Android 12 兼容版)..."

### 下载源列表（按优先级）
### 来源说明：
###   1. GitHub supremeful/houdini - 社区维护的各版本houdini集合
###   2. ghproxy 镜像 - 国内加速
###   3. 备用源
DOWNLOAD_URLS=(
    "https://github.com/supremeful/houdini/releases/download/v12.0.0/houdini-12.0.0-android12.tar.gz"
    "https://ghproxy.com/https://github.com/supremeful/houdini/releases/download/v12.0.0/houdini-12.0.0-android12.tar.gz"
    "https://mirror.ghproxy.com/https://github.com/supremeful/houdini/releases/download/v12.0.0/houdini-12.0.0-android12.tar.gz"
)

TMP_DIR="$(mktemp -d)"
TMP_FILE="${TMP_DIR}/houdini.tar.gz"
DOWNLOAD_OK=0

for url in "${DOWNLOAD_URLS[@]}"; do
    echo "  尝试: $url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 120 -o "$TMP_FILE" "$url" 2>/dev/null && DOWNLOAD_OK=1 && break
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --tries=1 -O "$TMP_FILE" "$url" 2>/dev/null && DOWNLOAD_OK=1 && break
    fi
    echo "  失败，尝试下一个源..."
done

if [ "$DOWNLOAD_OK" != "1" ]; then
    echo "download_houdini: 所有下载源均失败"
    echo "  请手动下载 libhoudini 并放入:"
    echo "    64位: $HOUDINI_DIR/lib64/libhoudini.so"
    echo "    32位: $HOUDINI_DIR/lib/libhoudini.so"
    echo "  或从 Android-x86 / BlissOS 镜像中提取"
    rm -rf "$TMP_DIR"
    exit 1
fi

### 校验下载文件（非空且是tar.gz）
if [ ! -s "$TMP_FILE" ] || ! tar -tzf "$TMP_FILE" >/dev/null 2>&1; then
    echo "download_houdini: 下载文件损坏，清理"
    rm -rf "$TMP_DIR"
    exit 1
fi

echo "download_houdini: 下载成功，解压中..."

### 解压并整理文件结构
tar -xzf "$TMP_FILE" -C "$TMP_DIR" 2>/dev/null

### 查找解压后的 libhoudini.so
HOUDINI64_FOUND="$(find "$TMP_DIR" -name "libhoudini.so" -path "*lib64*" 2>/dev/null | head -1)"
HOUDINI32_FOUND="$(find "$TMP_DIR" -name "libhoudini.so" -path "*lib/*" 2>/dev/null | head -1)"

### 如果没找到带lib64/lib路径的，尝试直接找
if [ -z "$HOUDINI64_FOUND" ]; then
    HOUDINI64_FOUND="$(find "$TMP_DIR" -name "libhoudini.so" -size +1M 2>/dev/null | head -1)"
fi

if [ -n "$HOUDINI64_FOUND" ]; then
    cp "$HOUDINI64_FOUND" "$HOUDINI_DIR/lib64/libhoudini.so"
    echo "  64位: 已安装 ($(stat -c%s "$HOUDINI_DIR/lib64/libhoudini.so" 2>/dev/null || echo '?') bytes)"
fi

if [ -n "$HOUDINI32_FOUND" ]; then
    cp "$HOUDINI32_FOUND" "$HOUDINI_DIR/lib/libhoudini.so"
    echo "  32位: 已安装 ($(stat -c%s "$HOUDINI_DIR/lib/libhoudini.so" 2>/dev/null || echo '?') bytes)"
fi

### 复制其他依赖库（如果有）
for lib in "$TMP_DIR"/*/lib64/*.so "$TMP_DIR"/lib64/*.so; do
    [ -f "$lib" ] && [ "$(basename "$lib")" != "libhoudini.so" ] && cp "$lib" "$HOUDINI_DIR/lib64/" 2>/dev/null || true
done
for lib in "$TMP_DIR"/*/lib/*.so "$TMP_DIR"/lib/*.so; do
    [ -f "$lib" ] && [ "$(basename "$lib")" != "libhoudini.so" ] && cp "$lib" "$HOUDINI_DIR/lib/" 2>/dev/null || true
done

rm -rf "$TMP_DIR"

if [ -f "$HOUDINI_DIR/lib64/libhoudini.so" ] || [ -f "$HOUDINI_DIR/lib/libhoudini.so" ]; then
    echo "download_houdini: 完成！libhoudini 已安装到 $HOUDINI_DIR"
    echo "  设置 ANDROIDEMU_TRANSLATION=houdini 或 auto 即可启用"
    exit 0
else
    echo "download_houdini: 解压后未找到 libhoudini.so"
    exit 1
fi
