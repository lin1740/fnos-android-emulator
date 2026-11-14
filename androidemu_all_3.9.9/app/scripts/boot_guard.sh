#!/bin/bash
### 3.9.9-r2：飞牛看护进程 environ 实测无 PATH，补 /usr/sbin（runuser 所在目录），
### 保证本看护调用护栏 start 等降权分支时不因找不到 runuser 而失败。
case ":${PATH:-}:" in
    *:/usr/sbin:*) ;;
    *) export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/sbin:/sbin" ;;
esac

### boot_guard.sh — 开机卡死诊断与自愈守护（3.8.9 新增）
###
### 【它解决什么问题】（群友实测反馈：容器 Up，但 sys.boot_completed 永远为空）
###   ① compose 设了 androidboot.console=0（3.3.6 为减少性能损耗关闭串口控制台），
###      因此 Android 的启动日志**不会进入 `docker logs`**（实测 0 字节、0 行）。
###      用户按常规 `docker logs androidemu-android | grep error` 只能看到一片空白，
###      真实日志只在容器内 `logcat`——本守护把诊断写进 boot_diag.status，便于取证。
###   ② 原 webrtc_watchdog 里的「GPU 直通失败自动回退」grep 的正是 docker logs，
###      恒为空 → 该检测**永远不会触发**；且它回退后重建的是 webrtc 容器（改的却是
###      redroid 的 compose）→ 重建错了容器。本守护统一接管：用容器内 logcat 取证，
###      回退后重建 **redroid** 容器。
###   ③ fix_gpu_perms.sh 只在安装流程里跑一次，错过窗口（容器还没起/崩溃还没发生）
###      就不再补救；本守护持续巡检。
###
### 【自动动作的边界（保守设计）】
###   只有在「boot 卡住超过阈值」**且**「logcat 出现明确 GPU/DRM/EGL 崩溃证据」时才自动
###   回退软件渲染并重建容器；只命中其一则仅记录诊断、不改任何配置。
###   回退为一次性（标记文件），不会反复重建打断会话。
###
### 3.9.9：先切到根目录。守护是长驻进程，若它的工作目录在安装/升级时被替换掉
### （实测 2026-11-09：cwd 变成 /vol1/@appcenter/androidemu/docker (deleted)），
### 之后每 spawn 一个子 bash 都会打印
###   shell-init: error retrieving current directory: getcwd: ...
### 后台日志被这类噪音刷了 450 行。切到 / 之后不再依赖原目录是否存在。
cd / 2>/dev/null || true

### 用法：boot_guard.sh {start|stop|status|once|supervise}
### 环境变量（测试/排障用）：
###   BG_CNAME        容器名，默认 androidemu-android
###   BG_COMPOSE      compose 路径，默认 $TRIM_APPDEST/docker/docker-compose.yaml
###   BG_STUCK_SECS   判定「卡住」的秒数，默认 240
###   BG_INTERVAL     巡检间隔（守护模式），默认 60
###   BG_GPU_MIN      判定为 GPU 问题所需的 logcat 命中数，默认 3
###   BG_NO_RECREATE=1  只诊断不重建（测试用）
###   BG_ASSUME_GPU=1   无视 logcat 证据按 GPU 处理（测试用）

set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
C="${BG_CNAME:-${REDROID_NAME:-androidemu-android}}"
C_WEB="${REDROID_NAME_WEB:-androidemu-webrtc}"
COMPOSE="${BG_COMPOSE:-$APP_DIR/docker/docker-compose.yaml}"
STUCK_SECS="${BG_STUCK_SECS:-240}"
INTERVAL="${BG_INTERVAL:-60}"
GPU_MIN="${BG_GPU_MIN:-3}"
LOG="$VAR_DIR/boot_guard.log"
STATUS="$VAR_DIR/boot_diag.status"
PIDFILE="$VAR_DIR/boot_guard.pid"
STAMP="$VAR_DIR/boot_guard.stamp"
MARK="$VAR_DIR/gpu_fallback.done"

mkdir -p "$VAR_DIR" 2>/dev/null || true
log(){ echo "[$(date '+%F %T')] boot_guard: $*" >>"$LOG" 2>/dev/null || true; }

running(){ [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]; }
booted(){ [ "$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')" = "1" ]; }
dex(){ docker exec -u 0 "$C" sh -c "$1" 2>/dev/null | tr -d '\r\n'; }

### GPU/DRM 崩溃证据计数（真实日志来源 = 容器内 logcat）
logcat_gpu_hits(){
    _n=$(docker exec -u 0 "$C" sh -c "logcat -d 2>/dev/null | grep -icE 'no suitable EGLConfig|EGL_BAD|Failed to open /dev/dri|gralloc.*(fail|error)|drm.*(fail|error)'" 2>/dev/null | tr -d '\r\n')
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    echo "$_n"
}

### 诊断落盘（用户/远程支持的第一手材料）
collect_diag(){
    _stuck="$1" _gpu="$2" _verdict="$3"
    {
        echo "TS=$(date '+%F %T')"
        echo "CONCLUSION=$_verdict"
        echo "STUCK_SECONDS=$_stuck"
        echo "# ── 容器状态 ──"
        echo "container_running=$(running && echo yes || echo no)"
        echo "boot_completed=$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')"
        echo "container_state=$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null)"
        echo "restart_count=$(docker inspect -f '{{.RestartCount}}' "$C" 2>/dev/null)"
        echo "started_at=$(docker inspect -f '{{.State.StartedAt}}' "$C" 2>/dev/null)"
        echo "oom_killed=$(docker inspect -f '{{.State.OOMKilled}}' "$C" 2>/dev/null)"
        echo "mem_cpu=$(docker stats --no-stream --format '{{.MemUsage}} {{.CPUPerc}}' "$C" 2>/dev/null)"
        echo "# ── 关键服务（为空=还没起来）──"
        echo "surfaceflinger=$(dex 'getprop init.svc.surfaceflinger')"
        echo "zygote=$(dex 'getprop init.svc.zygote')"
        echo "servicemanager=$(dex 'getprop init.svc.servicemanager')"
        echo "# ── 权限/设备（启动硬前提）──"
        echo "container_priv=$(docker inspect -f '{{.HostConfig.Privileged}}' "$C" 2>/dev/null)"
        echo "devices=$(docker inspect -f '{{json .HostConfig.Devices}}' "$C" 2>/dev/null)"
        echo "seccomp_opt=$(docker inspect -f '{{range .HostConfig.SecurityOpt}}{{.}} {{end}}' "$C" 2>/dev/null | grep -q seccomp= && echo '自定义 seccomp 已挂载' || echo '无')"
        echo "container_binder=$(dex 'ls -l /dev/binder 2>/dev/null | head -1')"
        echo "container_dri=$(dex 'ls -l /dev/dri 2>/dev/null | tr "\n" " "')"
        echo "host_dri_modes=$(for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && printf '%s:%s ' "$(basename "$d")" "$(stat -c %a "$d" 2>/dev/null)"; done)"
        echo "container_dri_modes=$(docker exec -u 0 "$C" sh -c 'for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && printf "%s:%s " "$(basename "$d")" "$(stat -c %a "$d" 2>/dev/null)"; done' 2>/dev/null | tr -d "\r\n")"
        echo "render_mode=$(sed -n 's/^MODE=//p' "$VAR_DIR/render-mode" 2>/dev/null | head -n1)"
        echo "gpu_fallback_done=$([ -f "$MARK" ] && echo yes || echo no)"
        echo "# ── 启动日志（docker logs 恒为空属正常：compose 关了串口控制台 console=0）──"
        echo "docker_logs_bytes=$(docker logs "$C" 2>&1 | wc -c)"
        _lc=$(docker exec -u 0 "$C" sh -c 'logcat -d 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r\n')
        echo "logcat_lines=${_lc:-0}"
        echo "logcat_gpu_drm_hits=$_gpu"
        echo "# ── logcat 关键行（最后 15 条）──"
        docker exec -u 0 "$C" sh -c "logcat -d 2>/dev/null | grep -iE 'EGLConfig|EGL_BAD|/dev/dri|gralloc|drm|binder|init:|avc: denied' | tail -15" 2>/dev/null | sed 's/^/  /'
        echo "# ── 建议 ──"
        echo "$4"
        if [ "${_lc:-0}" = "0" ]; then
            echo "  · logcat 无输出：Android init 尚未推进到 logd —— 重点核对上面的 container_priv / container_binder / container_dri"
            echo "  · 可手动验证软件渲染：bash scripts/tune_compose.sh --force-software docker/docker-compose.yaml 后重建 redroid 容器"
        elif [ "${_gpu:-0}" -ge 3 ] 2>/dev/null; then
            echo "  · 已有 GPU/DRM 崩溃证据：守护会自动「放权宿主 DRI → 重建」，必要时再回退软件渲染，通常无需手工干预"
        fi
    } > "$STATUS" 2>/dev/null || true
}

