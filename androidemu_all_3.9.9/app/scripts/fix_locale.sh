#!/bin/bash
### fix_locale.sh — 强制「简体中文 + 东八区」，幂等、可反复调用（3.9.1）
###
### 为什么单独成脚本：此前这段逻辑散落在 agent_autodeploy 的两处分支里，且**只判断语言
### 不判断时区**——旧数据卷里语言是英文、时区是 UTC 时照样被跳过（x86 实测：界面英文、
### 状态栏显示 UTC 时间）。现在统一收口：语言与时区任一不符就修正并重启一次框架，
### 并由 boot_guard（每次开机）和 agent_autodeploy 都调用，任何启动路径都能收敛。
###
### 用法：
###   fix_locale.sh            # 幂等检查并修正（默认）
###   fix_locale.sh --force    # 忽略冷却与「本次开机已尝试」限制，强制执行
set -u

C="${ANDROIDEMU_CONTAINER:-androidemu-android}"
VAR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
WANT_LOCALE="zh-CN"
WANT_LANG="zh"
WANT_COUNTRY="CN"
WANT_TZ="Asia/Shanghai"
WAIT_TIMEOUT="${FIX_LOCALE_WAIT:-180}"
LOG="$VAR/locale.log"
STATUS="$VAR/locale.status"
mkdir -p "$VAR" 2>/dev/null || true
log(){ echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null; }

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

### 容器必须已开机
docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null | grep -q true || { log "容器未运行，跳过"; exit 0; }
_boot=$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')
[ "$_boot" = "1" ] || { log "尚未开机完成（boot_completed=$_boot），跳过"; exit 0; }

### 现状
_cur_loc=$(docker exec -u 0 "$C" sh -c 'getprop persist.sys.locale' 2>/dev/null | tr -d '\r\n')
_cur_lang=$(docker exec -u 0 "$C" sh -c 'getprop persist.sys.language' 2>/dev/null | tr -d '\r\n')
_cur_ctry=$(docker exec -u 0 "$C" sh -c 'getprop persist.sys.country' 2>/dev/null | tr -d '\r\n')
_cur_tz=$(docker exec -u 0 "$C" sh -c 'getprop persist.sys.timezone' 2>/dev/null | tr -d '\r\n')
_cfg=$(docker exec -u 0 "$C" sh -c 'am get-config 2>/dev/null' 2>/dev/null | tr -d '\r')

_lang_ok=0
case "$_cfg" in *zh-rCN*) _lang_ok=1 ;; esac
### 语言判定以 persist.sys.locale 为准（Android 10+ 只认它；language/country 是旧属性，
### 常常为空 —— 之前要求它们非空，导致本来正确的机器被误判并重启框架，ARM 实测踩到）。
if [ -n "$_cur_loc" ] && [ "$_cur_loc" != "$WANT_LOCALE" ]; then
    _lang_ok=0
fi
_tz_ok=0
[ "$_cur_tz" = "$WANT_TZ" ] && _tz_ok=1

### ── 24 小时制（3.9.1，默认值，语言/时区是否正常都要保证）──
### 只在「首次初始化」时强制写 24；之后用户若自己改成 12 小时制则尊重（不反复覆盖）。
### settings 写入立即生效，不需要重启框架。
_cur_h24=$(docker exec -u 0 "$C" sh -c 'settings get system time_12_24' 2>/dev/null | tr -d '\r\n')
_h24_mark="$VAR/time24.done"
if [ "$_cur_h24" != "24" ]; then
    if [ -f "$_h24_mark" ]; then
        log "时间制式为 ${_cur_h24:-未设置}（用户已自行调整），保留用户选择"
    else
        docker exec -u 0 "$C" sh -c 'settings put system time_12_24 24' 2>/dev/null || true
        _cur_h24=$(docker exec -u 0 "$C" sh -c 'settings get system time_12_24' 2>/dev/null | tr -d '\r\n')
        [ "$_cur_h24" = "24" ] && { date '+%F %T' > "$_h24_mark" 2>/dev/null || true; log "已设为 24 小时制"; }
    fi
else
    [ -f "$_h24_mark" ] || date '+%F %T' > "$_h24_mark" 2>/dev/null || true
fi

