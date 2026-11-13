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
_HAVE_SZ=$(stat -c %s "$HOUDINI_DIR/lib64/libhoudini.so" 2>/dev/null || echo 0)
if [ "$_HAVE_SZ" -gt 5000000 ] 2>/dev/null; then
    echo "download_houdini: libhoudini 已存在（$_HAVE_SZ bytes，校验通过），跳过下载"
    exit 0
fi
# 不存在或为坏产物（<5MB，如历史 26B stub）——清掉重下
[ "$_HAVE_SZ" -gt 0 ] 2>/dev/null && { echo "download_houdini: 检测到坏产物（$_HAVE_SZ bytes），重新下载"; rm -rf "$HOUDINI_DIR/lib64" "$HOUDINI_DIR/bin" "$HOUDINI_DIR/lib"; }

ANDROID_VER="${ANDROIDEMU_ANDROID_VER:-}"
if [ -z "$ANDROID_VER" ]; then
    RT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$RT_DIR/rtconf.sh" ]; then
        # shellcheck disable=SC1091
        . "$RT_DIR/rtconf.sh"; rtconf_load
    fi
    ANDROID_VER="${ANDROID_VER:-12}"
fi
_detected_ver="$(docker exec "${CNAME:-androidemu-android}" getprop ro.build.version.release 2>/dev/null | tr -d '\r\n')"
case "$_detected_ver" in ''|*[!0-9]*) : ;; *) ANDROID_VER="$_detected_ver" ;; esac

echo "download_houdini: 开始下载 Intel libhoudini (Android ${ANDROID_VER} 兼容版)..."

### 下载源列表（按优先级）：3.9.2 重建下载链（v3，实测验证）
### 源头考古：原主源 supremeful/houdini 仓库已删除；Android-x86 官方 dl 站不可用；
###   Cyosai 归档包是 Android 9 接口版，装到 Android 12 zygote 报符号缺失
###   （android_get_application_target_sdk_version）——实测不可用，仅保留垫底。
### 新主源：supremegamers/vendor_intel_proprietary_houdini（104★，Bliss/Android-x86
###   社区官方 blob 仓库，按 Android 版本分支维护，接口适配正确）：
###     Android 12（默认）→ hpe 分支；13 → wsa-13；14 → hpe-14；10/11/15/16 → 就近 hpe
###   codeload 整包 tarball（约 150-250MB，一次性；auto 模式仅在名单/崩溃触发时下载）。
_SGM_BRANCH="hpe"
case "$ANDROID_VER" in
    13) _SGM_BRANCH="wsa-13" ;;
    14) _SGM_BRANCH="hpe-14" ;;
    12|12.1|12L) _SGM_BRANCH="hpe" ;;
    *) _SGM_BRANCH="hpe" ;;   # 10/11/15/16 就近取 hpe（接口 v2 起跨版本兼容性良好）
esac
_SG="https://codeload.github.com/supremegamers/vendor_intel_proprietary_houdini/tar.gz/refs/heads/${_SGM_BRANCH}"
HOUDINI_TAG="v${ANDROID_VER}.0.0"
HOUDINI_ASSET="houdini-${ANDROID_VER}.0.0-android${ANDROID_VER}.tar.gz"
_SU="https://github.com/supremeful/houdini/releases/download/${HOUDINI_TAG}/${HOUDINI_ASSET}"
_AR="https://github.com/Cyosai/libhoudini-UnofficialArchive/releases/download/Ninth-series/houdini_9.0.5a_y+z.51068.zip"
echo "download_houdini: 源分支=${_SGM_BRANCH}（Android ${ANDROID_VER}），整包约 150-250MB，请耐心等待"
_dl_speed() {  # $1=完整URL，返回下载速度（字节/秒，失败输出 0）
    ### 8MB 样本、12 秒上限：1MB 太小，缓存命中会给出虚高速度，选源必错。
    curl -s -o /dev/null -m 12 -r 0-8388607 -w '%{speed_download}' "$1" 2>/dev/null \
        || echo 0
}
### 3.9.9 实测（2026-11-13，各拉 8MB，样本足够排除缓存假象）：
###   可用：gh-proxy.com 200 / 134KB/s；直连 codeload 200 / 18KB/s
###   失效：ghfast.top 403、ghproxy.net 403、gh.llkk.cc 000、ghp.ci 000、moeyy 000、
###         gh.api.99988866.xyz 000、ghproxy.cc 000、gh-proxy.net 302、
###         hub.gitmirror.com 000、gh.6yit.com 000、ghp.arislee.top 000、
###         gh-proxy.top 000、ghps.cc 404
### 失效源已全部移除，只留「代理」与「直连」两条真实可用的路，别再逐个空耗超时。
_probe_urls=(
    "https://gh-proxy.com/${_SG}"
    "${_SG}"
)
_p1=$(_dl_speed "${_probe_urls[0]}")
_p2=$(_dl_speed "${_probe_urls[1]}")
case "$_p1$_p2" in ''|*[!0-9.]*) _p1=${_p1:-0}; _p2=${_p2:-0} ;; esac
echo "download_houdini: 测速 代理=${_p1%%.*}B/s 直连=${_p2%%.*}B/s"
if [ "$(awk -v a="$_p1" -v b="$_p2" 'BEGIN{print (a>=b)?1:0}')" = "1" ]; then
    DOWNLOAD_URLS=("https://gh-proxy.com/${_SG}" "${_SG}" "https://gh-proxy.com/${_AR}")