### 宿主 DRI 节点权限是否未放开（660 → 容器内渲染进程打不开设备，是"重启后开不了机"的常见根因）
### 3.9.8：只关心「容器内」的 DRI 节点权限。
### 背景（2026-11-07 实测）：compose 用 devices: 直通时，容器内 /dev/dri/* 是创建/重启
### 那一刻按宿主权限生成的副本（容器内 /dev 是 tmpfs）。安卓只要容器内节点可读写就能
### 正常开机，宿主 /dev/dri 保持 root:video 660 即可 —— 本应用不再改宿主设备权限。
container_dri_perms_bad(){
    [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ] || return 1
    _m=$(docker exec -u 0 "$C" sh -c 'for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && printf "%s " "$(stat -c %a "$d" 2>/dev/null)"; done' 2>/dev/null | tr -d '\r\n')
    [ -n "$_m" ] || return 1
    for _x in $_m; do [ "$_x" = "666" ] || return 0; done
    return 1
}

### 自愈（保守、分两步）：
###   ① 宿主 DRI 权限未放开 → 放权 + 重建（**保住 GPU 加速**，这是最常见、代价最小的修复）；
###   ② 权限正常但 logcat 有 GPU/DRM 崩溃证据 → 回退软件渲染 + 重建（一次性）。
maybe_heal(){
    _mode=$(sed -n 's/^MODE=//p' "$VAR_DIR/render-mode" 2>/dev/null | head -n1)

    ### ① 容器内 DRI 权限修复（每次开机最多一次；不放权则 surfaceflinger 打不开设备）
    ###    只改容器自己的节点副本，不改宿主、不重建容器；重建反而会把节点权限重置回宿主值。
    if container_dri_perms_bad && [ ! -f "$VAR_DIR/dri_release.done" ]; then
        log "容器内 DRI 节点权限未放开（$(docker exec -u 0 "$C" sh -c 'for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && printf "%s:%s " "$(basename "$d")" "$(stat -c %a "$d" 2>/dev/null)"; done' 2>/dev/null | tr -d '\r\n')）→ 在容器内放权（不改宿主、不重建）"
        date '+%F %T' > "$VAR_DIR/dri_release.done" 2>/dev/null || true
        if [ -f "$APP_DIR/scripts/gpu_release.sh" ]; then
            TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/gpu_release.sh" >>"$LOG" 2>&1 || true
        fi
        ### 放权后给 surfaceflinger 一点重试时间；仍未开机则重启一次容器并立刻重新放权
        _w=0
        while [ "$_w" -lt 30 ]; do
            [ "$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')" = "1" ] && break
            sleep 2; _w=$((_w+1))
        done
        if [ "$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')" != "1" ]; then
            if [ "${BG_NO_RECREATE:-0}" = "1" ]; then
                log "BG_NO_RECREATE=1，跳过重启（测试模式）"
                return 0
            fi
            log "放权后仍未开机 → 重启容器并立即重新放权"
            docker restart "$C" >>"$LOG" 2>&1 || true
            if [ -f "$APP_DIR/scripts/gpu_release.sh" ]; then
                TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/gpu_release.sh" --wait 40 >>"$LOG" 2>&1 || true
            fi
        fi
        return 0
    fi

    ### ② 软件渲染回退（一次性）
    if [ -f "$MARK" ]; then
        ### 3.9.8：标记必须和当前渲染模式一致。实测另一台虚拟机残留了 3 天前的
        ### gpu_fallback.done，而重装后 render-mode 又探测成 gpu/host —— 守护以为
        ### 「已经回退过」而永久跳过自愈，surfaceflinger 连续崩 75 分钟、
        ### boot_completed 一直为空、面板 0 台在线。
        _cur_mode=$(sed -n 's/^MODE=//p' "$VAR_DIR/render-mode" 2>/dev/null | head -n1)
        if [ "$_cur_mode" != "software" ]; then
            log "软件渲染回退标记存在但当前模式为 ${_cur_mode:-未知}（标记过期/回退未落地）→ 清除标记，重新回退"
            rm -f "$MARK" 2>/dev/null || true
        else
            log "已回退过软件渲染（$MARK 存在），不再重复动作；诊断见 $STATUS"
            return 0
        fi
    fi
    _gpu=$(logcat_gpu_hits)
    [ "${BG_ASSUME_GPU:-0}" = "1" ] && _gpu=99
    if [ "$_gpu" -ge "$GPU_MIN" ]; then
        log "检出 GPU/DRM 崩溃证据 ${_gpu} 处（render-mode=${_mode:-未知}）→ 回退软件渲染并重建 redroid 容器"
        date '+%F %T' > "$MARK" 2>/dev/null || true
        if [ -f "$APP_DIR/scripts/tune_compose.sh" ] && [ -f "$COMPOSE" ]; then
            bash "$APP_DIR/scripts/tune_compose.sh" --force-software "$COMPOSE" >>"$LOG" 2>&1 || true
        fi
        if [ "${BG_NO_RECREATE:-0}" = "1" ]; then
            log "BG_NO_RECREATE=1，跳过重建（测试模式）"
            return 0
        fi
        ( cd "$(dirname "$COMPOSE")" 2>/dev/null && docker compose -p androidemu up -d --force-recreate redroid ) >>"$LOG" 2>&1 || true
        rm -f "$STAMP" 2>/dev/null || true
        log "已按软件渲染重建 redroid 容器，请等待重新开机（约 1~3 分钟）"
    else
        log "boot 卡住但未发现 GPU/DRM 证据（logcat 命中 ${_gpu}，宿主 DRI 权限正常）→ 仅记录诊断，不改配置"
    fi
}

### 3.9.1：渲染异常（花屏）巡检 —— 已开机成功时也能发现「画面错乱」类问题。
### 背景：GPU 直通（host）在部分驱动上不出崩机、但会持续报渲染错误（buffer 出队失败、
###   EGL surface 失效、gralloc 分配失败、fence 超时…），用户看到的就是花屏/绿屏/条纹。
###   这类问题旧版看护完全覆盖不到（只在 boot 卡住时才动作）。
### 策略：MODE=gpu 且开机满 ART_MIN_UP 秒后，扫描近期 logcat 的「渲染错误特征」，
###   命中数 ≥ BG_ART_MIN（默认 8）→ 一次性回退软件渲染并重建 redroid（写 gpu_artifact.done，
###   不反复横跳；用户可用 scripts/switch_render.sh gpu 手动切回）。
ART_MIN_UP="${BG_ART_MIN_UP:-180}"
ART_HITS_MIN="${BG_ART_MIN:-8}"
ART_MARK="$VAR_DIR/gpu_artifact.done"

art_hits(){
    docker exec -u 0 "$C" sh -c "logcat -d -t 800 2>/dev/null | grep -icE 'dequeueBuffer failed|EGL_BAD_SURFACE|EGL_BAD_ALLOC|gralloc.*(alloc|lock|map).*(fail|error)|hwcomposer.*(fail|error)|Fence.*(timeout|timed out)'" 2>/dev/null | tr -d '\r\n'
}

check_render_artifacts(){
    [ -f "$ART_MARK" ] && return 0
    _mode=$(sed -n 's/^MODE=//p' "$VAR_DIR/render-mode" 2>/dev/null | head -n1)
    if [ "$_mode" != "gpu" ]; then
        ### render-mode 缺失时退回 compose 判断（gpu_mode=host 才算直通）
        grep -q 'androidboot\.redroid_gpu_mode=host' "$COMPOSE" 2>/dev/null || return 0
    fi
    ### 开机初期渲染错误本就多（SurfaceFlinger/相册等冷启动），给足稳定窗口再判定
    _up=$(docker inspect -f '{{.State.StartedAt}}' "$C" 2>/dev/null)
    if [ -n "$_up" ]; then
        _up_s=$(date -d "$_up" +%s 2>/dev/null || echo 0)
        _now_s=$(date +%s 2>/dev/null || echo 0)
        [ "$_up_s" -gt 0 ] && [ $(( _now_s - _up_s )) -lt "$ART_MIN_UP" ] && return 0
    fi
    _hits=$(art_hits)
    case "$_hits" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_hits" -lt "$ART_HITS_MIN" ]; then
        return 0
    fi
    log "检出渲染异常特征 ${_hits} 处（阈值 ${ART_HITS_MIN}，GPU 直通模式）→ 判定画面错乱风险，回退软件渲染"
    date '+%F %T' > "$ART_MARK" 2>/dev/null || true
    collect_diag 0 "$_hits" "渲染异常（疑似花屏/错帧，命中 ${_hits}）" \
        "已自动回退软件渲染（swiftshader）并重建容器；如需重新尝试 GPU 直通：bash scripts/switch_render.sh gpu"
    if [ -f "$APP_DIR/scripts/tune_compose.sh" ] && [ -f "$COMPOSE" ]; then
        bash "$APP_DIR/scripts/tune_compose.sh" --force-software "$COMPOSE" >>"$LOG" 2>&1 || true
    fi
    if [ "${BG_NO_RECREATE:-0}" = "1" ]; then
        log "BG_NO_RECREATE=1，跳过重建（测试模式）"
        return 0
    fi
    ( cd "$(dirname "$COMPOSE")" 2>/dev/null && docker compose -p androidemu up -d --force-recreate redroid ) >>"$LOG" 2>&1 || true
    rm -f "$STAMP" 2>/dev/null || true
    log "已按软件渲染重建 redroid 容器（渲染异常回退，一次性；不会反复切换）"
}

