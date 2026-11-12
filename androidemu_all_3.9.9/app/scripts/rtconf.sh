#!/bin/bash
### rtconf.sh — 统一加载「运行时版本配置」（单一可信源）
###
### 目的：镜像名/版本号只在一处维护（app/docker/runtime.conf），其它脚本一律从这里取，
###       避免把版本写死在多处 —— 这是"以后要支持 Android 9~16 任选、穿云投屏按 digest 随包锁定"
###       的前提（换版本只改一个文件，不用改代码）。
###
### 用法：
###   . /path/to/rtconf.sh   然后调用 rtconf_load        # 在脚本里（推荐）
###   bash rtconf.sh show                                # 打印当前生效值
###
### 查找顺序：$ANDROIDEMU_RUNTIME_CONF → $TRIM_APPDEST/docker/runtime.conf →
###           与本脚本同级的 ../docker/runtime.conf
### 找不到配置文件时使用与 runtime.conf 相同的默认值（行为与历史一致）。

rtconf_file(){
    for _c in "${ANDROIDEMU_RUNTIME_CONF:-}" \
              "${TRIM_APPDEST:-/var/apps/androidemu/target}/docker/runtime.conf" \
              "$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" 2>/dev/null && pwd)/runtime.conf"; do
        [ -n "${_c:-}" ] && [ -f "$_c" ] && { printf '%s' "$_c"; return 0; }
    done
    return 1
}

rtconf_load(){
    _rt_f="$(rtconf_file)" || _rt_f=""
    if [ -n "$_rt_f" ]; then
        # shellcheck disable=SC1090
        . "$_rt_f"
    else
        # 兜底默认（与 app/docker/runtime.conf 完全一致；配置文件缺失时行为不变）
        ANDROID_VER="${ANDROIDEMU_ANDROID_VER:-12}"
        REDROID_REPO="${ANDROIDEMU_REDROID_REPO:-redroid/redroid}"
        REDROID_TAG="${ANDROIDEMU_REDROID_TAG:-${ANDROID_VER}.0.0-latest}"
        WEBRTC_REPO="${ANDROIDEMU_WEBRTC_REPO:-buutuu/scrcpy-over-webrtc}"
        WEBRTC_TAG="${ANDROIDEMU_WEBRTC_TAG:-latest}"
        ACCEL_PREFIX="${ANDROIDEMU_ACCEL_PREFIX:-docker.fnnas.com}"
        CACHE_PREFIX="${ANDROIDEMU_CACHE_PREFIX:-androidemu-cache}"
        GMS_IMAGE_BASE="${GMS_IMAGE_BASE:-ghcr.io/lin1740/androidemu-gms}"
        CANON_REDROID="${ACCEL_PREFIX}/${REDROID_REPO}:${REDROID_TAG}"
        OFF_REDROID="${REDROID_REPO}:${REDROID_TAG}"
        CANON_WEBRTC="${ACCEL_PREFIX}/${WEBRTC_REPO}:${WEBRTC_TAG}"
        OFF_WEBRTC="${WEBRTC_REPO}:${WEBRTC_TAG}"
        CACHE_REDROID="${CACHE_PREFIX}/redroid:${ANDROID_VER}"
        CACHE_WEBRTC="${CACHE_PREFIX}/webrtc:${WEBRTC_TAG}"
        WEBRTC_DIGEST="${ANDROIDEMU_WEBRTC_DIGEST:-sha256:dc6e62393e0e490c79410d8b41ef32896f7a384b97077e4b5cfb9804a4bb2cdd}"
    fi
    ### 派生值兜底（配置文件若被裁剪掉派生段也不会空）
    : "${CANON_REDROID:=${ACCEL_PREFIX}/${REDROID_REPO}:${REDROID_TAG}}"
    : "${OFF_REDROID:=${REDROID_REPO}:${REDROID_TAG}}"
    : "${CANON_WEBRTC:=${ACCEL_PREFIX}/${WEBRTC_REPO}:${WEBRTC_TAG}}"
    : "${OFF_WEBRTC:=${WEBRTC_REPO}:${WEBRTC_TAG}}"
    : "${CACHE_REDROID:=${CACHE_PREFIX}/redroid:${ANDROID_VER}}"
    : "${CACHE_WEBRTC:=${CACHE_PREFIX}/webrtc:${WEBRTC_TAG}}"
    : "${WEBRTC_DIGEST:=}"
    ### digest 锁定引用（与 runtime.conf 派生段一致；digest 非空时 compose/拉取用它）
    if [ -n "${WEBRTC_DIGEST:-}" ]; then
        CANON_WEBRTC_REF="${CANON_WEBRTC%:*}@${WEBRTC_DIGEST}"
        OFF_WEBRTC_REF="${OFF_WEBRTC%:*}@${WEBRTC_DIGEST}"
    else
        CANON_WEBRTC_REF="$CANON_WEBRTC"
        OFF_WEBRTC_REF="$OFF_WEBRTC"
    fi
    export ANDROID_VER REDROID_REPO REDROID_TAG WEBRTC_REPO WEBRTC_TAG WEBRTC_DIGEST ACCEL_PREFIX \
           CACHE_PREFIX GMS_IMAGE_BASE CANON_REDROID OFF_REDROID CANON_WEBRTC OFF_WEBRTC \
           CANON_WEBRTC_REF OFF_WEBRTC_REF CACHE_REDROID CACHE_WEBRTC
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    case "${1:-show}" in
        show|"")
            rtconf_load
            echo "配置来源       : $(rtconf_file || echo '（未找到 runtime.conf，使用内置默认）')"
            echo "ANDROID_VER    : $ANDROID_VER"
            echo "安卓容器镜像   : $CANON_REDROID   （别名 $OFF_REDROID）"
            echo "穿云投屏镜像   : $CANON_WEBRTC_REF   （别名 $OFF_WEBRTC_REF；digest 锁定，上游 latest 更新不影响已装用户）"
            echo "升级缓存标签   : $CACHE_REDROID / $CACHE_WEBRTC"
            echo "GMS 载体镜像   : $GMS_IMAGE_BASE"
            ;;
        *) echo "用法：$0 [show]"; exit 1 ;;
    esac
fi
