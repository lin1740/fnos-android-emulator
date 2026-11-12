#!/bin/bash
### set_ports.sh — 安装后调整本应用的对外端口（3.8.9 新增）
###
### 【为什么有这个脚本】
### 升级向导里原本也有一步「端口设置」，但升级时并不需要改端口（只会增加误操作风险），
### 3.8.9 起已从升级向导移除；为了不丢失"改端口"这个能力，改为提供本脚本 +
### 安装向导里的端口设置步骤（首次安装仍可选端口）。更安全：升级不再触碰端口配置，
### 改动端口变成一次显式、可查看、幂等的操作。
###
### 用法：
###   bash set_ports.sh --show                                  # 查看当前端口
###   bash set_ports.sh --web 9443                              # 改画面服务对外端口
###   bash set_ports.sh --turn 3478 --adb 5556                  # 改 TURN 对外 / ADB 转发端口
###   bash set_ports.sh --web 9443 --no-restart                 # 只写配置，稍后生效
###   （可选 --ext N 单独指定对外端口）
###
### 说明（重要）：
###   · 容器内实际监听端口是固定的（画面 8443、TURN 3478、安卓 adb 5555），本脚本改的是
###     「对外通告 / 映射用的端口」与宿主 ADB 转发端口；改完请在路由器 / 穿透工具同步映射。
###   · 幂等：值没变化时不做多余动作；所有改动只落在应用数据目录的 ports.conf。
###   · 不改动安卓数据、镜像与容器数据卷。

set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
CONF="$VAR_DIR/ports.conf"
mkdir -p "$VAR_DIR" 2>/dev/null || true

cur(){ sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n1; }

SHOW=0; NO_RESTART=0; NEW_WEB=""; NEW_TURN=""; NEW_ADB=""; NEW_EXT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --show)       SHOW=1; shift ;;
        --no-restart) NO_RESTART=1; shift ;;
        --web)        NEW_WEB="${2:-}"; shift 2 ;;
        --turn)       NEW_TURN="${2:-}"; shift 2 ;;
        --adb)        NEW_ADB="${2:-}"; shift 2 ;;
        --ext)        NEW_EXT="${2:-}"; shift 2 ;;
        -h|--help)    sed -n '7,16p' "$0"; exit 0 ;;
        *) echo "未知参数：$1（可用：--show / --web N / --turn N / --adb N / --ext N / --no-restart）" >&2; exit 1 ;;
    esac
done

WEB="$(cur WEB_PORT)";  [ -n "$WEB" ]  || WEB=8443
TURN="$(cur TURN_PORT)"; [ -n "$TURN" ] || TURN=3478
ADB="$(cur ADB_PORT)";  [ -n "$ADB" ]  || ADB=5556
EXT="$(cur EXT_PORT)"

if [ "$SHOW" = "1" ]; then
    echo "配置文件        : $CONF"
    echo "画面服务端口    : WEB_PORT=${WEB}"
    echo "TURN 对外端口   : TURN_PORT=${TURN}"
    echo "ADB 转发端口    : ADB_PORT=${ADB}"
    echo "单独指定的对外端口: EXT_PORT=${EXT:-（未设置，默认与画面端口一致）}"
    echo "容器内实际监听  : 画面 8443 / TURN 3478 / 安卓 adb 5555（固定，不随本项变化）"
    exit 0
fi

[ -n "$NEW_WEB" ]  && WEB="$NEW_WEB"
[ -n "$NEW_TURN" ] && TURN="$NEW_TURN"
[ -n "$NEW_ADB" ]  && ADB="$NEW_ADB"
[ -n "$NEW_EXT" ]  && EXT="$NEW_EXT"

for v in "$WEB" "$TURN" "$ADB"; do
    case "$v" in ''|*[!0-9]*) echo "端口必须是数字：$v" >&2; exit 1 ;; esac
    [ "$v" -ge 1 ] && [ "$v" -le 65535 ] || { echo "端口超出范围：$v" >&2; exit 1; }
done
if [ -n "$EXT" ]; then
    case "$EXT" in *[!0-9]*) echo "对外端口必须是数字：$EXT" >&2; exit 1 ;; esac
fi

OLD_WEB="$(cur WEB_PORT)"; OLD_TURN="$(cur TURN_PORT)"; OLD_ADB="$(cur ADB_PORT)"
{
    echo "WEB_PORT=$WEB"
    echo "TURN_PORT=$TURN"
    echo "ADB_PORT=$ADB"
    [ -n "$EXT" ] && echo "EXT_PORT=$EXT"
    echo "UPDATED=$(date '+%F %T')"
} > "$CONF" 2>/dev/null || { echo "无法写入 $CONF" >&2; exit 1; }
echo "已更新端口：画面=$WEB  TURN对外=$TURN  ADB=$ADB${EXT:+  对外=$EXT}"

if [ "$NO_RESTART" = "1" ]; then
    echo "（--no-restart）仅写入配置，稍后由相关服务读取生效"
    exit 0
fi

### 1) 画面服务：net_mode.sh 会按 ports.conf 把对外端口写进 compose 并重建 webrtc 容器
if [ -f "$APP_DIR/scripts/net_mode.sh" ]; then
    if bash "$APP_DIR/scripts/net_mode.sh" >/dev/null 2>&1; then
        echo "画面服务已按新端口重建（数据卷不变）"
    else
        echo "画面服务重建未成功，可在应用中心「重启应用」后生效"
    fi
fi

### 2) ADB 转发：按新端口重启（宿主 socat/python 转发）
if [ -f "$APP_DIR/scripts/redroid_adb_forward.sh" ]; then
    bash "$APP_DIR/scripts/redroid_adb_forward.sh" remove  >/dev/null 2>&1 || true
    if bash "$APP_DIR/scripts/redroid_adb_forward.sh" install >/dev/null 2>&1; then
        echo "ADB 转发已按新端口重启"
    else
        echo "ADB 转发重启未成功（可稍后重试或重启应用）"
    fi
fi

echo "提示：如在路由器 / 穿透工具中做过端口映射，请同步改为新端口。"
exit 0