### 3.9.4：日志轮转。
###   长期运行下本应用的日志没有任何上限：实测 gateway.log 3.2MB、webrtc_watchdog.log 1.4MB、
###   agent_helper.log 1.2MB、adb_forward.log 1.3MB，都还在持续增长，几个月后会占掉可观存储，
###   也会拖慢用户按日志排查。这里每轮巡检检查一次，单文件超过 2MB 就只保留最近 1MB。
###   用「tail 出尾部 → cat 覆盖回原文件」，保持 inode 不变，正在写入的进程句柄不会失效。
rotate_logs(){
    for _lf in "$VAR_DIR/gateway.log" "$VAR_DIR/webrtc_watchdog.log" "$VAR_DIR/agent_helper.log" \
               "$VAR_DIR/adb_forward.log" "$VAR_DIR/audio_fix.log" "$VAR_DIR/keystore_fix.log" \
               "$VAR_DIR/boot_guard.log" "$VAR_DIR/docker_up_retry.log" "$VAR_DIR/storage_perm_fix.log" \
               "$VAR_DIR/agent_watchdog_loop.log"; do
        [ -f "$_lf" ] || continue
        _sz=$(stat -c%s "$_lf" 2>/dev/null || echo 0)
        case "$_sz" in ''|*[!0-9]*) continue ;; esac
        [ "$_sz" -le 2097152 ] && continue
        if tail -c 1048576 "$_lf" > "$_lf.rt" 2>/dev/null; then
            cat "$_lf.rt" > "$_lf" 2>/dev/null || true
        fi
        rm -f "$_lf.rt" 2>/dev/null || true
    done
}

### 单次巡检
### 3.9.9：升级 / 重装窗口判定（与 webrtc_watchdog.sh 同名函数同义）。
### 飞牛升级是「替换应用文件 → docker-project down/pull/up」，down 之后容器是「不存在」，
### 本守护若在这段时间补建容器，就会和飞牛随后按固定 container_name 的 up 撞车
### （报 container name already in use，升级界面弹「无法更新」，2026-11-08 实测）。
### 判据：应用文件（manifest / 看护脚本 / compose）最近 PKG_FRESH_WINDOW 秒内被替换过；
### 正常运行期这些文件 mtime 不变，所以不影响崩溃自愈。
PKG_FRESH_WINDOW="${AE_PKG_FRESH_WINDOW:-300}"
pkg_files_fresh(){
    if [ -f "$VAR_DIR/.upgrade_window" ]; then
        _uw=$(cat "$VAR_DIR/.upgrade_window" 2>/dev/null || echo "")
        case "$_uw" in
            ''|*[!0-9]*) : ;;
            *) [ $(( $(date +%s) - _uw )) -lt 1800 ] && return 0 ;;
        esac
    fi
    _pnow=$(date +%s)
    for _pf in "$APP_DIR/manifest" "$APP_DIR/scripts/boot_guard.sh" "$APP_DIR/docker/docker-compose.yaml"; do
        [ -f "$_pf" ] || continue
        _pm=$(stat -c %Y "$_pf" 2>/dev/null || echo 0)
        case "$_pm" in ''|*[!0-9]*) continue ;; esac
        [ "$_pm" -gt 0 ] || continue
        [ $(( _pnow - _pm )) -lt "$PKG_FRESH_WINDOW" ] && return 0
    done
    return 1
}