else
    DOWNLOAD_URLS=("${_SG}" "https://gh-proxy.com/${_SG}" "https://gh-proxy.com/${_AR}")
fi
echo "download_houdini: 首选 ${DOWNLOAD_URLS[0]}（共 ${#DOWNLOAD_URLS[@]} 条候选）"


TMP_DIR="$(mktemp -d)"
TMP_FILE="${TMP_DIR}/houdini.pkg"
DOWNLOAD_OK=0

# _dl_one <url>：断点续传拉一个大文件到完整（同源最多 4 轮，每轮上限 30 分钟）。
# 实测教训：SGM 整包约 250MB，慢速网络（180KB/s）下单次 max-time 600 只能拉
# ~100MB 就被切断 —— 必须 -C - 续传直至 gzip/zip 魔数出现且大小不再增长。
_dl_one() {
    local url="$1" round prev
    for round in 1 2 3 4; do
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 15 --max-time 1800 -C - -o "$TMP_FILE" "$url" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 --tries=1 -c -O "$TMP_FILE" "$url" 2>/dev/null
        else
            return 1
        fi
        # 完整性：魔数正确即视为下完（续传对齐前提下服务器会正确续 206）
        local mg sz
        mg=$(head -c 2 "$TMP_FILE" 2>/dev/null | od -An -tx1 | tr -d ' \n')
        sz=$(stat -c %s "$TMP_FILE" 2>/dev/null || echo 0)
        case "$mg" in 504b|1f8b) [ "$sz" -gt 1000000 ] 2>/dev/null && return 0 ;; esac
        # 未达标：若大小没变（源坏了）换下一源；否则继续续传
        [ "$sz" = "$prev" ] && return 1
        prev="$sz"
    done
    return 1
}

for url in "${DOWNLOAD_URLS[@]}"; do
    echo "  尝试: $url"
    rm -f "$TMP_FILE"   # 换源从零开始（同源多轮续传由 _dl_one 保留文件）
    if _dl_one "$url"; then DOWNLOAD_OK=1; break; fi
    echo "  失败，尝试下一个源..."
done

if [ "$DOWNLOAD_OK" != "1" ]; then
    echo "download_houdini: 所有下载源均失败"
    echo "  若处于晚间时段（约 19:00~24:00），可能是链路拥塞所致，可稍后重试；也可手动下载后放入上述路径。"
    echo "  请手动下载 libhoudini 并放入:"
    echo "    64位: $HOUDINI_DIR/lib64/libhoudini.so"
    echo "    32位: $HOUDINI_DIR/lib/libhoudini.so"
    echo "  或从 Android-x86 / BlissOS 镜像中提取"
    rm -rf "$TMP_DIR"
    exit 1
fi

### 校验下载文件（zip "PK" 或 gzip 1f8b 魔数；新归档源是 zip，旧源是 tar.gz）
_MG=$(head -c 2 "$TMP_FILE" 2>/dev/null | od -An -tx1 | tr -d ' \n')
case "$_MG" in
    504b) PKGFMT=zip ;;
    1f8b) PKGFMT=tgz ;;
    *) echo "download_houdini: 下载文件损坏（magic=$_MG），清理"; rm -rf "$TMP_DIR"; exit 1 ;;
