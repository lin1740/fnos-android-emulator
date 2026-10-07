#!/bin/bash
### webrtc_watchdog.sh — 确保穿云投屏画面服务始终可用。
###
### 2.0.46 关键修正（x86 实测根因）：webrtc 容器可能被 fnOS 用「另一个 compose 项目名」管理，
### 容器名不是固定的 androidemu-webrtc（实测为 cd7052c4e969_androidemu-webrtc）。若按固定名
### docker inspect 判断，会永远「找不到」→ 反复用 -p androidemu 重建 → 两个 host 网络容器
### 抢 8443/3478 端口 → 互相顶掉 → 表现为画面黑屏又闪一下、公网/穿透时通时断。
### 因此本守护以「画面端口是否在监听」为唯一健康信号：
###   · 端口在听 → 健康，不动；
###   · 端口不在听 → 先清理已退出的 *webrtc* 容器（避免名/端口冲突），再 up -d webrtc。
### 2.0.47：日志文件若不可写（历史原因属主为 root）自动回退到 /tmp，避免 Permission denied。
### 2.0.48：启动前清理所有旧 supervise 实例（历史残留会越积越多；用 ps+kill，不依赖 pkill）。
### 幂等 + PID 互斥；ensure 为一次性自检（供启动脚本调用），start 为后台循环。
### 2.0.68 掉线根因修正：容器 env 缺 audio/stayAwake 时本守护会每轮 --force-recreate，但 compose 文件里
### 本就没有这两个键 —— 重建多少次都补不上，于是每 30~40 秒重建一次画面容器，云手机会话被反复掐断
### （用户侧表现："一会能连、一会掉，退出重进又能连、几秒又掉"；ARM 实测 129 次重建）。现在：
### ① 缺键先补写 compose（保留已有调优值，备份 .bak-defaults），再重建一次；② compose 补不了时不重建；
### ③ 强制重建带 30 分钟冷却戳，彻底杜绝重建死循环。
set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"
PIDFILE="$VAR_DIR/webrtc_watchdog.pid"
LOGFILE="$VAR_DIR/webrtc_watchdog.log"
INTERVAL="${WEBRTC_WATCH_INTERVAL:-30}"
### 2.0.51：容器名变量必须定义（此前 helper 里用了 $C 但脚本未定义 → set -u 报 unbound variable）
C="${WEBRTC_NAME:-androidemu-webrtc}"
### 2.0.68：强制重建冷却戳（杜绝"重建也没用却每轮再重建"的死循环）
RECREATE_STAMP="$VAR_DIR/webrtc_recreate.stamp"

mkdir -p "$VAR_DIR" 2>/dev/null || true

### 日志可写性探测：不可写就回退 /tmp（属主为 root 时包用户无法追加）
if [ -f "$LOGFILE" ] && [ ! -w "$LOGFILE" ]; then
    LOGFILE="/tmp/androidemu-webrtc-watchdog.log"
fi
if ! ( : >> "$LOGFILE" ) 2>/dev/null; then
    LOGFILE="/tmp/androidemu-webrtc-watchdog.log"
fi

### 2.0.68：默认 compose 读不到时改用容器标签里的真实路径（不可读/root 属主的历史安装）
if [ ! -r "$COMPOSE" ]; then resolve_compose || true; fi

P_WEB="8443"
if [ -f "$VAR_DIR/ports.conf" ]; then
    _v=$(sed -n 's/^WEB_PORT=//p' "$VAR_DIR/ports.conf" 2>/dev/null | head -n1)
    case "$_v" in ''|*[!0-9]*) : ;; *) P_WEB="$_v" ;; esac
fi

