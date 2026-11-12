#!/bin/bash
### 3.9.1：桌面图标占位（"包名 + 安卓小人"）自愈。
### 根因（实测）：/data 为宿主 bind mount 时，pm install 落盘的 base.apk 权限是 0700
### （属主为安装当时的 app uid）。Launcher3 是另一个 uid，读不到该 APK，
### logcat 报 "Failed to open APK ... I/O error"，于是所有图标退化为占位图。
### 处理：仅在检测到「有 APK 非 other 可读」时才动手 —— 修正权限、清图标缓存、重启桌面。
### 幂等且零开销：权限正常时直接退出（每 5 分钟最多检查一次）。
set +e
C=androidemu-android
VAR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
### 3.9.2 热修：标记文件可能是早期系统身份流程建的（0:0 644），普通用户写不了 →
### 节流失效、每轮巡检都跑一遍。不可写就退到临时目录。
_ae_wpath(){ # $1=文件名，输出一个可写的路径
    local n="$1" fb="${TMPDIR:-/tmp}/androidemu_$(id -u)"
    if [ -d "$VAR" ] && [ -w "$VAR" ] && { [ ! -e "$VAR/$n" ] || [ -w "$VAR/$n" ]; }; then
        printf '%s\n' "$VAR/$n"
    else
        mkdir -p "$fb" 2>/dev/null
        printf '%s\n' "$fb/$n"
    fi
}
STAMP=$(_ae_wpath icons_fix.stamp)
_log(){ echo "[$(date '+%F %T')] fix_app_icons: $*"; }

# 节流：5 分钟内已检查过则跳过
_now=$(date +%s); _last=$(stat -c %Y "$STAMP" 2>/dev/null || echo 0)
[ $((_now - _last)) -lt 300 ] && exit 0

docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null | grep -q true || exit 0
MP=$(docker inspect "$C" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
[ -z "$MP" ] && exit 0
[ -d "$MP/app" ] || exit 0

mkdir -p "$VAR" 2>/dev/null; : > "$STAMP" 2>/dev/null

BAD=$(find "$MP/app" -type f -name '*.apk' ! -perm -o+r 2>/dev/null | head -1)
[ -z "$BAD" ] && exit 0

_log "检测到 APK 权限异常（示例: $(basename "$(dirname "$BAD")")），开始修正"
find "$MP/app" -mindepth 1 -type d -exec chmod 0771 {} + 2>/dev/null
chmod 0771 "$MP/app" 2>/dev/null
find "$MP/app" -type f \( -name '*.apk' -o -name '*.so' -o -name '*.odex' -o -name '*.vdex' -o -name '*.art' \) -exec chmod 0644 {} + 2>/dev/null
rm -rf "$MP"/app/vmdl*.tmp 2>/dev/null

# 只在修正时清图标缓存并重启桌面（避免每次开机重建拖慢桌面首次渲染）
docker exec -u 0 "$C" sh -c "am force-stop com.android.launcher3" >/dev/null 2>&1
rm -f "$MP/data/com.android.launcher3/databases/app_icons.db"* 2>/dev/null
docker exec -u 0 "$C" sh -c "am start -n com.android.launcher3/.uioverrides.QuickstepLauncher" >/dev/null 2>&1
_log "已修正 $(find "$MP/app" -type f -name '*.apk' 2>/dev/null | wc -l) 个 APK 权限并重建图标缓存"