once(){
    ### 3.9.9：分辨率 16 对齐护栏（花屏兜底，与浏览器软/硬解无关）。
    ### 必须放在「升级/重装静默窗口」之前：那 300 秒里整轮容器巡检会跳过，
    ### 而分辨率如果被前端/用户改成非 16 对齐，这 5 分钟就会一直花屏。
    ### 护栏本身幂等：不重建容器、不碰端口、只改 wm size 与两处配置；
    ### 容器未就绪时脚本内 boot_completed 判定会直接返回，不产生副作用。
    ### 常驻护栏（15 秒一轮）由 install/upgrade 回调与 boot_guard start 拉起；
    ### 这里每轮兜底检查：进程不在就重新拉起，防止常驻被意外杀掉。
    if [ -f "$APP_DIR/scripts/resolution_guard.sh" ]; then
        if ! pgrep -f "scripts/resolution_guard.sh supervise" >/dev/null 2>&1; then
            TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" \
                TRIM_RUN_USERNAME="${TRIM_RUN_USERNAME:-docker-androidemu}" \
                bash "$APP_DIR/scripts/resolution_guard.sh" start >>"$LOG" 2>&1 || true
        fi
    fi

    ### 3.9.9-r4：存储权限守护兜底。容器重建/升级窗口里该守护可能被清掉，
    ### 不恢复的话 /data/media/0/* 会停在 700，文件中心一直报
    ### 「open /sdcard/Download: permission denied」（2026-11-10 实测）。
    if [ -f "$APP_DIR/scripts/fix_storage_perm.sh" ]; then
        if ! pgrep -f "scripts/fix_storage_perm.sh" >/dev/null 2>&1; then
            TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" \
                nohup bash "$APP_DIR/scripts/fix_storage_perm.sh" >>"$LOG" 2>&1 &
            log "存储权限守护缺失 → 已重新拉起"
        fi
        ### 守护在跑也可能还没轮到本轮；对 Download 做一次幂等快检，最坏 60 秒内补一刀。
        if [ "$(docker exec "$C" sh -c 'stat -c %a /data/media/0/Download 2>/dev/null' 2>/dev/null | tr -d '\r\n')" != "777" ]; then
            TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" \
                bash "$APP_DIR/scripts/fix_storage_perm.sh" --once >>"$LOG" 2>&1 || true
            log "存储目录权限非 777 → 已执行一次修复"
        fi
    fi

    ### 3.9.9：升级/重装窗口内不碰容器（原因见 pkg_files_fresh 注释）
    if pkg_files_fresh; then
        log "应用文件最近 ${PKG_FRESH_WINDOW}s 内被替换（升级/重装窗口）→ 本轮跳过容器巡检"
        return 0
    fi
    ### 3.9.8：每轮轻量补一次「容器内」DRI 节点放权（容器重启/重建会重置回宿主权限值）。
    ### 幂等：已是 666 时脚本自己跳过；只在容器 running 且确有需要时执行，不产生额外容器。
    if container_dri_perms_bad; then
        TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/gpu_release.sh" --wait 3 >>"$LOG" 2>&1 || true
    fi
    if ! running; then
        collect_diag 0 0 "容器未运行（由 Docker restart 策略或应用中心启用拉起）" \
            "若长期不运行：在应用中心「停用 → 启用」，或查看 $LOG"
        return 0
    fi
    if booted; then
        ### 开机成功：清掉"卡住计时"与"DRI 放权已做过"的一次性标记（下次开机仍可重新生效）；
        ### gpu_fallback.done（软件渲染回退）保持持久，避免来回切换。
        rm -f "$STAMP" "$VAR_DIR/dri_release.done" 2>/dev/null || true
        ### 3.9.1：开机成功后仍需巡检渲染异常（花屏类问题不崩机，只在日志里留痕迹）
        check_render_artifacts || true
        ### 3.9.1：语言/时区收敛（任何启动路径都能生效；同一次开机只尝试一次）
        ### 节流：locale.status 5 分钟内刚写过就跳过，避免每轮巡检 6 次 docker exec。
        if [ -f "$APP_DIR/scripts/fix_locale.sh" ]; then
            _ls_mtime=$(stat -c %Y "$VAR_DIR/locale.status" 2>/dev/null || echo 0)
            if [ $(( $(date +%s) - _ls_mtime )) -gt 300 ]; then
                bash "$APP_DIR/scripts/fix_locale.sh" >/dev/null 2>&1 || true
            fi
        fi
        ### 3.9.1：桌面图标占位自愈 —— 用户装完应用后 APK 权限可能又落成 0700，
        ### 导致图标退化为「包名+安卓小人」。脚本自带 5 分钟节流，权限正常时零开销。
        if [ -x "$APP_DIR/scripts/fix_app_icons.sh" ]; then
            TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/fix_app_icons.sh" >>"$LOG" 2>&1 || true
        fi

        ### 3.9.1：身份伪装兜底 —— 仅在覆盖文件缺失时后台补齐，避免启动链路阻塞。
        ### （放在开机成功之后：此时镜像必然已在本地，docker create 秒回，不会与镜像拉取争锁；
        ###   补齐后写回 compose 挂载，容器下次重建即生效。）
        if [ -x "$APP_DIR/scripts/apply_rebrand.sh" ] && [ ! -s "$VAR_DIR/props/system/build.prop" ]; then
            log "身份伪装覆盖文件缺失 → 后台补齐（容器下次重建后生效）"
            ( TRIM_PKGVAR="$VAR_DIR" TRIM_PKGAPPDIR="$APP_DIR" nohup bash "$APP_DIR/scripts/apply_rebrand.sh" >/dev/null 2>&1 & ) || true
        fi

        ### 3.9.1：agent 兜底 —— 守护/agent 缺失，或信令协议与 TLS 开关不符时，自动重部署。
        ### （fix_locale 重启框架、TLS 切换都会让 agent 掉线；30s 自愈循环不一定在跑。）
        if [ -f "$APP_DIR/scripts/agent_autodeploy.sh" ]; then
            if bash "$APP_DIR/scripts/agent_autodeploy.sh" --needs-redeploy >/dev/null 2>&1; then
                log "agent 需要重部署（缺失或协议与 TLS 不符）→ 后台执行"
                ### 3.9.4：改为后台执行。实测同步执行时整个部署要几十秒到数分钟（推 agent 二进制
                ### 进容器），会把整轮巡检阻塞，一旦外层带超时（如 timeout 包裹启动）部署会被
                ### 中途掐断，表现为「日志停在『开始部署agent』、宿主上没有守护循环」。
                ( TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" nohup bash "$APP_DIR/scripts/agent_autodeploy.sh" >>"$LOG" 2>&1 & ) || true
            fi
        fi

        ### 3.9.4：agent 常驻守护丢失自愈。
        ### 上面那条兜底只在「agent 需要重部署」时才动作（agent 正常运行就返回 1 不做事）。
        ### 实测把宿主上的守护循环清掉后，因为容器里的 agent 仍在正常跑，--needs-redeploy
        ### 一直返回 1，守护就再也不会被装回来 —— 下一轮 agent 崩溃便无人拉起。
        ### 这里补一条：容器在跑 + agent 进程在 + 宿主上没有守护循环 → 重装守护。
        ### 频率限制 10 分钟一次，避免异常场景下反复调用。
        if [ -f "$APP_DIR/scripts/agent_autodeploy.sh" ]; then
            _wd_alive=0
            ps -eo args 2>/dev/null | grep -F "agent_watchdog_loop.sh" | grep -F "androidemu" | grep -v grep >/dev/null 2>&1 && _wd_alive=1
            ps -eo args 2>/dev/null | grep -F "scripts/agent_autodeploy.sh" | grep -F "androidemu" | grep -E 'while|sleep [0-9]' | grep -v grep >/dev/null 2>&1 && _wd_alive=1
            if [ "$_wd_alive" = "0" ]; then
                _wd_stamp="$VAR_DIR/.agent_wd_restore"
                _wd_now=$(date +%s)
                _wd_last=$( [ -f "$_wd_stamp" ] && cat "$_wd_stamp" 2>/dev/null || echo 0 )
                case "$_wd_last" in ''|*[!0-9]*) _wd_last=0 ;; esac
                if [ $((_wd_now - _wd_last)) -ge 600 ]; then
                    if docker exec -u 0 "$C" sh -c 'ps -A 2>/dev/null | grep -q cloudphone-agent' >/dev/null 2>&1; then
                        log "agent 守护循环缺失（容器内 agent 仍在运行）→ 后台重新安装守护"
                        ( TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" nohup bash "$APP_DIR/scripts/agent_autodeploy.sh" >>"$LOG" 2>&1 & ) || true
                        echo "$_wd_now" > "$_wd_stamp" 2>/dev/null || true
                    fi
                fi
            fi
        fi
        ### 3.9.6：agent 连接存活巡检 —— 进程在「但不工作」是最隐蔽的一种：
        ### websocket 断开后进程仍存活，服务端收不到设备注册，用户看到「没有设备」，
        ### 等 5-10 分钟也不会自愈（官方群反馈）。判断依据：agent.log 的最后写入时间，
        ### 超过 5 分钟没有任何输出说明它已经卡死/断线，直接重启让它重新注册。
        if docker exec -u 0 "$C" sh -c 'ps -A 2>/dev/null | grep -q cloudphone-agent' >/dev/null 2>&1; then
            _ag_age=$(docker exec -u 0 "$C" sh -c 'stat -c %Y /data/local/tmp/agent.log 2>/dev/null || echo 0' 2>/dev/null | tr -d '\r')
            case "$_ag_age" in ''|*[!0-9]*) _ag_age=0 ;; esac
            _ag_now=$(date +%s)
            if [ "$_ag_age" -gt 0 ] && [ $((_ag_now - _ag_age)) -ge 300 ]; then
                log "agent 进程在但日志 5 分钟无输出（疑似断线）→ 重启 agent 重新注册设备"
                docker exec -u 0 "$C" sh -c 'pkill -f cloudphone-agent' >/dev/null 2>&1 || true
                sleep 2
                ( TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" nohup bash "$APP_DIR/scripts/agent_autodeploy.sh" >>"$LOG" 2>&1 & ) 2>/dev/null || true
            fi
        fi

        ### 3.9.2：信令端口存活巡检 —— 容器在跑但 webrtc 服务进程崩溃（8443 拒连）时，
        ### 自动重启 webrtc 容器。每次开机最多尝试一次（标记防循环）。
        ### 3.9.2 补：webrtc 容器整个停在 Exited（启用路径只创建安卓容器，见 cmd/main）
        ### 时也拉起 —— 实测「停用→启用」后 8443 一直不监听、画面打不开，就是这个场景。
        ### 3.9.9：端口取 ports.conf 的实际值（原来写死 8443，用户改了画面端口后这里
        ### 会一直误判「未监听」，进而白重启一次 webrtc）。
        _wp=8443
        if [ -f "$VAR_DIR/ports.conf" ]; then
            _wpv=$(sed -n 's/^WEB_PORT=//p' "$VAR_DIR/ports.conf" 2>/dev/null | head -n1)
            case "$_wpv" in ''|*[!0-9]*) : ;; *) _wp="$_wpv" ;; esac
        fi
        if command -v ss >/dev/null 2>&1 && ! ss -tln 2>/dev/null | grep -q ":$_wp "; then
            _wr_running=$(docker inspect -f '{{.State.Running}}' androidemu-webrtc 2>/dev/null | tr -d '\r\n')
            _wm="$VAR_DIR/.webrtc_restarted_$(sed -n 's/^btime=//p' /proc/stat 2>/dev/null | head -1)"
            if [ "$_wr_running" = "true" ]; then
                if [ ! -f "$_wm" ]; then
                    ### 3.9.9：与 webrtc_watchdog 共用「端口持续不通」计时（.web_down_since）。
                    ### 用户点停用时画面服务先收 SIGTERM（此时 docker 状态仍是 running、
                    ### 端口已关），旧逻辑会立刻 restart 把它拉回来 —— 实测停用后 8443 又活、
                    ### 还多一次容器重建。现在要求端口持续不通满 90 秒才允许重启：
                    ### 正常停用在此之前就结束了（安卓一停，本段根本不会进入）。
                    _bdown="$VAR_DIR/.web_down_since"
                    _bnow=$(date +%s)
                    _bs=$(cat "$_bdown" 2>/dev/null || echo "")
                    case "$_bs" in
                        ''|*[!0-9]*)
                            echo "$_bnow" > "$_bdown" 2>/dev/null || true
                            log "信令端口 $_wp 未监听且 webrtc 在运行 → 记录时刻先观察（60s），不立即重启"
                            ;;
                        *)
                            if [ $(( _bnow - _bs )) -lt 90 ]; then
                                log "信令端口 $_wp 仍未监听 $(( _bnow - _bs ))s（观察窗口 90s）→ 继续观察"
                            else
                                log "信令端口 $_wp 持续未监听 $(( _bnow - _bs ))s 且 webrtc 容器在运行 → 自动重启 webrtc 容器（本次开机限一次）"
                                docker restart androidemu-webrtc >/dev/null 2>&1 || true
                                mkdir -p "$VAR_DIR" && touch "$_wm" 2>/dev/null
                                rm -f "$_bdown" 2>/dev/null || true
                            fi
                            ;;
                    esac
                fi
            elif [ -n "$_wr_running" ] && [ ! -f "$_wm" ]; then
                ### 3.9.4：用户点「停用」时 compose 是先停 webrtc、再停安卓 —— 此刻
                ### webrtc 已 Exited 而安卓还 running，本规则会立刻把 webrtc 拉回来，
                ### 表现为「停用无效 / 容器反复重建」。因此加一道时间闸：webrtc 刚刚
                ### 退出（<180 秒）时一律不干预，交给停用流程走完；真正需要自救的场景
                ### （webrtc 长时间停着而安卓一直正常运行）仍然会命中。
                _wr_fin=$(docker inspect -f '{{.State.FinishedAt}}' androidemu-webrtc 2>/dev/null | tr -d '\r\n')
                _wr_age=999999
                if [ -n "$_wr_fin" ] && [ "$_wr_fin" != "0001-01-01T00:00:00Z" ]; then
                    _wr_ts=$(date -d "$_wr_fin" +%s 2>/dev/null || echo 0)
                    [ "$_wr_ts" -gt 0 ] 2>/dev/null && _wr_age=$(( $(date +%s) - _wr_ts ))
                fi
                if [ "$_wr_age" -lt 180 ]; then
                    log "webrtc 刚退出 ${_wr_age}s（疑似用户停用中）→ 本轮不自动拉起"
                else
                    log "webrtc 容器已停止而安卓容器在运行 → 自动启动（本次开机限一次）"
                    docker start androidemu-webrtc >/dev/null 2>&1 || true
                    mkdir -p "$VAR_DIR" && touch "$_wm" 2>/dev/null
                fi
            fi
        else
            ### 端口正常 → 清掉观察计时，下一轮异常重新从零开始计
            rm -f "$VAR_DIR/.web_down_since" 2>/dev/null || true
        fi

        ### 3.9.2 热修：安装会话残留导致 PackageManager 崩溃循环（每约 2 分钟重启一次）时自动清理。
        ### 只在 crash 缓冲里确实出现 findPathForUuid 特征 ≥3 次时动作，限频 30 分钟/容器。
        if [ -x "$APP_DIR/scripts/fix_pms_loop.sh" ]; then
            TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/fix_pms_loop.sh" >>"$LOG" 2>&1 || true
        fi

        ### 3.9.2：开机后生成「32 位应用」报告（纯只读，供用户/排查对照，安装向导里指向它）。
        ### 只在本次开机第一次巡检时执行，用 btime 做标记避免每分钟重跑。
        if [ -x "$APP_DIR/scripts/check_abi_apps.sh" ]; then
            _abi_mk="$VAR_DIR/.abi_report_$(sed -n 's/^btime=//p' /proc/stat 2>/dev/null | head -1)"
            if [ ! -f "$_abi_mk" ]; then
                CNAME="$C" TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/check_abi_apps.sh" --quiet >>"$LOG" 2>&1 || true
                mkdir -p "$VAR_DIR" 2>/dev/null && touch "$_abi_mk" 2>/dev/null || true
            fi
        fi

        ### 3.9.2 热修：keystore/locksettings 属主常驻巡检 —— 该守护原先只在安装流程
        ### （start_pull_bg.sh）被拉起，重启或重装后即丢失；实测此时 /data/system 被写成
        ### 宿主数字 UID（961:994）→ keystore2 崩 → LockSettingsService 断言失败 →
        ### system_server 反复重启，表现是「所有应用都点不开、无限正在启动手机」。
        ### 现改为每次开机成功都幂等补齐：先检测修复一次，再常驻（flock 保单实例）。
        if [ -x "$APP_DIR/scripts/fix_keystore.sh" ]; then
            TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/fix_keystore.sh" --once >>"$LOG" 2>&1 || true
            TRIM_PKGVAR="$VAR_DIR" nohup bash "$APP_DIR/scripts/fix_keystore.sh" >/dev/null 2>&1 &
        fi

        ### 3.9.3 权限修正配套：身份伪装兜底重放（在 harden_system 之前执行，让
        ### 「user/release-keys/debuggable=0」画像先一步就位，避免 harden_system 因
        ### userdebug 特征再做一次多余重启）。
        ### 背景（实测 2026-10-31 全新安装）：安装回调窗口内应用树权限未被应用
        ### 中心托管到位，tune_compose 对 compose 的 grep/sed 共 19 条
        ### Permission denied，apply_rebrand 的 props 重建与 compose 挂载注入
        ### 整体落空——容器呈现 redroid 原始 userdebug 画像（复核判据：伪装
        ### 属性组仅模板基线一条幸存）。
        ### 每轮健康巡检补查：props 不齐或 compose 无挂载行 → 重跑
        ### apply_rebrand.sh（其内部幂等：齐了直接返回）；仅当这次真的注入了
        ### 新挂载行才重建一次 redroid 容器（数据卷为 external 卷，重建不动
        ### 数据；与 harden_system 的既有重启语义一致）。
        if [ -f "$APP_DIR/scripts/apply_rebrand.sh" ]; then
            _rb_before=$(grep -c "/props.*build\.prop" "$COMPOSE" 2>/dev/null || echo 0)
            if [ ! -s "$VAR_DIR/props/system/build.prop" ] || [ "${_rb_before:-0}" = "0" ]; then
                TRIM_PKGVAR="$VAR_DIR" TRIM_PKGAPPDIR="$APP_DIR" bash "$APP_DIR/scripts/apply_rebrand.sh" >>"$LOG" 2>&1 || true
                _rb_after=$(grep -c "/props.*build\.prop" "$COMPOSE" 2>/dev/null || echo 0)
                if [ "${_rb_after:-0}" -gt "${_rb_before:-0}" ]; then
                    ( cd "$APP_DIR/docker" 2>/dev/null && docker compose -p androidemu up -d --force-recreate redroid ) >>"$LOG" 2>&1 || true
                    log "身份伪装缺失已补：props 重建 + compose 挂载注入 → 重建 redroid 容器（一次性，数据卷不动，约 1~3 分钟后开机）"
                fi
            fi
        fi

        ### 3.9.1 热修：容器"新手机"画像（去 调试特征）—— 每次 boot 巡检时检查，
        ### 需要处理时自动执行 harden_system.sh（内部幂等+限频：已处理则跳过不重启）。
        if [ -f "$APP_DIR/scripts/harden_system.sh" ]; then
            TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/harden_system.sh" >>"$LOG" 2>&1 || true
        fi
        ### 3.9.9：受限档运行期复核（无 su / adbd 非系统身份 / ADB 仅本机）。
        ### 脚本内部按标记与档位自判，非该档直接退出；60 秒节流。
        if [ -f "$APP_DIR/scripts/runtime_guard.sh" ]; then
            TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/runtime_guard.sh" >>"$LOG" 2>&1 || true
        fi
        ### 3.9.9：硬件视频编码（默认开启，可在向导里关掉）。两种情形：
        ###   ① 向导选了启用但尚未生效 → 执行一次 enable（成功后清请求标记）
        ###   ② 已启用但容器重建导致注入丢失/属性被重置 → repair
        ### 脚本内部有前置检测与失败自动回退；未启用时直接退出，无副作用。
        ### 每 300 秒最多跑一次，避免打断巡检节奏。
        if [ -f "$APP_DIR/scripts/hwenc_ctl.sh" ]; then
            _hw_state="$(cat "$VAR_DIR/hwenc.status" 2>/dev/null || echo none)"
            _hw_last="$(cat "$VAR_DIR/hwenc.last_run" 2>/dev/null || echo 0)"
            _hw_now="$(date +%s)"
            case "${_hw_last:-0}" in ''|*[!0-9]*) _hw_last=0 ;; esac
            if [ "$_hw_state" = "enabled" ]; then
                if [ $((_hw_now - _hw_last)) -ge 300 ]; then
                    TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" \
                        bash "$APP_DIR/scripts/hwenc_ctl.sh" repair >>"$LOG" 2>&1 || true
                    echo "$_hw_now" > "$VAR_DIR/hwenc.last_run" 2>/dev/null || true
                fi
            elif [ -f "$VAR_DIR/hwenc.requested" ]; then
                if [ $((_hw_now - _hw_last)) -ge 120 ]; then
                    if TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" \
                        bash "$APP_DIR/scripts/hwenc_ctl.sh" enable >>"$LOG" 2>&1; then
                        rm -f "$VAR_DIR/hwenc.requested" 2>/dev/null || true
                        echo "[$(date '+%F %T')] 硬件视频编码已启用" >>"$LOG"
                    else
                        echo "[$(date '+%F %T')] 硬件视频编码启用失败（详见 hwenc.log），保持软件编码" >>"$LOG"
                        rm -f "$VAR_DIR/hwenc.requested" 2>/dev/null || true
                    fi
                    echo "$_hw_now" > "$VAR_DIR/hwenc.last_run" 2>/dev/null || true
                fi
            fi
        fi

    ### 3.9.1 热修：禁用面板版本检查弹窗（更新由应用发版统一管理）
        if [ -f "$APP_DIR/scripts/disable_update_popup.sh" ]; then
            TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/disable_update_popup.sh" >>"$LOG" 2>&1 || true
        fi

        ### 3.9.2：桌面图标自动补齐 —— 面板/adb 安装的第三方应用不会自动上桌面
        ###（AOSP Launcher3 只进抽屉）；巡检检测到"有包未上桌面"才动数据库，
        ### 无缺失时静默退出（内部 force-stop 启动器+写库+重启，对用户零打扰）。
        if [ -f "$APP_DIR/scripts/app_desktop_sync.sh" ]; then
            CNAME="$C" TRIM_PKGVAR="$VAR_DIR" bash "$APP_DIR/scripts/app_desktop_sync.sh" 2>/dev/null || true
        fi

        ### 3.9.7：禁用 Google 设置向导。容器内没有 WiFi 硬件，它的 WifiService 请求会被
        ### 拒绝并抛 FATAL EXCEPTION 反复崩溃（实测两分钟内崩两次）。GMS 重装或容器重建
        ### 后包状态会被恢复成启用，所以每轮巡检都做一次幂等收敛。
        if docker exec "$C" sh -c 'pm list packages -e 2>/dev/null | grep -q com.google.android.setupwizard' >/dev/null 2>&1; then
            docker exec "$C" sh -c 'pm disable-user --user 0 com.google.android.setupwizard' >/dev/null 2>&1 &&                 log "已禁用 Google 设置向导（容器无 WiFi 硬件，避免其反复崩溃）"
        fi

        ### 3.9.7：GMS 补装巡检。用户勾了 GMS 但安装流程可能没走 start_pull_bg 那条路
