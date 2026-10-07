#!/bin/bash
### ensure the redroid / webrtc images are present.
###
### 2.0.17 关键变化：compose 的「规范名」是加速源前缀（docker.m.daocloud.io/...）。
### 原因（本机实测）：Docker 的 registry-mirrors 机制对官方名 docker.io 镜像不生效——
### 即便配了加速器，官方名拉取仍会直连 registry-1.docker.io 并 context deadline exceeded；
### 而带加速源前缀的显式拉取是通的。故 compose 直接用加速源名，
### 本脚本把镜像准备好，并把「官方名」也打成别名（排障 / 回退 / 卸载清理都用得到）。
###
### 2.0.76 拉取源改进（发布者反馈"镜像下载时间太长"）：
###   ① 先并发测速：对每个加速源探测 /v2/ 的延迟（各 4 秒超时），按实测延迟从小到大排序，
###      最快的源最先拉；不可达的源直接排到最后，不再白等。
###   ② 取消原来的"整单 180 秒硬超时"——这是"怎么都下不完"的主因：2GB 镜像在 10MB/s 下
###      需要 3 分半，旧逻辑会把它当失败杀掉，换源后又从头开始。现在改为分级判定：
###        · 60 秒内日志仍为空        → 该源无响应，立即换源（快速失败）；
###        · 日志连续 90 秒没有增长   → 判定卡住，换源（含下载进度，故不会误杀正常拉取）；
###        · 否则最长给 30 分钟       → 让偏慢但稳定的源把镜像拉完。
###   ③ 记录实际速度（MB/s）并写入 $VAR_DIR/mirror.used，面板与日志都能看到用的是哪个源。

### 标准版镜像：redroid:12.0.0-latest
COMPOSE_FILE="${TRIM_APPDEST:-/var/apps/androidemu/target}/docker/docker-compose.yaml"
REDROID_TAG="12.0.0-latest"
CANON_REDROID="docker.fnnas.com/redroid/redroid:${REDROID_TAG}"
OFF_REDROID="redroid/redroid:${REDROID_TAG}"
CANON_WEBRTC="docker.fnnas.com/buutuu/scrcpy-over-webrtc:latest"
OFF_WEBRTC="buutuu/scrcpy-over-webrtc:latest"

### 候选加速源（2.0.81 简化）：固定顺序，不再测速排序。
### 第1优先飞牛自带加速 docker.fnnas.com（官方 CDN，审核自查也优先飞牛），第2优先 DaoCloud，
### 两个加速源都失败时，ensure_image 末尾会兜底试 Docker Hub 官方源。
MIRRORS="${ANDROIDEMU_MIRRORS:-docker.fnnas.com docker.m.daocloud.io}"

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
    local tmp m t
    tmp="/tmp/.androidemu-probe.$$"
    mkdir -p "$tmp" 2>/dev/null || { echo "$MIRRORS"; return 0; }
    for m in $MIRRORS; do
        (
            t=$(curl -s -o /dev/null -m 4 -w '%{time_total}' "https://$m/v2/" 2>/dev/null)
            case "$t" in ''|*[!0-9.]*) t=99 ;; esac
            echo "$t $m" > "$tmp/$m" 2>/dev/null || true
        ) &
    done
    wait
    cat "$tmp"/* 2>/dev/null | sort -n | awk '{print $2}'
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
    logline "按实测延迟排序加速源（$NAME）…"
    ORDER=$(probe_mirrors)
    [ -n "$ORDER" ] || ORDER="$MIRRORS"
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
    logline "        可在飞牛「Docker → 设置 → 镜像加速器」中确认 registry-mirrors，"
    logline "        或用环境变量 ANDROIDEMU_MIRRORS 指定自己的加速源后重试。"
    return 1
}

ensure_redroid_image(){
    ensure_image "$CANON_REDROID" "$OFF_REDROID" "$OFF_REDROID" "Redroid Android 系统镜像"
}

ensure_webrtc_image(){
    ensure_image "$CANON_WEBRTC" "$OFF_WEBRTC" "buutuu/scrcpy-over-webrtc:latest" "WebRTC 云手机画面服务镜像"
}
