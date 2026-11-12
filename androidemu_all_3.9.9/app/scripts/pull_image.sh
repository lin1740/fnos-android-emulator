#!/bin/bash
### ensure the redroid / webrtc images are present.
###

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
if [ -f "$APP_DIR/scripts/rtconf.sh" ]; then
    # shellcheck disable=SC1091
    . "$APP_DIR/scripts/rtconf.sh"
    rtconf_load
fi
### 兜底（rtconf.sh 缺失时仍保持历史默认行为）
: "${CANON_REDROID:=docker.fnnas.com/redroid/redroid:12.0.0-latest}"
: "${OFF_REDROID:=redroid/redroid:12.0.0-latest}"
: "${CANON_WEBRTC:=docker.fnnas.com/buutuu/scrcpy-over-webrtc:latest}"
: "${OFF_WEBRTC:=buutuu/scrcpy-over-webrtc:latest}"
### digest 锁定的由来（3.9.4）：此前 WEBRTC_DIGEST 默认为空且全树无赋值，
### 「按 digest 锁定」从未起效；安装/升级走 tag 拉取时会把镜像源上过期的 latest
### 拉回本地覆盖，用户会看到「发现新版本 v0.4.x（当前 v0.4.y）」。digest 内容寻址，
### 任何源拉到都一致，上游发新版时可用环境变量覆盖此值。
### 3.9.9：锁到 0.4.4 多架构 index（实测内容：服务端 v0.4.4 git daa1fa8 + Agent v0.4.4，
### created 2026-11-08T06:15Z；docker.fnnas.com 与 daocloud 两源 digest 一致）。
### 相对 0.4.3 的可见变化：多机直连/设备抽屉重构、缩略图停流死锁根治、无硬件 Opus
### 编码器时自动降级纯视频、iOS/微信内置浏览器播放修复。entrypoint.sh 两版逐字节相同、
### /app 文件布局一致，本包的定制 entrypoint 无需改动。
: "${WEBRTC_REPO:=buutuu/scrcpy-over-webrtc}"
: "${WEBRTC_DIGEST:=sha256:dc6e62393e0e490c79410d8b41ef32896f7a384b97077e4b5cfb9804a4bb2cdd}"
COMPOSE_FILE="${TRIM_APPDEST:-/var/apps/androidemu/target}/docker/docker-compose.yaml"

### 候选加速源（2.0.81 简化）：固定顺序，不再测速排序。
### 第1优先飞牛自带加速 docker.fnnas.com（官方 CDN，审核自查也优先飞牛），第2优先 DaoCloud，
### 两个加速源都失败时，ensure_image 末尾会兜底试 Docker Hub 官方源。
### 3.9.4：加速源扩容（2026-11-01 从 NAS 实测筛选，死源已剔除）。
### 实测延迟：daocloud 0.18s / fnnas 0.22s / 1ms.run 0.29s / aityp 0.29s /
### dockerproxy 0.82s / xuanyuan 1.32s 可用；1panel.live、dockerhub.icu、hub.rat.dev 已失联不收录。
### 群友反馈"红容器拉不下来"的根因：默认只有 fnnas+daocloud 两源，fnnas 偶发 401、
### daocloud 限流、Docker Hub 官方在国内不可达，三条路全断即安装失败——多源兜底后不再单点。
MIRRORS="${ANDROIDEMU_MIRRORS:-docker.fnnas.com docker.m.daocloud.io docker.1ms.run docker.aityp.com dockerproxy.net docker.xuanyuan.me}"

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
PROGRESS_LOG="${PROGRESS_LOG:-}"
PULL_STALL="${PULL_STALL:-60}"        ### 日志多少秒没有增长就判定卡住（秒）
PULL_TIMEOUT="${PULL_TIMEOUT:-1800}"  ### 单个源最长拉取时间（秒）
PULL_NO_OUTPUT="${PULL_NO_OUTPUT:-30}" ### 多少秒还没有任何输出就判定无响应（秒）

### 拉取优先级（2.0.76 调整）：原来用 ionice 空闲级(-c 3) + nice 19，在 NAS 有其他负载时
### 拉取会被"饿死"，实测能慢好几倍；现在改成 best-effort 低优先级(-c 2 -n 7) + nice 10：
### 仍然是低优先级（不影响 NAS 网页/相册等前台使用），但不会被完全饿死。
PULL_NICE=""
if command -v ionice >/dev/null 2>&1; then PULL_NICE="ionice -c 2 -n 7"; fi
if command -v nice >/dev/null 2>&1; then PULL_NICE="$PULL_NICE nice -n 10"; fi

