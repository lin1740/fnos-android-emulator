#!/bin/bash
### data_location.sh — 让容器数据跟随「应用所在的存储空间」。
###
### 背景（发布者要求）：首次安装时希望用户能选择装在存储空间一还是二。
###   · 应用本体的安装位置由飞牛决定：manifest 的 install_type 留空即「安装时由用户选择
###     存储位置」；本应用已是空值，因此飞牛在有多个存储空间时会弹出选择。
###   · 但容器数据默认是 Docker 命名卷，落在 Docker 数据根（如 /vol1/docker/volumes），
###     不随应用所在空间走。本脚本把「首次安装」的数据改成 bind 挂载到应用自己的数据目录
###     （${TRIM_PKGVAR}/vol-data），从而与所选存储空间一致。
###
### 安全性（重要）：
###   · 只在「首次安装、且不存在既有命名卷数据」时切换为 bind 挂载；
###   · 一旦检测到既有安卓数据（androidemu-data 卷非空）→ 保持命名卷不动，绝不迁移、不丢数据；
###   · 目标目录不可写 → 保持命名卷并记录原因；
###   · 幂等：已切换过则直接退出。
set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"
DEST="$VAR_DIR/vol-data"
LOG="$VAR_DIR/data_location.log"
HELPER_IMG="${DATA_LOC_HELPER_IMG:-docker.fnnas.com/buutuu/scrcpy-over-webrtc:latest}"

mkdir -p "$VAR_DIR" 2>/dev/null || true
log(){ echo "[$(date '+%F %T')] $*" 2>/dev/null >> "$LOG" 2>/dev/null || true; }

[ -f "$COMPOSE" ] || { log "compose 不存在，跳过"; exit 0; }

### 幂等：已经切到应用空间内的目录
if grep -q "$DEST" "$COMPOSE" 2>/dev/null; then
    log "已在使用应用空间内的数据目录：$DEST（跳过）"
    exit 0
fi

### 既有数据保护：命名卷存在且有内容 → 保持原状
### 注意：测量失败时按「有数据」处理（宁可不动，也不冒丢数据的风险）。
if docker volume inspect androidemu-data >/dev/null 2>&1; then
    _sz=$(docker run --rm -v androidemu-data:/v --entrypoint sh "$HELPER_IMG" -c 'du -s /v 2>/dev/null | cut -f1' 2>/dev/null | tr -dc '0-9')
    if [ -z "$_sz" ]; then
        _cnt=$(docker run --rm -v androidemu-data:/v --entrypoint sh "$HELPER_IMG" -c 'ls -A /v 2>/dev/null | wc -l' 2>/dev/null | tr -dc '0-9')
        case "${_cnt:-}" in
            ''|0) [ -n "${_cnt:-}" ] && _sz=0 || _sz=1 ;;   ### 取不到一律当作有数据
            *)    _sz=1 ;;
        esac
    fi
    case "${_sz:-1}" in
        0) : ;;
        *) log "检测到既有安卓数据（${_sz}KB），保持 Docker 命名卷不迁移（避免风险）"; exit 0 ;;
    esac
fi

### 目标目录可写性
mkdir -p "$DEST/androidemu-data" "$DEST/webrtc-data" 2>/dev/null || {
    log "数据目录不可写：$DEST，保持 Docker 命名卷"
    exit 0
}

### 改写 compose：命名卷 → bind 挂载（保留顶层 volumes 声明，旧卷不删除，作为回退备份）
cp -f "$COMPOSE" "$COMPOSE.bak-dataloc" 2>/dev/null || true
sed -i "s#^\( *\)- androidemu-data:/data#\1- ${DEST}/androidemu-data:/data#" "$COMPOSE"
sed -i "s#^\( *\)- androidemu-webrtc-data:/app/data#\1- ${DEST}/webrtc-data:/app/data#" "$COMPOSE"

if grep -q "$DEST/androidemu-data" "$COMPOSE" && grep -q "$DEST/webrtc-data" "$COMPOSE"; then
    log "已启用应用空间内的数据目录：$DEST（应用数据将与本应用安装在同一存储空间）"
    echo "data_location: 数据目录已切换到应用所在存储空间：$DEST"
else
    cp -f "$COMPOSE.bak-dataloc" "$COMPOSE" 2>/dev/null || true
    log "compose 改写失败，已回滚为命名卷"
fi
exit 0