esac

### 完整性硬校验：tgz 走 tar 全列表（gzip CRC，截断包必挂）；zip 走 unzip -t
### 实测教训：codeload 截断包能"部分解压"出目录结构与 26 字节坏文件，静默产出假产物。
if [ "$PKGFMT" = "tgz" ]; then
    if ! tar -tzf "$TMP_FILE" >/dev/null 2>&1; then
        echo "download_houdini: 包未下完整（tar 校验失败），清理重试"; rm -rf "$TMP_DIR"; exit 1
    fi
else
    _zip_ok=1
    if command -v unzip >/dev/null 2>&1; then
        unzip -qq -t "$TMP_FILE" >/dev/null 2>&1 || _zip_ok=0
    else
        python3 - "$TMP_FILE" <<'ZPY' || _zip_ok=0
import sys, zipfile
bad = zipfile.ZipFile(sys.argv[1]).testzip()
sys.exit(1 if bad else 0)
ZPY
    fi
    if [ "$_zip_ok" != "1" ]; then
        echo "download_houdini: zip 校验失败，清理"; rm -rf "$TMP_DIR"; exit 1
    fi
fi

echo "download_houdini: 下载成功（$PKGFMT），解压中..."

### 解压并整理文件结构（按魔数分派）
if [ "$PKGFMT" = "tgz" ]; then
    tar -xzf "$TMP_FILE" -C "$TMP_DIR" 2>/dev/null
else
    if command -v unzip >/dev/null 2>&1; then
        unzip -qq -o "$TMP_FILE" -d "$TMP_DIR" 2>/dev/null
    else
        python3 -m zipfile -e "$TMP_FILE" "$TMP_DIR" 2>/dev/null || python3 - "$TMP_FILE" "$TMP_DIR" <<'ZPY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
ZPY
    fi
fi

### 查找解压后的 libhoudini.so
### 三种包布局：
###   A) supremegamers blob 仓库（新主源）：prebuilts/lib64/libhoudini.so + prebuilts/bin/
###      houdini{,64} + bin/{arm,arm64}/linker{,64} + prebuilts/lib/{arm,arm64}/（双 ARM 库集）
###   B) supremeful tar.gz（历史）：根下 lib64/libhoudini.so + lib/libhoudini.so
###   C) Android-x86 归档 zip（垫底）：system/arm64/...（Android 9 接口版）
_PREB="$(find "$TMP_DIR" -maxdepth 3 -type d -name prebuilts 2>/dev/null | head -1)"
if [ -n "$_PREB" ] && [ -f "$_PREB/lib64/libhoudini.so" ]; then
    ### 布局 A：完整产品化安装（含 32/64 双 ARM 库集与 linker）
    ### 产物硬门槛（实测教训：曾装出 26 字节坏 bridge / 缺 houdini64 的假产物）：
    ###   bridge ≥5MB、houdini64 ≥3MB、arm64 集 ≥300 .so —— 不达标按失败处理。
    _BR_SZ=$(stat -c %s "$_PREB/lib64/libhoudini.so" 2>/dev/null || echo 0)
    _TR_SZ=$(stat -c %s "$_PREB/bin/houdini64" 2>/dev/null || echo 0)
    _A64_N=$(find "$_PREB/lib64/arm64" -name '*.so' 2>/dev/null | wc -l)
    _A32_N=$(find "$_PREB/lib/arm" -name '*.so' 2>/dev/null | wc -l)
    if [ "$_BR_SZ" -lt 5000000 ] 2>/dev/null || [ "$_TR_SZ" -lt 3000000 ] 2>/dev/null || [ "$_A64_N" -lt 300 ] 2>/dev/null || [ "$_A32_N" -lt 300 ] 2>/dev/null; then
        echo "download_houdini: 包内容不完整（bridge=$_BR_SZ 翻译器=$_TR_SZ arm64集=$_A64_N arm32集=$_A32_N），清理退出"
        rm -rf "$TMP_DIR" "$HOUDINI_DIR/lib64" "$HOUDINI_DIR/bin" "$HOUDINI_DIR/lib"; exit 1
    fi
    mkdir -p "$HOUDINI_DIR/bin/arm" "$HOUDINI_DIR/bin/arm64" "$HOUDINI_DIR/lib64/arm64" "$HOUDINI_DIR/lib/arm" 2>/dev/null || true
    rm -rf "$HOUDINI_DIR/lib64/libhoudini.so" "$HOUDINI_DIR/bin/houdini" "$HOUDINI_DIR/bin/houdini64"
    cp "$_PREB/lib64/libhoudini.so" "$HOUDINI_DIR/lib64/libhoudini.so"
    for b in houdini houdini64; do
        [ -f "$_PREB/bin/$b" ] && cp "$_PREB/bin/$b" "$HOUDINI_DIR/bin/$b"
    done
    [ -f "$_PREB/bin/arm/linker" ] && cp "$_PREB/bin/arm/linker" "$HOUDINI_DIR/bin/arm/linker"
    [ -f "$_PREB/bin/arm64/linker64" ] && cp "$_PREB/bin/arm64/linker64" "$HOUDINI_DIR/bin/arm64/linker64"
    rm -rf "$HOUDINI_DIR/lib64/arm64" "$HOUDINI_DIR/lib/arm"
    cp -a "$_PREB/lib64/arm64" "$HOUDINI_DIR/lib64/arm64" 2>/dev/null
    cp -a "$_PREB/lib/arm" "$HOUDINI_DIR/lib/arm" 2>/dev/null
    echo "  64位 bridge: 已安装 ($(stat -c%s "$HOUDINI_DIR/lib64/libhoudini.so" 2>/dev/null || echo '?') bytes)"
    echo "  翻译器: bin/houdini$( [ -f "$HOUDINI_DIR/bin/houdini64" ] && echo -n ' + bin/houdini64' )$( [ -f "$HOUDINI_DIR/bin/arm64/linker64" ] && echo -n ' + linkers' )"
    echo "  ARM64 库集: $(find "$HOUDINI_DIR/lib64/arm64" -name '*.so' 2>/dev/null | wc -l) 个 .so | ARM32 库集: $(find "$HOUDINI_DIR/lib/arm" -name '*.so' 2>/dev/null | wc -l) 个 .so"
    rm -rf "$TMP_DIR"
    echo "download_houdini: 完成！libhoudini 已安装到 $HOUDINI_DIR"
    echo "  设置 ANDROIDEMU_TRANSLATION=houdini 或 auto 即可启用"
    exit 0