log(){ echo "[$(date '+%F %T')] $*" 2>/dev/null >> "$LOGFILE" 2>/dev/null || true; }
alive(){ [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }
listening(){ ss -lntp 2>/dev/null | grep -q ":$P_WEB "; }

### 2.0.68：compose 文件解析 —— 优先采用容器标签里记录的真实 compose 文件。
### 历史/异常安装里 $APP_DIR/docker/docker-compose.yaml 可能属主为 root（0600）而不可读写，
### 此时按默认路径判断会得到"文件读不到"的假象；用容器标签可以拿到 docker 真正使用的文件。
resolve_compose(){
    _f=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$C" 2>/dev/null | tr ',' '\n' | head -n1)
    case "$_f" in
        /*) [ -f "$_f" ] && COMPOSE="$_f" && return 0 ;;
    esac
    return 1
}

### 2.0.48：清理所有旧守护实例（stop 只杀 PIDFILE 里那一个，历史残留会越积越多）
kill_stale(){
    for _p in $(ps -eo pid,args 2>/dev/null | grep -F "$0 supervise" | grep -v grep | awk '{print $1}'); do
        [ "$_p" = "$$" ] && continue
        kill -9 "$_p" 2>/dev/null || true
    done
}

### 2.0.50：容器必须带上 DEFAULT_SETTINGS（音频等默认值靠它注入）。
### 实测事故：compose 里有该项，但容器 env 里根本没有 → 前端回落到写死的 audio:false → 没声音。
webrtc_env_dump(){ docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$C" 2>/dev/null; }
env_has_defaults(){ webrtc_env_dump | grep -q '^DEFAULT_SETTINGS='; }
env_has_audio(){ webrtc_env_dump | grep -q '^DEFAULT_SETTINGS=.*"audio":true'; }
env_has_awake(){ webrtc_env_dump | grep -q '^DEFAULT_SETTINGS=.*"stayAwake":true'; }
### 2.0.77：compose 里的 DEFAULT_SETTINGS（帧率/分辨率/码率等）与容器实际 env 对比。
### 调优脚本改了配置但容器还是旧的时，用户会看到"改了不生效、还是卡"；这里检测到不一致
### 就用带冷却的重建让它生效（一个源，不会循环重建）。
compose_defaults(){
    ### 取出 DEFAULT_SETTINGS= 后的原始值（可能带首尾引号）；用 awk -F 避免 sed 引号嵌套
    grep -m1 'DEFAULT_SETTINGS=' "$COMPOSE" 2>/dev/null | awk -F'DEFAULT_SETTINGS=' 'NF>1{print $2}'
}
container_defaults(){ webrtc_env_dump | grep '^DEFAULT_SETTINGS=' | head -n1 | sed 's/^DEFAULT_SETTINGS=//'; }
### 2.0.77：容器 env 里的值会带着 compose 的单引号（YAML 不处理 shell 引号），比较前必须归一化
norm_defaults(){
    ### 去掉可能存在的首尾引号。注意：compose 里写成 DEFAULT_SETTINGS=''{...}'' 时，
    ### docker 会把那对单引号一起放进容器 env，比较前必须归一化。
    ### 这里用 printf 的八进制转义取引号字符，源码里不出现字面引号，避免任何引号嵌套问题。
    local _v="$1" _sq _dq
    _sq=$(printf '\047')
    _dq=$(printf '\042')
    _v="${_v#$_sq}"; _v="${_v%$_sq}"
    _v="${_v#$_dq}"; _v="${_v%$_dq}"
    printf '%s' "$_v"
}

### 2.0.68：compose 里是否已含必要默认键
compose_has_defaults(){
    grep -q '"audio":true' "$COMPOSE" 2>/dev/null && grep -q '"stayAwake":true' "$COMPOSE" 2>/dev/null
}

### 2.0.68：把缺失的默认键补进 compose 文件（保留用户已有调优值）。返回 0=已修改 3=无需修改 2=无法修改。
### 这是掉线死循环的关键修复：以前只重建容器、不改 compose，容器 env 永远补不上 → 每轮都重建 →
### 在线会话每 30~40 秒被掐断一次（ARM 实测 129 次重建，用户侧即"连上一阵又掉"）。
patch_compose_defaults(){
    [ -f "$COMPOSE" ] || return 2
    [ -w "$COMPOSE" ] || return 2
    cp -f "$COMPOSE" "$COMPOSE.bak-defaults" 2>/dev/null || true
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$COMPOSE" <<'PYEOF'
import json, re, sys
p = sys.argv[1]
try:
    s = open(p, encoding="utf-8").read()
except Exception:
    sys.exit(2)
m = re.search(r"DEFAULT_SETTINGS=(['\"])(\{.*?\})\1", s)
if not m:
    sys.exit(2)
try:
    d = json.loads(m.group(2))
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
want = {"maxBitrate": 10, "minBitrate": 2, "fps": 60, "size": 1280, "bitrate": 10,
        "audio": True, "audioSource": "output", "audioDup": True, "audioLowLatency": False,
        "pageAudioMuted": False, "stayAwake": True, "powerOff": False}
ch = False
for k, v in want.items():
    if k not in d:
        d[k] = v
        ch = True
if not ch:
    sys.exit(3)
new = json.dumps(d, separators=(",", ":"))
s = s[:m.start(2)] + new + s[m.end(2):]
try:
    open(p, "w", encoding="utf-8").write(s)
except Exception:
    sys.exit(2)
sys.exit(0)
PYEOF
        return $?
    fi
    compose_has_defaults && return 3
    sed -i 's/"bitrate":10}/"bitrate":10,"audio":true,"audioSource":"output","audioDup":true,"audioLowLatency":false,"pageAudioMuted":false,"stayAwake":true,"powerOff":false}/' "$COMPOSE" 2>/dev/null || return 2
    compose_has_defaults && return 0
    return 2
}

### 2.0.68：带冷却的强制重建（默认 1800 秒内只允许一次）
recreate_webrtc(){
    _now=$(date +%s 2>/dev/null || echo 0)
    _last=0
    [ -f "$RECREATE_STAMP" ] && _last=$(cat "$RECREATE_STAMP" 2>/dev/null || echo 0)
    case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
    _cd="${WEBRTC_RECREATE_COOLDOWN:-1800}"
    if [ "$_now" -gt 0 ] && [ $(( _now - _last )) -lt "$_cd" ]; then
        log "距上次强制重建不足 ${_cd}s，跳过重建（避免循环重建掐断在线会话）"
        return 1
    fi
    echo "$_now" > "$RECREATE_STAMP" 2>/dev/null || true
    ( cd "$(dirname "$COMPOSE")" 2>/dev/null && docker compose -p androidemu up -d --force-recreate webrtc ) >>"$LOGFILE" 2>&1 || true
    sleep 5
    return 0
}

### 2.0.78：GPU 直通的自动回退。能力检测有可能在某些 ARM 机器上"看着满足、容器里却跑不起来"
### （内核给了 DRM 节点，但容器内 EGL/gralloc 起不来）。只要安卓容器日志里出现反复的
### EGL/DRM 失败，就强制回退软件渲染【一次】（写一次性标记，避免反复重建把会话打断）。
GPU_FALLBACK_MARK="$VAR_DIR/gpu_fallback.done"
ANDROID_C="${REDROID_NAME:-androidemu-android}"
gpu_fallback_check(){
    [ -f "$GPU_FALLBACK_MARK" ] && return 0
    _mode=$(sed -n 's/^MODE=//p' "$VAR_DIR/render-mode" 2>/dev/null | head -n1)
    [ "$_mode" = "gpu" ] || return 0
    _bad=$(docker logs "$ANDROID_C" --tail 300 2>&1 | grep -ciE 'no suitable EGLConfig|Failed to open /dev/dri|gralloc.*(fail|error)|drm.*(fail|error)|EGL_BAD' 2>/dev/null)
    case "$_bad" in ''|*[!0-9]*) _bad=0 ;; esac
    [ "$_bad" -ge 3 ] || return 0
    log "检测到 GPU 直通在容器内失败（EGL/DRM 报错 $_bad 处），自动回退软件渲染（只做一次）"
    bash "$APP_DIR/scripts/tune_compose.sh" --force-software "$COMPOSE" >>"$LOGFILE" 2>&1 || true
    echo "$(date '+%F %T')" > "$GPU_FALLBACK_MARK" 2>/dev/null || true
    recreate_webrtc || true
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

### 一次性自检：端口没在听就重建（清冲突 + up -d webrtc）
ensure_once(){
    ### 2.0.78：先做 GPU 失败回退检查（软件渲染下一个 sed 就返回，开销可忽略）
    gpu_fallback_check
    ### 3.3.8：修复 TURN 监听地址（确保公网可达）
    fix_turn_listening
    if listening; then
        log "画面端口 :$P_WEB 已在监听，服务正常，无需处理"
        ### 3.4.2：彻底禁用 DEFAULT_SETTINGS 相关重建（audio:false 被误判为缺失、反复重建掐断投屏）。
        ### 端口在听就直接返回，只保留端口健康检查。
        return 0
    fi
    log "画面端口 :$P_WEB 未监听，重建 webrtc 服务"
    for _c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E 'webrtc'); do
        [ "$(docker inspect -f '{{.State.Running}}' "$_c" 2>/dev/null)" = "true" ] || docker rm -f "$_c" 2>/dev/null || true
    done
    ( cd "$(dirname "$COMPOSE")" 2>/dev/null && docker compose -p androidemu up -d webrtc ) >>"$LOGFILE" 2>&1 || true
    sleep 5
    listening && { log "重建后端口 :$P_WEB 已监听，恢复成功"; return 0; }
    log "重建后端口仍未监听，等待下轮重试（详见 webrtc 容器日志）"
    return 1
}

supervise(){
    while :; do
        ensure_once
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
