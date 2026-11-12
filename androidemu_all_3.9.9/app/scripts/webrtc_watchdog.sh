#!/bin/bash
### webrtc_watchdog.sh — 确保穿云投屏画面服务始终可用。
###
set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"
PIDFILE="$VAR_DIR/webrtc_watchdog.pid"
LOGFILE="$VAR_DIR/webrtc_watchdog.log"
INTERVAL="${WEBRTC_WATCH_INTERVAL:-30}"
### 2.0.51：容器名变量必须定义（此前 helper 里用了 $C 但脚本未定义 → set -u 报 unbound variable）
C="${WEBRTC_NAME:-androidemu-webrtc}"
RECREATE_STAMP="$VAR_DIR/webrtc_recreate.stamp"

### 3.9.9：同 boot_guard —— 长驻守护不能依赖启动时的工作目录（应用目录被替换后
### 会变成 (deleted)，子进程一律报 getcwd 失败）。
cd / 2>/dev/null || true

mkdir -p "$VAR_DIR" 2>/dev/null || true

### 日志可写性探测：不可写就回退 /tmp（属主为系统账号时包用户无法追加）
if [ -f "$LOGFILE" ] && [ ! -w "$LOGFILE" ]; then
    LOGFILE="/tmp/androidemu-webrtc-watchdog.log"
fi
if ! ( : >> "$LOGFILE" ) 2>/dev/null; then
    LOGFILE="/tmp/androidemu-webrtc-watchdog.log"
fi

if [ ! -r "$COMPOSE" ]; then resolve_compose || true; fi

P_WEB="8443"
if [ -f "$VAR_DIR/ports.conf" ]; then
    _v=$(sed -n 's/^WEB_PORT=//p' "$VAR_DIR/ports.conf" 2>/dev/null | head -n1)
    case "$_v" in ''|*[!0-9]*) : ;; *) P_WEB="$_v" ;; esac
fi