### 探测 docker pull 是否支持 --progress（旧版 CLI 不支持，带上会直接 unknown flag 失败）
PULL_PROGRESS=""
if docker pull --help 2>&1 | grep -q -- '--progress'; then
    PULL_PROGRESS="--progress=plain"
fi

logline(){
    ### 进度日志只用于面板展示；不可写时静默跳过，绝不影响拉取本身
    if [ -n "$PROGRESS_LOG" ] && [ -w "$PROGRESS_LOG" -o -w "$(dirname "$PROGRESS_LOG" 2>/dev/null)" ]; then
        echo "[$(date '+%F %T')] $*" >> "$PROGRESS_LOG" 2>/dev/null || true
    fi
    echo "[$(date '+%F %T')] $*"
}

### 并发探测各加速源延迟，按延迟升序输出源名（不可达的排最后）
probe_mirrors(){
    ### 3.9.5 重写：按「实际下载速度」实测选源（旧版只测 /v2/ 延迟、只排序不淘汰）。
    ### 策略（用户 2026-11-03 指定）：
    ###   · 飞牛源可用（实测能完成拉取且耗时达标）→ 只保留飞牛一个源，其余全砍
    ###   · 飞牛不可用/太慢 → 其余源并行实测，按耗时升序只保留最快的 3 个，
    ###     慢的、超时的（没有用的）全部淘汰
    ###   · 全部不可用 → 返回最快的 2 个兜底（总得有源可试）
    ### 实测方式：对每个源真实 docker pull 一个 2MB 小镜像（busybox:1.36.1）计时，
    ### 拉取前先删该源同名缓存，避免「本地已有秒回」造成假速度；结果缓存 10 分钟。
    local tmp cache m t0 t1 _t _m out FN_BASE="busybox:1.36.1"
    cache="$VAR_DIR/mirror_speed.cache"
    if [ -f "$cache" ]; then
        local _age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
        if [ "$_age" -lt 600 ] 2>/dev/null; then
            cat "$cache" 2>/dev/null
            return 0
        fi
    fi
    tmp="/tmp/.androidemu-speed.$$"
    mkdir -p "$tmp" 2>/dev/null || { echo "$MIRRORS"; return 0; }
    _speed_one(){
        local s="$1" out="$2" nm t0 t1
        case "$s" in
            ""|docker.io) nm="$FN_BASE" ;;
            *) nm="$s/library/$FN_BASE" ;;
        esac
        docker rmi -f "$nm" >/dev/null 2>&1
        t0=$(date +%s)
        if timeout 25 docker pull "$nm" >/dev/null 2>&1; then
            t1=$(( $(date +%s) - t0 ))
            echo "$t1 $s" > "$out/$s" 2>/dev/null || true
        else
            echo "999 $s" > "$out/$s" 2>/dev/null || true
        fi
    }
    ### 第一步：先测飞牛（用户指定：飞牛可用则只用飞牛）
    _speed_one "docker.fnnas.com" "$tmp"
    read -r _t _m < "$tmp/docker.fnnas.com" 2>/dev/null || true
    if [ -n "${_t:-}" ] && [ "${_t:-999}" -le 15 ] 2>/dev/null; then
        printf '%s\n' "docker.fnnas.com" | tee "$cache" >/dev/null
        logline "镜像源实测：飞牛源 ${_t}s 可用 → 按策略只保留飞牛源" >&2
        rm -rf "$tmp" 2>/dev/null || true
        return 0
    fi
    logline "镜像源实测：飞牛源不可用或过慢（${_t:-超时}s），并行实测其余源…" >&2
    ### 第二步：飞牛不可用 → 并行实测其余源，速度优先
    for m in $MIRRORS; do
        [ "$m" = "docker.fnnas.com" ] && continue
        ( _speed_one "$m" "$tmp" ) &
    done
    wait
    out=$(cat "$tmp"/* 2>/dev/null | sort -n | awk '$1<999 {print $2}' | head -3)
    if [ -z "$out" ]; then
        ### 全部超时：保留耗时最短的 2 个兜底（哪怕超时也按耗时排）
        out=$(cat "$tmp"/* 2>/dev/null | sort -n | awk '{print $2}' | head -2)
    fi
    if [ -n "$out" ]; then
        logline "镜像源实测结果（保留最快的，慢源已淘汰）：$(echo $out | tr '\n' ' ')" >&2
    fi
    printf '%s\n' $out | tee "$cache" >/dev/null
    rm -rf "$tmp" 2>/dev/null || true
}

### 拉取单个源：带"无输出/无进度/超时"三类保护。
### 返回 0 成功；2 无响应或卡住（应换源）；3 超时；其它为 docker pull 自身退出码。
pull_one(){
    local cand="$1" plog pid t0 now sz prev last_change hard zero_dl slow_dl sz0 rc size
    plog="$PROGRESS_LOG"
    [ -n "$plog" ] || plog="/tmp/.androidemu-pull.$$.log"
    : > "$plog" 2>/dev/null || plog="/tmp/.androidemu-pull.$$.log"
    logline "开始拉取：$cand"
    t0=$(date +%s); last_change=$t0; prev=-1
    hard=$(( t0 + PULL_TIMEOUT )); zero_dl=$(( t0 + PULL_NO_OUTPUT )); slow_dl=$(( t0 + 60 )); sz0=0
    # shellcheck disable=SC2086
    ( $PULL_NICE docker pull $PULL_PROGRESS "$cand" >>"$plog" 2>&1 ) &
    pid=$!
    sz0=$(stat -c %s "$plog" 2>/dev/null || echo 0)
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        now=$(date +%s)
        sz=$(stat -c %s "$plog" 2>/dev/null || echo 0)
        if [ "$sz" != "$prev" ]; then prev="$sz"; last_change="$now"; fi
        if [ "$sz" = "0" ] && [ "$now" -ge "$zero_dl" ]; then
            logline "$PULL_NO_OUTPUT 秒无任何输出，判定 $cand 无响应，换源"
            kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 2
        fi
        if [ "$sz" != "0" ] && [ $(( now - last_change )) -ge "$PULL_STALL" ]; then
            logline "$cand 连续 ${PULL_STALL} 秒无进度，判定卡住，换源"
            kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 2
        fi
        if [ "$now" -ge "$slow_dl" ] && [ $(( sz - sz0 )) -lt 3000 ]; then
            logline "$cand 60秒内日志仅增长 $(( sz - sz0 )) 字节，判定为慢速源（实测下载约几十KB/s），换源"
            kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 2
        fi
        if [ "$now" -ge "$hard" ]; then
            logline "$cand 超过 $(( PULL_TIMEOUT / 60 )) 分钟仍未完成，换源"
            kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 3
        fi
    done
    wait "$pid"; rc=$?
    if [ "$rc" = "0" ]; then
        size=$(docker image inspect -f '{{.Size}}' "$cand" 2>/dev/null || echo 0)
        case "$size" in ''|*[!0-9]*) size=0 ;; esac
        now=$(date +%s)
        if [ "$size" -gt 0 ] && [ $(( now - t0 )) -gt 0 ]; then
            logline "拉取完成：$cand（$(awk -v s="$size" -v d=$(( now - t0 )) 'BEGIN{printf "%.1f", s/1048576/d}') MB/s，耗时 $(( now - t0 )) 秒）"
        else
            logline "拉取完成：$cand（耗时 $(( now - t0 )) 秒）"
        fi
    fi
    return $rc
}

### $1=规范名(加速源) $2=官方名 $3=仓库路径 $4=中文名
ensure_image(){
    local CANON="$1" OFFICIAL="$2" REPO="$3" NAME="$4" SRC CAND ORDER
    docker image inspect "$CANON" >/dev/null 2>&1 && {
        docker image inspect "$OFFICIAL" >/dev/null 2>&1 || docker tag "$CANON" "$OFFICIAL" 2>/dev/null || true
        logline "镜像已存在，跳过拉取：$CANON"
        return 0
    }
    docker image inspect "$OFFICIAL" >/dev/null 2>&1 && {
        docker tag "$OFFICIAL" "$CANON" 2>/dev/null || true
        docker image inspect "$CANON" >/dev/null 2>&1 && return 0
    }
    ### 排序策略（2026-11-01 定稿）：飞牛源永远排第一（官方 CDN，审核自查也认它），
    ### 其余加速源按实测延迟从快到慢跟随；某源拉取失败/卡住由 pull_one 的
    ### 无输出/慢速/总超时三类熔断换下一个，不会死等。
    ### 3.9.4：优先级定稿 —— 飞牛源 → 用户在「加速源设置」里自配的源 → 内置公共源（按实测延迟）。
    ### 群友场景复盘：用户自配了私有/更快的加速源，但本脚本此前只用自己的内置清单，
    ### 自配源被完全无视；现读取 /etc/docker/daemon.json 的 registry-mirrors（飞牛该设置
    ### 的实际落点），去掉协议头后插入排序。自配源与内置源合并去重后统一参与实测排序。
    ### 官方名兜底拉取时 Docker 守护进程也会自动套用用户自配源，双保险。
    USER_MIRRORS=""
    if [ -r /etc/docker/daemon.json ]; then
        USER_MIRRORS=$(python3 -c 'import json,sys
try:
    ms = json.load(open(sys.argv[1])).get("registry-mirrors") or []
    out = []
    for m in ms:
        m = str(m).strip().rstrip("/")
        m = m.split("://", 1)[-1]
        if m and "/" not in m:
            out.append(m)
    print(" ".join(out))
except Exception:
    pass' /etc/docker/daemon.json 2>/dev/null)
    fi
    logline "用户自配加速源：${USER_MIRRORS:-（无，使用内置公共源）}"
    ### 自配源与内置公共源合并后一起参与实测延迟排序（速度优先对自配源同样生效）。
    [ -n "$USER_MIRRORS" ] && MIRRORS="$MIRRORS $USER_MIRRORS"
    logline "按实测延迟排序加速源（$NAME；飞牛源固定优先）…"
    ORDER=$(probe_mirrors)
    [ -n "$ORDER" ] || ORDER="$MIRRORS"
    ### 3.9.5：probe 结果即最终顺序（内部已按「飞牛优先/速度淘汰」策略裁剪），
    ### 不再强制把所有源拼回来 —— 砍掉的慢源就是不用。
    ORDER=$(printf '%s\n' $ORDER | awk '!seen[$0]++' | tr '\n' ' ')
    logline "加速源顺序：$ORDER"
    for SRC in $ORDER; do
        CAND="$SRC/$REPO"
        if pull_one "$CAND"; then
            docker image inspect "$CAND" >/dev/null 2>&1 || continue
            [ "$CAND" != "$CANON" ] && docker tag "$CAND" "$CANON" 2>/dev/null || true
            docker tag "$CAND" "$OFFICIAL" 2>/dev/null || true
            if docker image inspect "$CANON" >/dev/null 2>&1; then
                logline "镜像就绪：$CANON（来源 $CAND）"
                echo "$CAND" > "${VAR_DIR}/mirror.used" 2>/dev/null || true
                return 0
            fi
        fi
    done
    ### 最后再试一次 Docker Hub 官方名（没有加速源可用时）
    if pull_one "$REPO"; then
        docker tag "$REPO" "$CANON" 2>/dev/null || true
        docker image inspect "$CANON" >/dev/null 2>&1 && {
            logline "镜像就绪：$CANON（来源 Docker Hub 官方）"
            echo "$REPO" > "${VAR_DIR}/mirror.used" 2>/dev/null || true
            return 0
        }
    fi
    logline "所有加速源与 Docker Hub 官方源均失败（$NAME）。"
    logline "        若处于晚间时段（约 19:00~24:00），也可能是国际链路拥塞/源限速所致，可稍后或白天重试。"
    logline "        可在飞牛「Docker → 镜像仓库 → 设置 → 加速源设置」中确认 registry-mirrors，"
    logline "        或用环境变量 ANDROIDEMU_MIRRORS 指定自己的加速源后重试。"
    return 1
}

ensure_redroid_image(){
    ### 3.9.7：先在本机按「redroid 仓库 + 12.x tag」宽松认领用户预下载的镜像。
    ### 群友实测场景：手动 docker pull 了 redroid:12.0.0 或带加速源前缀的等价 tag，
    ### 但 ensure_image 只认 CANON/OFFICIAL 两个精确名，认不出来就去联网拉取；
    ### 拉不动时整个安装失败，页面停在 Bad Gateway。这里命中即 retag 就绪。
    local _hit
    _hit=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
             | grep -v '<none>' \
             | grep -iE '(^|/)redroid(/redroid)?:12(\.|$|-)' | head -1)
    if [ -n "$_hit" ]; then
        docker tag "$_hit" "$CANON_REDROID" 2>/dev/null || true
        docker tag "$_hit" "$OFF_REDROID" 2>/dev/null || true
        if docker image inspect "$CANON_REDROID" >/dev/null 2>&1; then
            logline "本机已有 redroid 镜像，直接认领：$_hit → $CANON_REDROID"
            echo "$_hit" > "${VAR_DIR}/mirror.used" 2>/dev/null || true
            return 0
        fi
    fi
    ensure_image "$CANON_REDROID" "$OFF_REDROID" "$OFF_REDROID" "Redroid Android 系统镜像"
}

ensure_webrtc_image(){
    ### 3.9.4 守卫（2026-11-02 用户实测「修好又回退」的最终解法）：
    ### 只要本机已经存在锁定版本的内容（按 RepoDigest 匹配），第一件事就是把 compose
    ### 使用的 tag 纠正过去并直接返回 —— 不再进入任何拉取分支。
    ### 原因：此前把 digest 判断放在拉取流程内部，一旦该分支因环境差异没走到，就会
    ### 回退 tag 链把加速源上过期的 latest（0.4.1）拉回来覆盖，表现为「修好后过一会
    ### 儿又变回旧版」。无条件前置 pin 让任何调用路径（安装/启用/看板一键拉取/看护）
    ### 都不可能再回退。
    if [ -n "${WEBRTC_DIGEST:-}" ] && [ -n "${CANON_WEBRTC:-}" ]; then
        _pin_id=$(docker images --digests --format '{{.Digest}} {{.ID}}' 2>/dev/null \
                    | awk -v d="$WEBRTC_DIGEST" '$1==d {print $2; exit}')
        if [ -n "$_pin_id" ]; then
            _canon_id=$(docker image inspect -f '{{.Id}}' "$CANON_WEBRTC" 2>/dev/null | sed 's/^sha256://' | cut -c1-12)
            if [ "$_canon_id" != "$_pin_id" ]; then
                docker tag "$_pin_id" "$CANON_WEBRTC" 2>/dev/null || true
                docker tag "$_pin_id" "${OFF_WEBRTC:-buutuu/scrcpy-over-webrtc:latest}" 2>/dev/null || true
                docker tag "$_pin_id" "${CACHE_WEBRTC:-androidemu-cache/webrtc:latest}" 2>/dev/null || true
                logline "画面服务 tag 已纠正为锁定版本内容（$_pin_id → $CANON_WEBRTC）"
            fi
            return 0
        fi
    fi
    ### 3.9.1：digest 锁定 —— 优先按 WEBRTC_DIGEST 精确拉取（内容与发布本包时实测一致），
    ### 拉到后回打到 CANON tag（docker tag 的目标不允许 @digest，故用 tag 形式承载内容）。
    ### digest 链全失败才回退旧的 tag 链（latest），保持离线/异常场景的旧行为。
    if [ -n "${WEBRTC_DIGEST:-}" ]; then
        ### 3.9.4 保险：先按内容摘要扫描本机全部镜像（不依赖源名探测结果）。
        ### 此前只按「候选源名 + 仓库 + digest」逐个 inspect，若该源在当前网络下探测
        ### 失败（被 probe_mirrors 剔除）就会漏掉本地已有的正确内容，回退 tag 链后
        ### CANON 仍指向旧版（2026-11-02 实测：本机明明有 018ea 内容，fnnas:latest
        ### 却一直是 0.4.1）。按 RepoDigest 全量扫描可彻底避免依赖源名。
        _pin_id=$(docker images --digests --format '{{.Digest}} {{.ID}}' 2>/dev/null \
                    | awk -v d="$WEBRTC_DIGEST" '$1==d {print $2; exit}')
        if [ -n "$_pin_id" ]; then
            docker tag "$_pin_id" "$CANON_WEBRTC" 2>/dev/null || true
            docker tag "$_pin_id" "$OFF_WEBRTC" 2>/dev/null || true
            logline "画面服务镜像按内容摘要命中本机（$_pin_id → $CANON_WEBRTC），锁定版本已就绪"
            return 0
        fi
        _pin_re="${WEBRTC_REPO}@${WEBRTC_DIGEST}"
        ### 本地已有同内容镜像（此前按 digest 拉过，RepoDigest 可能挂在任一镜像源名下）
        for SRC in $(probe_mirrors) ""; do
            if [ -n "$SRC" ]; then CAND="$SRC/$_pin_re"; else CAND="$_pin_re"; fi
            if docker image inspect "$CAND" >/dev/null 2>&1; then
                docker tag "$CAND" "$CANON_WEBRTC" 2>/dev/null || true
                logline "镜像已存在（digest 锁定）：$CAND"
                return 0
            fi
        done
        ### 逐源按 digest 拉取（内容寻址，哪个源拉到都一样）
        for SRC in $(probe_mirrors) ""; do
            if [ -n "$SRC" ]; then CAND="$SRC/$_pin_re"; else CAND="$_pin_re"; fi
            logline "按 digest 拉取：$CAND"
            if pull_one "$CAND"; then
                docker image inspect "$CAND" >/dev/null 2>&1 || continue
                docker tag "$CAND" "$CANON_WEBRTC" 2>/dev/null || true
                logline "镜像就绪（digest 锁定）：$CANON_WEBRTC（来源 $CAND）"
                echo "$CAND" > "${VAR_DIR}/mirror.used" 2>/dev/null || true
                return 0
            fi
        done
        logline "按 digest 拉取失败，回退标签方式拉取（latest）"
    fi
    ensure_image "$CANON_WEBRTC" "$OFF_WEBRTC" "$OFF_WEBRTC" "WebRTC 云手机画面服务镜像"
}

GMS_IMAGE_BASE="${GMS_IMAGE_BASE:-ghcr.io/lin1740/androidemu-gms}"
### 3.9.7：下面多处 `$GMS_DOCKERHUB_IMAGE` 引用，但脚本开了 set -u 且从未定义该变量，
### 实测直接报「unbound variable」退出，GMS 永远装不上。给空默认值，
### 外部若显式提供仍会追加到候选源列表。
GMS_DOCKERHUB_IMAGE="${GMS_DOCKERHUB_IMAGE:-}"
ensure_gms_image(){
    local ARCH GMS_IMG GMS_TAG GMS_SOURCES SRC
    ARCH=$(uname -m 2>/dev/null)
    case "$ARCH" in
        x86_64|amd64) GMS_TAG="x86_64" ;;
        aarch64|arm64) GMS_TAG="arm64" ;;
        *) logline "不支持的架构: $ARCH，跳过GMS镜像拉取"; return 1 ;;
    esac
    GMS_IMG="${GMS_IMAGE_BASE}:${GMS_TAG}"
    # 已存在则跳过
    docker image inspect "$GMS_IMG" >/dev/null 2>&1 && {
        logline "GMS镜像已存在，跳过拉取：$GMS_IMG"
        return 0
    }
    # 多源fallback（国内镜像优先，速度快；官方GHCR兜底）
    # 南京大学GHCR镜像：ghcr.nju.edu.cn/用户名/镜像名:标签
    # DaoCloud GHCR代理：docker.m.daocloud.io/ghcr.io/用户名/镜像名:标签
    GMS_SOURCES="ghcr.nju.edu.cn/lin1740/androidemu-gms:${GMS_TAG} docker.m.daocloud.io/ghcr.io/lin1740/androidemu-gms:${GMS_TAG} ${GMS_IMG}"
    [ -n "$GMS_DOCKERHUB_IMAGE" ] && GMS_SOURCES="$GMS_SOURCES $GMS_DOCKERHUB_IMAGE"
    for SRC in $GMS_SOURCES; do
        logline "开始拉取GMS镜像：$SRC"
        if docker pull "$SRC" >/dev/null 2>&1; then
            [ "$SRC" != "$GMS_IMG" ] && docker tag "$SRC" "$GMS_IMG" 2>/dev/null || true
            logline "GMS镜像拉取完成：$GMS_IMG（来源：$SRC）"
            return 0
        else
            logline "GMS镜像拉取失败：$SRC，尝试下一个源"
        fi
    done
    logline "GMS镜像所有源均拉取失败，将在容器启动后由install_gms.sh重试"
    return 1
}