###        （镜像已存在直接起容器时不会触发），容器重建后 /system 又会回退。
###        判定：标记=yes + 容器 boot 完成 + 容器内确实没有 GMS + 当前没有安装进程
###        → 后台补装。install_gms.sh 内部有「已装则跳过」，不会重复装。
        if [ -f "$VAR_DIR/install_gms" ] && [ "$(cat "$VAR_DIR/install_gms" 2>/dev/null | tr -d '\r\n ')" = "yes" ]; then
            if [ "$(docker exec "$C" getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')" = "1" ]; then
                if ! docker exec "$C" sh -c 'pm list packages 2>/dev/null | grep -q com.google.android.gms' >/dev/null 2>&1; then
                    if ! ps -eo args 2>/dev/null | grep -F "scripts/install_gms.sh" | grep -v grep >/dev/null 2>&1; then
                        if [ -f "$APP_DIR/scripts/install_gms.sh" ]; then
                            log "检测到 GMS 标记但仍未安装 → 后台补装"
                            ( TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" nohup bash "$APP_DIR/scripts/install_gms.sh" >>"$LOG" 2>&1 & ) 2>/dev/null || true
                        fi
                    fi
                fi
            fi
        fi

        ### 3.9.2 补：ADB 保活 —— redroid 镜像的 adbd 不是开机自启的，只在安装/启用时
        ### 由 redroid_adb_forward.sh 的 ensure_adbd 拉起一次；容器一重启（升级、清理调试特征
        ### 画像、崩溃自愈都会重启）adbd 就没了，宿主转发器一直重连却连不上目标端口
        ### （实测 2026-10-30：容器 Up 8 小时、init.svc.adbd 为空、5555 未监听，
        ### adb_forward.log 每 23 秒重建一次转发器）。这里每轮巡检兜一次，开销极小。
        if [ "$(docker exec "$C" sh -c 'getprop init.svc.adbd' 2>/dev/null | tr -d '\r\n')" != "running" ]; then
            docker exec -u 0 "$C" sh -c 'setprop service.adb.tcp.port 5555; start adbd' >/dev/null 2>&1 || true
            log "adbd 未运行 → 已尝试拉起（ADB 直连 5555）"
        fi

        # 健康时不写诊断文件，避免覆盖上一次的故障证据；只在文件不存在时留一份基线
        if [ ! -f "$STATUS" ]; then
            collect_diag 0 "$(logcat_gpu_hits)" "健康：boot_completed=1" "无需处理"
        fi
        return 0
    fi
    _now=$(date +%s 2>/dev/null || echo 0)
    _first=$(cat "$STAMP" 2>/dev/null || echo "")
    case "$_first" in ''|*[!0-9]*) _first="$_now"; echo "$_first" > "$STAMP" 2>/dev/null || true ;; esac
    _stuck=$(( _now - _first ))
    _gpu=$(logcat_gpu_hits)
    if [ "$_stuck" -lt "$STUCK_SECS" ]; then
        ### 3.9.8：开机早期快速兜底。surfaceflinger 反复 restarting 是渲染栈起不来的
        ### 明确信号，不必等满 240s 阈值 + logcat 命中数；90 秒即回退软件渲染。
        ### （虚拟机 GPU 直通失败实测卡了 75 分钟，用户看到的就是「一直没设备」。）
        if [ "$_stuck" -ge 90 ]; then
            _sf=$(docker exec "$C" getprop init.svc.surfaceflinger 2>/dev/null | tr -d '\r\n')
            _rmode=$(sed -n 's/^MODE=//p' "$VAR_DIR/render-mode" 2>/dev/null | head -n1)
            if [ "$_sf" = "restarting" ] && [ "$_rmode" != "software" ] && [ ! -f "$MARK" ]; then
                log "开机 ${_stuck}s 且 surfaceflinger=restarting（渲染栈崩溃）→ 提前回退软件渲染并重建"
                date '+%F %T' > "$MARK" 2>/dev/null || true
                if [ -f "$APP_DIR/scripts/tune_compose.sh" ] && [ -f "$COMPOSE" ]; then
                    bash "$APP_DIR/scripts/tune_compose.sh" --force-software "$COMPOSE" >>"$LOG" 2>&1 || true
                fi
                ( cd "$(dirname "$COMPOSE")" 2>/dev/null && docker compose -p androidemu up -d --force-recreate redroid ) >>"$LOG" 2>&1 || true
                rm -f "$STAMP" 2>/dev/null || true
                log "已提前按软件渲染重建 redroid，等待重新开机"
                return 0
            fi
        fi
        log "boot 尚未完成（已 ${_stuck}s，阈值 ${STUCK_SECS}s），继续观察"
        collect_diag "$_stuck" "$_gpu" "开机中（未超阈值）" "继续观察；超过 ${STUCK_SECS}s 仍未开机将自动诊断"
        return 0
    fi
    log "boot 卡住 ${_stuck}s（boot_completed 为空）→ 采集诊断"
    collect_diag "$_stuck" "$_gpu" "开机卡住（已 ${_stuck}s）" \
        "见 $STATUS 与 $LOG；若为 GPU 直通失败，守护会自动回退软件渲染并重建容器"
    maybe_heal
}