write_status(){
    {
        echo "TS=$(date '+%F %T')"
        echo "locale=$_cur_loc language=$_cur_lang country=$_cur_ctry runtime=$([ "$_lang_ok" = "1" ] && echo zh-rCN || echo 非中文)"
        echo "timezone=${_cur_tz:-未设置}"
        echo "time_12_24=${_cur_h24:-未设置}"
        echo "verdict=$1"
    } > "$STATUS" 2>/dev/null || true
}

if [ "$_lang_ok" = "1" ] && [ "$_tz_ok" = "1" ]; then
    log "语言=zh-CN、时区=Asia/Shanghai 均正确，无需处理"
    write_status "正常"
    exit 0
fi

### 防抖：同一次开机内默认只尝试一次（避免反复重启框架）；--force 可绕过
_bootid=$(docker inspect -f '{{.State.StartedAt}}' "$C" 2>/dev/null | tr -d '\r\n')
_mark="$VAR/locale.done"
if [ "$FORCE" = "0" ] && [ -f "$_mark" ] && [ "$(cat "$_mark" 2>/dev/null)" = "$_bootid" ]; then
    log "本次开机已尝试过修正（bootid=$_bootid），跳过以免反复重启框架；如需强制：fix_locale.sh --force"
    write_status "本次开机已尝试，跳过"
    exit 0
fi

log "检测到语言/时区不符（locale=${_cur_loc:-空} language=${_cur_lang:-空} country=${_cur_ctry:-空} tz=${_cur_tz:-空}，运行时=$([ "$_lang_ok" = 1 ] && echo zh-rCN || echo 非中文)）→ 设置并重启框架"
docker exec -u 0 "$C" sh -c "setprop persist.sys.language $WANT_LANG; setprop persist.sys.country $WANT_COUNTRY; setprop persist.sys.locale $WANT_LOCALE; setprop persist.sys.timezone $WANT_TZ" 2>/dev/null || true

### 时间属性有时被 Android 的 time_detector 用网络时区覆盖，先关掉自动时区/自动时间，
### 否则重启后会再次被改回 UTC/本地网络时区（实测反馈的「改完又变」多半来自这里）。
### 24 小时制已在上面统一处理（首次初始化写入，之后尊重用户手动调整）。
docker exec -u 0 "$C" sh -c 'settings put global auto_time_zone 0; settings put global auto_time 0' 2>/dev/null || true

docker exec -u 0 "$C" sh -c 'stop; sleep 2; start' >/dev/null 2>&1 || true
_w=0
while [ "$_w" -lt "$WAIT_TIMEOUT" ]; do
    sleep 5; _w=$((_w+5))
    _cfg=$(docker exec -u 0 "$C" sh -c 'am get-config 2>/dev/null' 2>/dev/null | tr -d '\r')
    _cur_tz=$(docker exec -u 0 "$C" sh -c 'getprop persist.sys.timezone' 2>/dev/null | tr -d '\r\n')
    case "$_cfg" in *zh-rCN*) [ "$_cur_tz" = "$WANT_TZ" ] && break ;; esac
done
_cur_loc=$(docker exec -u 0 "$C" sh -c 'getprop persist.sys.locale' 2>/dev/null | tr -d '\r\n')
_cur_lang=$(docker exec -u 0 "$C" sh -c 'getprop persist.sys.language' 2>/dev/null | tr -d '\r\n')
_cur_ctry=$(docker exec -u 0 "$C" sh -c 'getprop persist.sys.country' 2>/dev/null | tr -d '\r\n')
_lang_ok=0; case "$_cfg" in *zh-rCN*) _lang_ok=1 ;; esac
_tz_ok=0; [ "$_cur_tz" = "$WANT_TZ" ] && _tz_ok=1

echo "$_bootid" > "$_mark" 2>/dev/null || true

if [ "$_lang_ok" = "1" ] && [ "$_tz_ok" = "1" ]; then
    log "修正成功（等待 ${_w}s）：语言=zh-CN，时区=Asia/Shanghai"
    write_status "已修正（等待 ${_w}s）"
    exit 0
fi
log "修正未完全生效（等待 ${_w}s）：运行时=${_cfg} tz=${_cur_tz}；下次开机会按 persist 属性重试"
write_status "修正未完全生效（下次开机重试）"
exit 1