log(){ echo "[$(date '+%F %T')] $*" 2>/dev/null >> "$LOGFILE" 2>/dev/null || true; }
alive(){ [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }
listening(){ ss -lntp 2>/dev/null | grep -q ":$P_WEB "; }

resolve_compose(){
    _f=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$C" 2>/dev/null | tr ',' '\n' | head -n1)
    case "$_f" in
        /*) [ -f "$_f" ] && COMPOSE="$_f" && return 0 ;;
    esac
    return 1
}

kill_stale(){
    for _p in $(ps -eo pid,args 2>/dev/null | grep -F "$0 supervise" | grep -v grep | awk '{print $1}'); do
        [ "$_p" = "$$" ] && continue
        kill -9 "$_p" 2>/dev/null || true
    done
}

### 2.0.50：容器必须带上 DEFAULT_SETTINGS（音频等默认值靠它注入）。
### 实测事故：compose 里有该项，但容器 env 里根本没有 → 前端回落到写死的 audio:false → 没声音。
webrtc_env_dump(){ docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$C" 2>/dev/null; }
env_has_audio(){ webrtc_env_dump | grep -q '^DEFAULT_SETTINGS=.*"audio":true'; }
env_has_awake(){ webrtc_env_dump | grep -q '^DEFAULT_SETTINGS=.*"stayAwake":true'; }

GPU_FALLBACK_MARK="$VAR_DIR/gpu_fallback.done"
ANDROID_C="${REDROID_NAME:-androidemu-android}"
ANDROID_START_STAMP="$VAR_DIR/android_restart.stamp"
ensure_android(){
    _running=$(docker inspect -f '{{.State.Running}}' "$ANDROID_C" 2>/dev/null)
    [ "$_running" = "true" ] && return 0
    ### 3.9.2 修正（「停用」失效的真因）：容器**存在但已停止** = 用户在应用中心停用
    ### 或手动 docker stop。此前的 `docker start` 会把它拉回来，实测停用后 45 秒
    ### 容器又开始运行、8443 重新可访问，用户以为没停成功，审核也会判停用功能异常。
    ### 崩溃重启由 compose 的 restart: unless-stopped 负责，不依赖这里。
    if docker inspect "$ANDROID_C" >/dev/null 2>&1; then
        _st=$(docker inspect -f '{{.State.Status}}' "$ANDROID_C" 2>/dev/null)
        case "$_st" in
            exited|created|dead)
                log "安卓容器处于 ${_st}（应用已停用/手动停止），不自动拉起"
                return 0
                ;;
        esac
    fi
    _now=$(date +%s); _last=0
    [ -f "$ANDROID_START_STAMP" ] && _last=$(cat "$ANDROID_START_STAMP" 2>/dev/null || echo 0)
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    if [ $((_now - _last)) -lt 60 ]; then return 0; fi
    echo "$_now" > "$ANDROID_START_STAMP" 2>/dev/null || true
    log "安卓容器 $ANDROID_C 未运行（可能被 OOM 终止），尝试拉起"
    if docker start "$ANDROID_C" >/dev/null 2>&1; then
        log "安卓容器已拉起（docker start）"
    else
        ( cd "$(dirname "$COMPOSE")" 2>/dev/null && docker compose -p androidemu up -d redroid ) >>"$LOGFILE" 2>&1 \
            && log "安卓容器已拉起（compose up -d redroid）" \
            || log "安卓容器拉起失败，等待下轮重试"
    fi
}
gpu_fallback_check(){
    if [ -f "$APP_DIR/scripts/boot_guard.sh" ]; then
        bash "$APP_DIR/scripts/boot_guard.sh" once >>"$LOGFILE" 2>&1 || true
    fi
    return 0
}
### 3.3.8：修复 TURN 监听地址 — entrypoint.sh 生成的 turnserver.conf 不含 listening-ip，
### coturn 自动发现接口时只监听 docker 网桥（172.19.0.1），导致局域网/外网都无法连接 TURN。
### 必须 sed 注入 listening-ip=0.0.0.0 后杀掉 coturn 重启（HUP 不生效）。
fix_turn_listening(){
    docker exec "$C" sh -c '
        grep -q "^listening-ip=0.0.0.0" /etc/coturn/turnserver.conf 2>/dev/null || {
            sed -i "/^listening-port/a listening-ip=0.0.0.0" /etc/coturn/turnserver.conf
            killall turnserver 2>/dev/null
            sleep 2
            nohup turnserver -c /etc/coturn/turnserver.conf >/tmp/turn_watchdog.log 2>&1 &
            sleep 2
            echo "turn listening fixed"
        }
    ' 2>/dev/null || true
}

### 3.9.9：端口持续不通的观察窗口（秒）。
### 为什么要观察而不是立刻重建：飞牛停用是「先停画面服务、后停安卓」，停用全过程
### 最长可达 40~60 秒；这期间画面服务已收 SIGTERM（但 docker inspect 的 State.Status
### 仍是 running，端口已不监听），安卓也还在 running —— 单看这两项任何一项都不足以
### 判定「用户停用」，于是旧逻辑会走「端口未监听 → 重建」，把刚停掉的服务又拉回来。
### 用「端口持续不通满 60 秒」+「每轮复核停用信号」两层过滤，正常停用一定在此之前结束。
DOWN_SETTLE="${WEBRTC_DOWN_SETTLE:-90}"
WEB_DOWN_STAMP="$VAR_DIR/.web_down_since"

### 用户停用信号（唯一判定入口，重建前会再复核一次）：
###   ① 画面服务是「优雅退出」（ExitCode=143）且发生在 10 分钟内 —— docker stop 的特征，
###      崩溃/被杀的退出码是 137/139/1/0，不会命中；
###   ② 安卓容器已处于 exited/created/dead —— compose 停用的终点，只要走到这里就说明
###      用户点了停用（或手动 docker stop）。
user_stop_signal(){
    if docker inspect "$C" >/dev/null 2>&1; then
        _wst=$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null)
        case "$_wst" in
            exited|created|dead)
                _wcode=$(docker inspect -f '{{.State.ExitCode}}' "$C" 2>/dev/null | tr -d '\r\n')
                _wfin=$(docker inspect -f '{{.State.FinishedAt}}' "$C" 2>/dev/null | cut -c1-19 | tr 'T' ' ')
                _wts=$(date -u -d "$_wfin UTC" +%s 2>/dev/null || echo 0)
                case "$_wts" in ''|*[!0-9]*) _wts=0 ;; esac
                if [ "$_wcode" = "143" ] && [ "$_wts" -gt 0 ] && [ $(( $(date +%s) - _wts )) -lt 600 ]; then
                    return 0
                fi
                ;;
        esac
    fi
    _ast=$(docker inspect -f '{{.State.Status}}' "$ANDROID_C" 2>/dev/null)
    case "$_ast" in
        exited|created|dead) return 0 ;;
    esac
    return 1
}

### 安卓容器是否刚启动（120 秒内）——刚重建的容器画面服务还在初始化，
### 此时端口不通属于正常过程，不该判定为故障去重建。
android_just_started(){
    _st=$(docker inspect -f '{{.State.StartedAt}}' "$ANDROID_C" 2>/dev/null)
    [ -n "$_st" ] || return 1
    _ts=$(date -d "$_st" +%s 2>/dev/null || echo 0)
    case "$_ts" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_ts" -gt 0 ] || return 1
    [ $(( $(date +%s) - _ts )) -lt 120 ]
}

### 3.9.9：升级 / 重装窗口判定。
### 飞牛升级的顺序是「替换应用文件 → docker-project down/pull/up → 调 upgrade_callback」。
### 在 down 之后、up 之前，容器是「不存在」状态；旧逻辑会把这当成「容器丢了」立刻
### compose up 补建 —— 而 compose 用的是固定 container_name，于是飞牛随后的 up
### 直接报 `container name "/androidemu-webrtc" is already in use`，整个升级失败
### （2026-11-08 12:55 实测，升级界面弹「无法更新 androidemu」）。
### 判定信号：应用文件（manifest / 本脚本 / compose）最近 PKG_FRESH_WINDOW 秒内被替换过。
### 正常运行期间这些文件的 mtime 不会变，所以不会误伤崩溃自愈；升级结束
### （upgrade_callback 会重新拉起守护）后窗口自然过期。
PKG_FRESH_WINDOW="${AE_PKG_FRESH_WINDOW:-300}"
pkg_files_fresh(){
    if [ -f "$VAR_DIR/.upgrade_window" ]; then
        ### upgrade_init 留下的显式标记，优先级最高（时间戳由 upgrade_init 写在 系统身份下）
        _uw=$(cat "$VAR_DIR/.upgrade_window" 2>/dev/null || echo "")
        case "$_uw" in
            ''|*[!0-9]*) : ;;
            *) [ $(( $(date +%s) - _uw )) -lt 1800 ] && return 0 ;;
        esac
    fi
    _pnow=$(date +%s)
    for _pf in "$APP_DIR/manifest" "$APP_DIR/scripts/webrtc_watchdog.sh" "$APP_DIR/docker/docker-compose.yaml"; do
        [ -f "$_pf" ] || continue
        _pm=$(stat -c %Y "$_pf" 2>/dev/null || echo 0)
        case "$_pm" in ''|*[!0-9]*) continue ;; esac
        [ "$_pm" -gt 0 ] || continue
        [ $(( _pnow - _pm )) -lt "$PKG_FRESH_WINDOW" ] && return 0
    done
    return 1
}

### 一次性自检：端口没在听就重建（清冲突 + up -d webrtc）
ensure_once(){
    ### 3.9.9：升级/重装窗口内绝不补建、不重建（原因见 pkg_files_fresh 注释）
    if pkg_files_fresh; then
        log "应用文件最近 ${PKG_FRESH_WINDOW}s 内被替换（升级/重装窗口）→ 本轮不拉起、不重建"
        rm -f "$WEB_DOWN_STAMP" 2>/dev/null || true
        return 0
    fi
    ### 3.9.8/3.9.9：停用判定见 user_stop_signal()。命中即整轮退出：
    ### 已残留的画面服务一并停掉（否则等于没停），并清掉观察计时。
    if user_stop_signal; then
        if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]; then
            log "应用已停用（画面服务退出或安卓容器已停），但画面服务仍在运行 → 一并停止"
            docker stop "$C" >/dev/null 2>&1 || true
        else
            log "画面服务刚被优雅停止（exit 143，用户停用中）→ 本轮不拉起，也不重建"
        fi
        rm -f "$WEB_DOWN_STAMP" 2>/dev/null || true
        return 0
    fi
    ensure_android
    gpu_fallback_check
    fix_turn_listening
    if listening; then
        rm -f "$WEB_DOWN_STAMP" 2>/dev/null || true
        log "画面端口 :$P_WEB 已在监听，服务正常，无需处理"
        return 0
    fi
    ### 3.9.9：端口不通先记录时刻、观察一轮，不在第一时间重建（原因见 DOWN_SETTLE 注释）
    _wnow=$(date +%s)
    _dws=$(cat "$WEB_DOWN_STAMP" 2>/dev/null || echo "")
    case "$_dws" in
        ''|*[!0-9]*)
            echo "$_wnow" > "$WEB_DOWN_STAMP" 2>/dev/null || true
            log "画面端口 :$P_WEB 未监听 → 记录时刻，先观察（窗口 ${DOWN_SETTLE}s），避免与停用/重建流程抢跑"
            return 0
            ;;
    esac
    _age=$(( _wnow - _dws ))
    if [ "$_age" -lt "$DOWN_SETTLE" ]; then
        log "画面端口 :$P_WEB 仍未监听 ${_age}s（窗口 ${DOWN_SETTLE}s）→ 继续观察"
        return 0
    fi
    ### 观察窗口过后复核一次：停用信号、或安卓刚重建（画面服务正在初始化）
    if user_stop_signal; then
        rm -f "$WEB_DOWN_STAMP" 2>/dev/null || true
        log "观察窗口过后仍检测到停用信号 → 放弃重建"
        return 0
    fi
    if android_just_started; then
        log "安卓容器 120 秒内刚启动（画面服务初始化中）→ 继续观察，本轮不重建"
        return 0
    fi
    log "画面端口 :$P_WEB 持续未监听 ${_age}s，重建 webrtc 服务"
    for _c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E 'webrtc'); do
        [ "$(docker inspect -f '{{.State.Running}}' "$_c" 2>/dev/null)" = "true" ] || docker rm -f "$_c" 2>/dev/null || true
    done
    ( cd "$(dirname "$COMPOSE")" 2>/dev/null && docker compose -p androidemu up -d webrtc ) >>"$LOGFILE" 2>&1 || true
    rm -f "$WEB_DOWN_STAMP" 2>/dev/null || true
    sleep 5
    listening && { log "重建后端口 :$P_WEB 已监听，恢复成功"; return 0; }
    log "重建后端口仍未监听，等待下轮重试（详见 webrtc 容器日志）"
    return 1
}

supervise(){
    KEEP_AWAKE_LAST=0
    while :; do
        ensure_once
        NOW=$(date +%s)
        if [ $((NOW - KEEP_AWAKE_LAST)) -ge 300 ]; then
            if [ -f "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/keep_awake.sh" ]; then
                bash "${TRIM_APPDEST:-/var/apps/androidemu/target}/scripts/keep_awake.sh" >/dev/null 2>&1 || true
            fi
            KEEP_AWAKE_LAST=$NOW
        fi
        sleep "$INTERVAL"
    done
}

case "${1:-}" in
    ensure) ensure_once ;;
    start)
        kill_stale
        if alive; then log "已在运行（pid $(cat "$PIDFILE")），跳过"; exit 0; fi
        nohup bash "$0" supervise >>"$LOGFILE" 2>&1 &
        echo $! > "$PIDFILE"
        log "webrtc 守护已启动（pid $!，每 ${INTERVAL}s 检查画面端口）"
        ;;
    stop)
        if alive; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
        rm -f "$PIDFILE"
        kill_stale
        log "webrtc 守护已停止"
        ;;
    status)
        if alive; then echo "webrtc 守护: running (pid $(cat "$PIDFILE"))"; else echo "webrtc 守护: not running"; fi
        echo "画面端口 :$P_WEB 监听: $(listening && echo 是 || echo 否)"
        echo "webrtc 容器：$(docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -E 'webrtc' | tr '\n' ';')"
        echo "音频默认值：$(env_has_audio && echo '已开启 (audio:true)' || echo '未开启')"
        echo "保持唤醒：$(env_has_awake && echo '已开启 (stayAwake:true)' || echo '未开启')"
        ;;
    supervise) supervise ;;
    *) echo "用法：$0 {ensure|start|stop|status|supervise}"; exit 1 ;;
esac
exit 0