### 3.9.3：停用自清（审核项）——实测 fnOS「停用」只停容器，从不调用 cmd/main stop
### （appcenter-cli stop 期间无 cmd/main 进程、main.log 也无记录），宿主侧守护无人处理，
### 停用后仍有 boot_guard / fix_keystore / audio_fix / adb_forward / agent 循环 / 网关在跑。
### 判据用「连续 5 分钟不是 running」而不是「几轮巡检」：用户点启用后容器从 created →
### running 可能需要几十秒到几分钟（镜像/重建慢时更久），按轮次判会在启动窗口里误杀刚拉起的
### 守护链。计时起点落盘，守护重启也不会重置；created/restarting 一律视为「正在启动」。
_SELF_PID=$$
DIS_SINCE="$VAR_DIR/.app_down_since"

### APP_DIR 默认 /var/apps/androidemu/target 是软链，但飞牛拉起守护时用的可能是真实路径
### /vol1/@appcenter/androidemu（实测两种并存，且并非总是成对出现）。凡是按路径匹配
### 进程的地方都必须两种都认，否则会「假报缺失」或「漏杀」。
_APP_REAL="$(readlink -f "$APP_DIR" 2>/dev/null || true)"
[ -n "$_APP_REAL" ] || _APP_REAL="$APP_DIR"
_app_alive(){
    ps -eo args 2>/dev/null | grep -E "($APP_DIR|$_APP_REAL)/$1" | grep -v grep >/dev/null 2>&1
}

_container_up(){
    ### 返回 0 = 在运行或正在启动；1 = 已停止/不存在
    if docker inspect "$C" >/dev/null 2>&1; then
        _st=$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null | tr -d '\r\n')
        case "$_st" in
            running|restarting|created|paused) return 0 ;;
        esac
        ### 容器在、状态读不出来（docker 抖动）→ 按在运行处理，避免误判停用
        [ -z "$_st" ] && return 0
        return 1
    fi
    ### inspect 失败要区分两种完全不同的情况（这里曾判错，导致容器根本没被创建）：
    ###   · docker 本身正常、只是容器不存在 → 视为「未运行」，交给 ensure_containers 创建
    ###   · docker 守护不可用 → 不确定，按在运行处理，别把守护链清掉
    if docker info >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

### 容器是否存在（与「存在但已停」区分开，两者语义完全不同）：
###   · 不存在 = 从没创建成功 → 应用中心「启用」只会 compose start，必然报 12005
###   · 存在但已停 = 用户主动停用 → 保持停用，不拉起
_has_container(){
    docker inspect "$C" >/dev/null 2>&1
}

### 3.9.3：飞牛的「启用」只执行 compose start（实测失败日志：
### exit status 1: service "redroid" has no container to start，应用中心报 12005 →
### 前端只显示「docker不可用 / compose或者container异常」）。也就是说**容器不存在时，
### 用户怎么点启用都不可能成功**，必须由我们自己把容器创建出来。
### 首次安装时镜像还在后台下载、或下载中断，install_callback 的 up 就会失败，
### 这时容器不存在、应用中心永远启用不了 —— 群里「从内测到现在没打开过」就是这条。
### 处理：容器不存在且用户没停用（.want_running 存在）时，每 3 分钟尝试一次 compose up。
WANT_RUNNING="$VAR_DIR/.want_running"
_up_try_ts=0
ensure_containers(){
    [ -f "$WANT_RUNNING" ] || return 0
    _has_container && return 0
    _now=$(date +%s)
    [ $(( _now - _up_try_ts )) -lt 180 ] && return 0
    _up_try_ts=$_now
    ### 镜像没就绪时不要空跑（compose 会同步拉 2GB，把 up 卡住）：有拉取进程在跑就等它。
    if [ -f "$VAR_DIR/pull.pid" ] && kill -0 "$(cat "$VAR_DIR/pull.pid" 2>/dev/null)" 2>/dev/null; then
        log "容器尚未创建，镜像仍在下拉中 → 等待下拉完成"
        return 0
    fi
    log "容器不存在（启用只会 compose start，永远起不来）→ 主动创建：docker compose up -d"
    _out="$( cd "$APP_DIR/docker" 2>/dev/null && docker compose -p androidemu up -d 2>&1 )"
    echo "$_out" | tail -5 >> "$VAR_DIR/docker_up_retry.log" 2>/dev/null
    if _has_container; then
        log "容器已创建 → 应用中心的「启用」现在可以正常工作了"
    else
        log "容器创建仍失败，5 分钟后重试（详情见 $VAR_DIR/docker_up_retry.log）"
        echo "[$(date '+%F %T')] up 失败：$(echo "$_out" | tail -3 | tr '\n' ' ')" >> "$VAR_DIR/docker_up_retry.log" 2>/dev/null
    fi
}