fi

HOUDINI64_FOUND="$(find "$TMP_DIR" -path "*lib64/libhoudini.so" -size +1M 2>/dev/null | head -1)"
[ -z "$HOUDINI64_FOUND" ] && HOUDINI64_FOUND="$(find "$TMP_DIR" -path "*/system/arm64/libhoudini.so" -size +1M 2>/dev/null | head -1)"
HOUDINI32_FOUND="$(find "$TMP_DIR" -path "*/lib/libhoudini.so" -size +1M 2>/dev/null | head -1)"
[ -z "$HOUDINI64_FOUND" ] && HOUDINI64_FOUND="$(find "$TMP_DIR" -name "libhoudini.so" -size +1M 2>/dev/null | head -1)"

### 布局 C 的三件套（bin 翻译器 + arm64 库集）
_SYSROOT="$(find "$TMP_DIR" -type d -name system 2>/dev/null | head -1)"
mkdir -p "$HOUDINI_DIR/bin" "$HOUDINI_DIR/lib64/arm64" 2>/dev/null || true
if [ -n "$_SYSROOT" ]; then
    [ -f "$_SYSROOT/bin/houdini64" ] && cp "$_SYSROOT/bin/houdini64" "$HOUDINI_DIR/bin/" 2>/dev/null
    [ -f "$_SYSROOT/bin/houdini" ] && cp "$_SYSROOT/bin/houdini" "$HOUDINI_DIR/bin/" 2>/dev/null
    _ARMSET="$(dirname "$(find "$_SYSROOT/arm64" -name libart.so 2>/dev/null | head -1)" 2>/dev/null)"
    if [ -n "$_ARMSET" ] && [ -d "$_ARMSET" ]; then
        cp -a "$_ARMSET/." "$HOUDINI_DIR/lib64/arm64/" 2>/dev/null
        echo "  ARM 库集: 已安装 ($(find "$HOUDINI_DIR/lib64/arm64" -name '*.so' 2>/dev/null | wc -l) 个 .so)"
    fi
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
