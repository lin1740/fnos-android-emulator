#!/bin/bash
### check_abi_apps.sh — 列出「只有 32 位 ARM 库」的已安装应用
###
### 【为什么需要】
### x86 设备上跑安卓靠翻译层（libndk_translation）。翻译层只接管通过 classloader
### 命名空间加载的库；国内不少应用（微信、京东等）的 32 位包会用**绝对路径 dlopen**
### 自己的 armeabi-v7a 库，这条路绕不到翻译层，于是启动即崩：
###   dlopen failed: ... is for EM_ARM (40) instead of EM_386 (3)
### 这不是权限/缓存问题，装 64 位（arm64-v8a）包才能绕开。
###
### 本脚本只**读**、不改任何东西：把已安装的第三方应用按主 ABI 分类，
### 输出到 var/abi_report.txt，供用户与排查时对照（安装向导里也指向这个文件）。
###
### 用法：
###   check_abi_apps.sh            生成/更新报告
###   check_abi_apps.sh --quiet    仅在发现 32 位应用时写日志（供开机巡检调用）
set +e

C="${ANDROIDEMU_CONTAINER:-androidemu-android}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
OUT="$VAR_DIR/abi_report.txt"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

mkdir -p "$VAR_DIR" 2>/dev/null || true

[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ] || exit 0
[ "$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')" = "1" ] || exit 0

### 一次 dumpsys 拿全部包信息，在**宿主侧**解析。
### （踩坑记录：把 awk 写进 docker exec 的双引号里，$1 会被容器内 shell 二次展开，
###   曾经因此把 1316 个正常文件全判成异常。）
TMPD="$(mktemp /tmp/abi_dump.XXXXXX 2>/dev/null)" || exit 0
trap 'rm -f "$TMPD" 2>/dev/null' EXIT

docker exec -u 0 "$C" sh -c 'dumpsys package 2>/dev/null' > "$TMPD" 2>/dev/null
[ -s "$TMPD" ] || exit 0

### 第三方应用清单（排除系统包，避免报告噪音）
docker exec -u 0 "$C" sh -c 'pm list packages -3 2>/dev/null' 2>/dev/null \
    | sed 's/^package://' | tr -d '\r' | sort > "$TMPD.third" 2>/dev/null

### 解析：Package [name] 之后的 primaryCpuAbi / secondaryCpuAbi
awk -v third="$TMPD.third" '
BEGIN {
    while ((getline line < third) > 0) { keep[line] = 1 }
    close(third)
    n = 0
}
/^[[:space:]]*Package \[/ {
    pkg = $0
    sub(/.*Package \[/, "", pkg); sub(/\].*/, "", pkg)
    cur = pkg; abi = ""; abi2 = ""
    next
}
/primaryCpuAbi=/ {
    if (cur != "") { v = $0; sub(/.*primaryCpuAbi=/, "", v); sub(/[[:space:]].*/, "", v); abi = v }
}
/secondaryCpuAbi=/ {
    if (cur != "") { v = $0; sub(/.*secondaryCpuAbi=/, "", v); sub(/[[:space:]].*/, "", v); abi2 = v }
}
/^[[:space:]]*versionName=/ {
    if (cur != "" && keep[cur] == 1 && abi != "") {
        rows[cur] = abi "\t" abi2
        n++
    }
    cur = ""
}
END {
    for (p in rows) print p "\t" rows[p]
}
' "$TMPD" 2>/dev/null | sort > "$TMPD.rows" 2>/dev/null

TOTAL=$(wc -l < "$TMPD.rows" 2>/dev/null | tr -d ' ')
case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac

### 只有 32 位 ARM：主 ABI 是 armeabi*，且没有 arm64 作为次 ABI
awk -F'\t' '($2 ~ /^armeabi/) && ($3 !~ /arm64/) { print $1 }' "$TMPD.rows" 2>/dev/null > "$TMPD.only32"
N32=$(wc -l < "$TMPD.only32" 2>/dev/null | tr -d ' ')
case "$N32" in ''|*[!0-9]*) N32=0 ;; esac

{
    echo "# 应用 ABI 检测报告"
    echo "# 生成时间：$(date '+%F %T')"
    echo "# 说明：主 ABI 为 armeabi-v7a/armeabi 且无 arm64-v8a 的应用，在 x86 设备上"
    echo "#       可能因翻译层不接管绝对路径 dlopen 而启动失败（报 EM_ARM instead of EM_386）。"
    echo "#       处理办法：优先到应用官网/应用商店下载 64 位（arm64-v8a）版本安装包。"
    echo
    echo "第三方应用总数：$TOTAL"
    echo "仅 32 位 ARM 的应用数：$N32"
    echo
    if [ "$N32" -gt 0 ]; then
        echo "## 仅 32 位 ARM（建议换 64 位版本）"
        while IFS= read -r _p; do
            [ -n "$_p" ] || continue
            echo "  - $_p"
        done < "$TMPD.only32"
        echo
    fi
    echo "## 全部第三方应用与主 ABI"
    awk -F'\t' '{ printf "  %-46s %s%s\n", $1, ($2 == "" ? "(未取到)" : $2), ($3 == "" ? "" : "  [次:" $3 "]") }' "$TMPD.rows" 2>/dev/null
} > "$OUT" 2>/dev/null

### 先把 32 位清单读进变量，再清理临时文件（否则下面引用已删除的文件）
ONLY32_LIST="$(cat "$TMPD.only32" 2>/dev/null)"

if [ "$QUIET" = "1" ]; then
    [ "$N32" -gt 0 ] && echo "[$(date '+%F %T')] abi: 检测到 $N32 个仅 32 位 ARM 的应用（详见 $OUT）"
else
    echo "已生成报告：$OUT"
    echo "第三方应用 $TOTAL 个，其中仅 32 位 ARM $N32 个"
    [ -n "$ONLY32_LIST" ] && echo "$ONLY32_LIST" | sed 's/^/  - /'
    true
fi

rm -f "$TMPD.third" "$TMPD.rows" "$TMPD.only32" 2>/dev/null
exit 0