deactivate_cleanup(){
    log "主容器连续 ${_down_secs:-300}s 未运行 → 判定为应用已停用：停画面服务、清理其余守护（本看护保留，等启用后自动复原）"
    docker stop "$C_WEB" >/dev/null 2>&1 || true
    ### 只清本应用自己的进程：必须带应用路径前缀，否则同机其它应用（如 opencode 的
    ### gateway_amd64）会被同名匹配误杀。APP_DIR 与真实路径两种前缀都要覆盖
    ### （实测同一台机器上两者并存：网关/agent 循环跑在真实路径下）。
    ### 保留自己：启用时飞牛不保证调用 cmd/main start（实测多次只做 compose up），
    ### 若本看护也退出，就没有任何东西把网关/音频/ADB 拉回来 → 门户 502、ADB 断。
    for _pre in "$APP_DIR" "$_APP_REAL" "/var/apps/androidemu/target"; do
        [ -n "$_pre" ] || continue
        for _rel in "scripts/fix_keystore.sh" "server/audio_fix.py" \
                    "scripts/redroid_adb_forward.sh" "scripts/agent_autodeploy.sh" \
                    "scripts/webrtc_watchdog.sh" \
                    "server/gateway_amd64" "server/gateway_arm64"; do
            ps -eo pid,args 2>/dev/null | grep -F "$_pre/$_rel" | grep -v grep | awk '{print $1}' | while read -r _p; do
                [ "$_p" = "$_SELF_PID" ] && continue
                kill -9 "$_p" 2>/dev/null || true
            done
        done
    done
    ### agent_autodeploy 的常驻循环是 `bash -c while :; do ... scripts/agent_autodeploy.sh ...`，
    ### 命令行里脚本名出现在 bash -c 的字符串中，上面的按前缀匹配可能对不上（实测漏杀），
    ### 这里再按「脚本名 + 应用路径」双重条件兜底清一次。
    ### 3.9.4：把 /var/apps/androidemu/target 软链接别名也纳入，避免同一循环以两种路径
    ### 并存时漏杀（实测停用后仍留了一份 高权限循环）。
    ps -eo pid,args 2>/dev/null | grep -F "scripts/agent_autodeploy.sh" \
        | grep -E "($APP_DIR|$_APP_REAL|/var/apps/androidemu/target)" | grep -v grep | awk '{print $1}' | while read -r _p; do
        [ "$_p" = "$_SELF_PID" ] && continue
        kill -9 "$_p" 2>/dev/null || true
    done
    rm -f "$PIDFILE" 2>/dev/null || true
    ### 注意：不 exit。停在休眠态，每轮只做一次 docker inspect；容器回来后由
    ### ensure_helpers 把网关/音频/ADB/agent 全部还原。
    _dormant=1
}

### 启用后复原：容器在跑就把缺失的辅助守护补回来（每 5 分钟最多执行一次）
### 依赖上面已定义的 _APP_REAL / _app_alive（两种路径前缀都认）。
_ensure_ts=0
_gw_restart_ts=0
ensure_helpers(){
    ### 3.9.9：确保投屏核心进程能启动 —— app_process 副本 + 最小能力 + bind mount。
    ### 上游 agent 会把自己降权到 shell(2000)，而 redroid 的 app_process 在非 系统身份下
    ### 会 abort（chown/chmod dalvik-cache 无权限），细节见 scripts/app_process_caps.sh。
    ### 这里每轮做一次幂等检查（已挂载时只有一次 docker exec，开销很小）。
    if [ -f "$APP_DIR/scripts/app_process_caps.sh" ] && ! pkg_files_fresh; then
        TRIM_PKGVAR="$VAR_DIR" TRIM_APPDEST="$APP_DIR" \
            bash "$APP_DIR/scripts/app_process_caps.sh" --runtime >/dev/null 2>&1 || true
    fi
    ### 3.9.9：系统导航条修复 —— 镜像的导航栏 overlay 全部未启用，导航条按错误
    ### 默认高度绘制且 inset 不一致，会盖住应用底部控件（实测暂停键点不了）。
    ### 脚本内部幂等：已修复时只有一次 docker exec 检查；安卓未启动完成直接退出。
    if [ -f "$APP_DIR/scripts/fix_navbar.sh" ]; then
        TRIM_PKGVAR="$VAR_DIR" TRIM_APPDEST="$APP_DIR" \
            bash "$APP_DIR/scripts/fix_navbar.sh" --runtime >/dev/null 2>&1 || true
    fi
    ### 3.9.4：画面服务容器缺失时补建（放在 5 分钟限频之前 —— docker inspect 开销很小，
    ### 这一步决定面板能否打开，值得每轮都确认）。
    ### 实测（2026-11-01 停用→启用）：飞牛的「启用」只执行 compose start，只能启动**已存在**
    ### 的容器；画面服务容器缺失时它不会补建，而 _has_container 只看安卓容器 —— 安卓还在
    ### 就不会触发 ensure_containers → 8443 一直无响应、应用中心点开是白屏。
    ### 【3.9.4 修正】补建必须以「应用处于运行态」为前提：用户点停用时，画面容器先退出、
    ### 安卓容器还在优雅停止中，此时若无条件补建，会把刚停掉的容器重新拉起来 ——
    ### 实测表现为「停用不彻底 + 容器反复重建」。这里用安卓容器是否 running 作为判据。
    ### 3.9.9：升级/重装窗口内不补建（这里的 compose up 正是升级撞车的直接来源，
    ### 见 pkg_files_fresh 注释）。窗口外行为不变。
    if pkg_files_fresh; then
        log "升级/重装窗口：跳过画面服务容器补建"
    elif docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null | grep -q true; then
        if ! docker inspect "$C_WEB" >/dev/null 2>&1; then
            log "画面服务容器缺失 → 按 compose 补建"
            ( cd "$APP_DIR/docker" 2>/dev/null && docker compose -p androidemu up -d webrtc ) \
                >>"$VAR_DIR/docker_up_retry.log" 2>&1 || true
            if docker inspect "$C_WEB" >/dev/null 2>&1; then
                log "画面服务容器已补建"
            else
                log "画面服务补建失败（详情见 $VAR_DIR/docker_up_retry.log）"
            fi
        fi
    fi
    ### 3.9.7：网关巡检每轮都做（原被 300 秒节流挡住，网关一挂最长 5 分钟
    ### 无人拉起，飞牛统一网关反代到死 socket 就吐裸「Bad Gateway」）。
    ### 同时按架构选二进制（ARM 原来无条件用 amd64）+ 增加死 socket 检测。
    _gw_arch="$(uname -m 2>/dev/null)"
    case "$_gw_arch" in
        aarch64|arm64) _gw_bin="$APP_DIR/server/gateway_arm64" ;;
        *)             _gw_bin="$APP_DIR/server/gateway_amd64" ;;
    esac
    _gw_sock="$APP_DIR/app.sock"
    _gw_bad=0
    if ! _app_alive "server/$(basename "$_gw_bin") supervise"; then
        _gw_bad=1
        log "网关守护缺失 → 重新拉起（$(basename "$_gw_bin")）"
    elif [ -S "$_gw_sock" ]; then
        python3 - "$_gw_sock" <<'PY' 2>/dev/null || _gw_bad=1
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1)
try:
    s.connect(sys.argv[1]); s.close()
except Exception:
    sys.exit(1)
PY
        [ "$_gw_bad" = "1" ] && log "app.sock 死 socket → 清理并重启网关"
    fi
    if [ "$_gw_bad" = "1" ] && [ -x "$_gw_bin" ]; then
        _gw_now=$(date +%s)
        if [ $(( _gw_now - _gw_restart_ts )) -ge 30 ]; then
            _gw_restart_ts=$_gw_now
            rm -f "$_gw_sock" 2>/dev/null || true
            ( cd / && TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" "$_gw_bin" start >/dev/null 2>&1 & ) || true
        fi
    fi
    _now=$(date +%s)
    [ $(( _now - _ensure_ts )) -lt 300 ] && return 0
    _ensure_ts=$_now
    ### 音频守护
    if [ -x "$APP_DIR/server/audio_fix.py" ] && ! _app_alive "server/audio_fix.py watchdog"; then
        log "音频守护缺失 → 重新拉起"
        TRIM_PKGVAR="$VAR_DIR" nohup python3 "$APP_DIR/server/audio_fix.py" start >/dev/null 2>&1 &
    fi
    ### ADB 转发
    if [ -x "$APP_DIR/scripts/redroid_adb_forward.sh" ] && ! _app_alive "scripts/redroid_adb_forward.sh supervise"; then
        log "ADB 转发守护缺失 → 重新拉起"
        TRIM_PKGVAR="$VAR_DIR" nohup bash "$APP_DIR/scripts/redroid_adb_forward.sh" install >/dev/null 2>&1 &
    fi
}

supervise_loop(){
    log "开机守护启动（pid=$$，每 ${INTERVAL}s 巡检，卡住阈值 ${STUCK_SECS}s）"
    _down_max="${BG_DOWN_SECS:-300}"
    _dormant=0
    while :; do
        ### 3.9.9：局域网地址漂移自愈（实测 2026-11-14，群友多网卡机器）。
        ### 有线+无线双网卡时，换网/DHCP 变址后 compose 里的 PUBLIC_IP 仍是旧网段地址：
        ### 客户端能连 3478（监听 0.0.0.0），但拿到的中继地址不可达 →
        ### agent.log 表现为「连上 30 秒后 ICE failed」，turnserver 报 allocation timeout。
        ### 判据从严：仅当 ① 模式为 lan ② 旧值是私有地址 ③ 该地址已不在本机任何网卡上
        ### 才判定为残留并重放；每小时最多一次，避免反复重建容器打断投屏。
        _ipf="$VAR_DIR/.ipdrift_fix"
        _ipl=0
        [ -f "$_ipf" ] && _ipl=$(cat "$_ipf" 2>/dev/null || echo 0)
        case "${_ipl:-0}" in ''|*[!0-9]*) _ipl=0 ;; esac
        if [ $(( $(date +%s) - _ipl )) -ge 3600 ]; then
            _mode_now="$(sed -n 's/^MODE=//p' "$VAR_DIR/net.conf" 2>/dev/null | head -n1)"
            _pub_ip="$(sed -n 's/^[[:space:]]*-[[:space:]]*PUBLIC_IP=//p' "$APP_DIR/docker/docker-compose.yaml" 2>/dev/null | head -n1 | tr -d ' \r')"
            _cur_ip="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
            [ -z "$_cur_ip" ] && _cur_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
            if [ "$_mode_now" = "lan" ] && [ -n "$_pub_ip" ] && [ -n "$_cur_ip" ] && [ "$_pub_ip" != "$_cur_ip" ]; then
                case "$_pub_ip" in
                    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
                        if ! ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$_pub_ip"; then
                            log "局域网地址漂移：compose 的 PUBLIC_IP=$_pub_ip 已不在本机网卡上，当前为 $_cur_ip → 按当前地址重放 lan 模式"
                            echo "$(date +%s)" > "$_ipf" 2>/dev/null || true
                            TRIM_PKGVAR="$VAR_DIR" TRIM_APPDEST="$APP_DIR" bash "$APP_DIR/scripts/net_mode.sh" lan >>"$LOG" 2>&1 || true
                        fi
                        ;;
                esac
            fi
        fi

        ### 3.9.8：每轮清掉 compose 重建残留的临时容器（<12位hex>_androidemu-*）。
        ### 这类容器停在 Created，不占端口，但会让用户看到「多个同名前缀容器」；
        ### 一旦被拉起就会抢 8443 与 agent 连接（官方与群友都截过图反馈）。
        ### 放在循环最前面：无论孤儿由哪条路径（安装/启用/守护自愈）产生，一分钟内必被清掉。
        for _orph in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^[0-9a-f]{12}_androidemu-' || true); do
            docker rm -f "$_orph" >/dev/null 2>&1 && log "清理 compose 临时容器：$_orph"
        done
        _up=0
        if _container_up; then
            _up=1
            rm -f "$DIS_SINCE" 2>/dev/null || true
            if [ "$_dormant" = "1" ]; then
                log "容器已恢复运行 → 解除休眠，补回辅助守护"
                _dormant=0
                _ensure_ts=0
            fi
            ensure_helpers
        else
            if ! _has_container; then
                ### 容器根本不存在（首次安装镜像未就绪 / 早期 up 失败）→ 不能算用户停用，
                ### 主动把容器建出来，否则应用中心的「启用」永远是 12005。
                ensure_containers
            fi
            _now=$(date +%s)
            _since=$(cat "$DIS_SINCE" 2>/dev/null)
            case "$_since" in
                ''|*[!0-9]*) echo "$_now" > "$DIS_SINCE" 2>/dev/null || true ;;
                *)
                    _down_secs=$(( _now - _since ))
                    if [ "$_down_secs" -ge "$_down_max" ] && [ "$_dormant" = "0" ] && _has_container; then
                        deactivate_cleanup
                    fi
                    ;;
            esac
        fi
        # 休眠态（应用已停用）不做巡检；容器明确停止时也不做——此时 boot_completed、
        # harden_system、adbd 之类的检查必然失败，只会往日志里刷「OCI runtime exec failed」
        # 这类噪音，对排查没有帮助。等容器回来（created/restarting/running）再恢复巡检。
        if [ "$_dormant" != "1" ] && [ "$_up" = "1" ]; then once || true; fi
        rotate_logs || true
        sleep "$INTERVAL"
    done
}

case "${1:-}" in
    once) once ;;
    start)
        # 清理旧实例（按命令行精确匹配，不误伤自身）
        for _p in $(ps -eo pid,args 2>/dev/null | grep -F "boot_guard.sh" | grep -E 'supervise|start' | grep -v grep | awk '{print $1}'); do
            [ "$_p" = "$$" ] && continue
            kill -9 "$_p" 2>/dev/null || true
        done
        ### 3.9.2：pid 文件不可写（历史 系统属主）时退化到 /tmp，不要因为写不进 pid
        ### 就打印 Permission denied 并让整个启动看似失败。
        if [ ! -w "$(dirname "$PIDFILE")" ] 2>/dev/null || { [ -e "$PIDFILE" ] && [ ! -w "$PIDFILE" ]; }; then
            PIDFILE="/tmp/androidemu_boot_guard.$(id -u).pid"
        fi
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
            echo "boot_guard: 已在运行（pid $(cat "$PIDFILE")）"; exit 0
        fi
        nohup bash "$0" supervise >>"$LOG" 2>&1 &
        echo $! > "$PIDFILE" 2>/dev/null || true
        echo "boot_guard: 已启动（pid $!）"
        ;;
    stop)
        if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true; fi
        for _p in $(ps -eo pid,args 2>/dev/null | grep -F "boot_guard.sh" | grep supervise | grep -v grep | awk '{print $1}'); do
            kill -9 "$_p" 2>/dev/null || true
        done
        rm -f "$PIDFILE" 2>/dev/null || true
        echo "boot_guard: 已停止"
        ;;
    status)
        _pid=""
        [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null && _pid=$(cat "$PIDFILE")
        echo "boot_guard: ${_pid:+running (pid $_pid)}${_pid:-not running}"
        echo "容器 $C: $(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null || echo 未知) / boot_completed=$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')"
        echo "GPU 回退标记: $([ -f "$MARK" ] && echo 已回退 || echo 未回退)"
        echo "诊断文件: $STATUS $([ -f "$STATUS" ] && echo "($(date -r "$STATUS" '+%F %T' 2>/dev/null))")"
        echo "--- 日志尾部 ---"; tail -8 "$LOG" 2>/dev/null || echo "(无)"
        ;;
    supervise)
        ### 3.9.2：真正的单实例锁。PID 文件在并发启动时会被互相覆盖，
        ### 实测升级后会同时跑起两个守护，各自触发 harden_system 重启容器。
        if command -v flock >/dev/null 2>&1; then
            ### 3.9.2 修正：锁文件若因属主/权限打不开（例如历史 高权限进程留下的），
            ### fd 8 根本没建立，`flock -n 8` 必然失败 → 误判"已有实例"直接退出，
            ### 表现为守护怎么都起不来（实测：boot_guard.pid/lock 属主是系统账号）。
            ### 现在锁打不开就退化为"不锁"，并写日志；绝不能因此拒绝启动。
            if exec 8>"$VAR_DIR/boot_guard.lock" 2>/dev/null; then
                if ! flock -n 8 2>/dev/null; then
                    ### 3.9.2 补：僵尸锁 —— 本守护拉起的常驻子进程（fix_keystore.sh 等）
                    ### 会继承 fd 8，父进程退出/被杀后锁仍被它们持有，新实例永远起不来
                    ### （实测 2026-10-30：父进程已不在，lsof 显示 fix_keystore.sh 与 sleep 持有
                    ### boot_guard.lock，日志一直刷「已有实例在运行」，守护实际是停的）。
                    ### 判据：除自己与父进程外，没有第二个「本脚本 supervise」进程。
                    ### 不用 ps|grep 粗筛 —— su/setsid 等启动器的命令行里也带这段字符串，
                    ### 会把启动器当成第二个实例（实测就是这么误判的）。改用 /proc 比对参数：
                    ### argv[1] == 本脚本路径 且 argv[2] == supervise 才算。
                    _bgm=0
                    for _pd in /proc/[0-9]*; do
                        _pid=${_pd#/proc/}
                        [ "$_pid" = "$$" ] && continue
                        [ "$_pid" = "$PPID" ] && continue
                        _a2=$(tr '\0' '\n' < "$_pd/cmdline" 2>/dev/null | sed -n '2p')
                        _a3=$(tr '\0' '\n' < "$_pd/cmdline" 2>/dev/null | sed -n '3p')
                        if [ "$_a2" = "$APP_DIR/scripts/boot_guard.sh" ] && [ "$_a3" = "supervise" ]; then
                            _bgm=$((_bgm + 1))
                        fi
                    done
                    if [ "${_bgm:-0}" -gt 0 ]; then
                        echo "boot_guard: 已有实例在运行（flock 占用），退出"; exit 0
                    fi
                    exec 8>&-
                    _alt="${TMPDIR:-/tmp}/androidemu_boot_guard_$(id -u).lock"
                    if exec 8>"$_alt" 2>/dev/null && flock -n 8 2>/dev/null; then
                        echo "boot_guard: 检测到僵尸锁（持有者已非巡检进程），已切换备用锁 $_alt 继续运行"
                    else
                        echo "boot_guard: 备用锁不可用，本次不启用单实例锁"
                    fi
                fi
            else
                echo "boot_guard: 锁文件不可写（$VAR_DIR/boot_guard.lock），本次不启用单实例锁"
            fi
        fi
        supervise_loop
        ;;
    *) echo "用法：$0 {start|stop|status|once|supervise}"; exit 1 ;;
esac
exit 0
