#!/bin/bash
### install_gms.sh — 在标准版redroid容器中安装GMS（谷歌服务框架+Play商店）
### install_gms.sh — Install GMS (Google Mobile Services + Play Store) into standard redroid container
###
### 触发条件 / Trigger: $VAR_DIR/install_gms 文件存在且内容为 yes（由安装向导设置 / set by installation wizard）
### 安装完成后自动删除该标记文件，避免重复安装 / Marker is removed after installation to prevent re-install
###
### 流程 / Flow: 检测架构 → 拉取对应GMS镜像 → 创建临时容器提取文件 → 等待容器boot_completed → 复制到/system各分区 → 设置权限 → 重启容器 → 清理
###        Detect arch → Pull GMS image → Extract files from temp container → Wait boot_completed → Copy to partitions → Set permissions → Restart → Cleanup

set -u

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="${VAR_DIR}/gms_install.log"
MARKER="${VAR_DIR}/install_gms"
C="${CNAME:-androidemu-android}"
GMS_TMP="/tmp/androidemu_gms"

### GMS镜像地址配置 / GMS image configuration
### 推送到GHCR后替换为实际地址 / Replace with actual GHCR address after pushing
GMS_IMAGE_BASE="${GMS_IMAGE_BASE:-ghcr.io/lin1740/androidemu-gms}"
### 3.9.7：下面多处 `$GMS_DOCKERHUB_IMAGE` 引用，但脚本开了 set -u 且从未定义该变量，
### 实测直接报「unbound variable」退出，GMS 永远装不上。给空默认值，
### 外部若显式提供仍会追加到候选源列表。
GMS_DOCKERHUB_IMAGE="${GMS_DOCKERHUB_IMAGE:-}"

log() { echo "[$(date '+%F %T')] gms_install: $*" >> "$LOG" 2>/dev/null || true; }

### 检查标记文件 / Check marker
if [ ! -f "$MARKER" ]; then
    exit 0
fi
if [ "$(cat "$MARKER" 2>/dev/null | tr -d '\r\n ')" != "yes" ]; then
    exit 0
fi

### 3.9.7：已装就跳过。容器重建后 /system 会回退到镜像原始状态，标记仍在，
### 由 boot_guard 巡检重新触发本脚本；这里先看容器里到底有没有 GMS，避免重复装。
if docker exec "${C:-androidemu-android}" sh -c 'pm list packages 2>/dev/null | grep -q com.google.android.gms' >/dev/null 2>&1; then
    log "容器内已存在 GMS，跳过安装 / GMS already present, skipping"
    rm -f "${VAR_DIR}/install_gms_fails" 2>/dev/null || true
    exit 0
fi

log "检测到GMS安装请求，开始安装... / GMS install request detected, starting..."

### 3.9.4：GMS 安装失败的统一收尾 —— 记失败次数并决定是否重试。
### 原逻辑任何一步失败都直接删标记退出，用户选了 GMS 却永远装不上且无提示。
### 现改为：失败后保留标记，下次容器启动自动重试；连续 3 次失败才放弃
###（避免镜像一直拉不下来时每次开机都空耗）。计数文件随成功一并清理。
gms_fail_exit() {
    _gf="${VAR_DIR}/install_gms_fails"
    _gn=$(( $(cat "$_gf" 2>/dev/null || echo 0) + 1 ))
    echo "$_gn" > "$_gf" 2>/dev/null || true
    if [ "$_gn" -ge 3 ]; then
        log "GMS 安装已连续失败 $_gn 次，停止自动重试。排除网络/磁盘问题后，可向 $VAR_DIR/install_gms 写入 yes 重新触发"
        rm -f "$MARKER" "$_gf"
    else
        log "GMS 安装失败（第 $_gn/3 次），保留标记，下次容器启动将自动重试"
    fi
    exit 1
}


### 1. 检测系统架构 / Detect system architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        GMS_ARCH="x86_64"
        ;;
    aarch64|arm64|armv8*)
        GMS_ARCH="arm64"
        ;;
    *)
        log "错误：不支持的架构 $ARCH / Error: unsupported architecture $ARCH"
        gms_fail_exit
        ;;
esac
log "当前架构 / Current arch: $ARCH，使用 / using $GMS_ARCH 版本GMS镜像 / GMS image"

### 1.5 安卓版本 → 载体镜像 tag（3.9.2 多版本 GMS）：
###   Android 12 → 旧版 tag（:x86_64 / :arm64，保持历史行为与兼容）
###   其他版本   → 版本化 tag（:11-x86_64 / :13-x86_64 等，存在才可用；
###                 载体包未覆盖的"版本-架构"组合会在拉取失败时自动跳过，不阻塞启动）
### 3.9.4 修复：set -u 下直接引用未定义的 ANDROID_VER 会在「unbound variable」上崩掉
### 整个脚本（由 cmd/main 拉起时环境恰好带该变量才没暴露；手动/systemd 独立运行必崩）。
if [ -z "${ANDROID_VER:-}" ] && [ -f "$SCRIPT_DIR/rtconf.sh" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/rtconf.sh"
    rtconf_load >/dev/null 2>&1 || true
fi
ANDROID_VER="${ANDROID_VER:-${ANDROIDEMU_ANDROID_VER:-12}}"
if [ "$ANDROID_VER" = "12" ]; then
    GMS_TAG="$GMS_ARCH"
else
    GMS_TAG="${ANDROID_VER}-${GMS_ARCH}"
fi
log "GMS 载体 tag：${GMS_TAG}（Android $ANDROID_VER / $GMS_ARCH）"

### 2. 准备GMS文件（优先从镜像提取，其次用本地tar.gz兜底）
### Prepare GMS files (prefer image extraction, fallback to local tar.gz)
GMS_IMAGE="${GMS_IMAGE_BASE}:${GMS_TAG}"
GMS_TMP_CONTAINER="androidemu_gms_temp"

rm -rf "$GMS_TMP"
mkdir -p "$GMS_TMP"
chmod 777 "$GMS_TMP" 2>/dev/null || true

# 方法A：从GMS镜像提取 / Method A: Extract from GMS image
GMS_FROM_IMAGE=0
if command -v docker >/dev/null 2>&1; then
    if docker image inspect "$GMS_IMAGE" >/dev/null 2>&1; then
        log "GMS镜像已预下载，跳过拉取 / GMS image already pre-downloaded, skipping pull"
    else
        GMS_SOURCES="ghcr.nju.edu.cn/lin1740/androidemu-gms:${GMS_TAG} docker.m.daocloud.io/ghcr.io/lin1740/androidemu-gms:${GMS_TAG} ${GMS_IMAGE}"
        [ -n "$GMS_DOCKERHUB_IMAGE" ] && GMS_SOURCES="$GMS_SOURCES $GMS_DOCKERHUB_IMAGE"
        for SRC in $GMS_SOURCES; do
            log "正在拉取GMS镜像 / Pulling GMS image: $SRC ..."
            if docker pull "$SRC" >>"$LOG" 2>&1; then
                [ "$SRC" != "$GMS_IMAGE" ] && docker tag "$SRC" "$GMS_IMAGE" 2>/dev/null || true
                log "镜像拉取成功 / Image pulled successfully（来源/source: $SRC）"
                break
            else
                log "镜像拉取失败 / Image pull failed: $SRC，尝试下一个源 / trying next source"
            fi
        done
    fi
    # 镜像存在则创建临时容器并提取文件 / If image exists, create temp container and extract files
    if docker image inspect "$GMS_IMAGE" >/dev/null 2>&1; then
        docker rm -f "$GMS_TMP_CONTAINER" >/dev/null 2>&1 || true
        ### 3.9.4 修复：GMS 载体镜像为纯数据镜像（无 ENTRYPOINT/CMD），裸 create 报
        ### 「no command specified」导致提取从未成功、GMS 装不上且镜像永远留在本地。
        ### create 时不校验命令可执行性，补哑命令 true 即可建容器，export 照常导出。
        if docker create --name "$GMS_TMP_CONTAINER" "$GMS_IMAGE" >/dev/null 2>&1 \
           || docker create --name "$GMS_TMP_CONTAINER" "$GMS_IMAGE" true >/dev/null 2>&1; then
            log "正在从镜像提取GMS文件 / Extracting GMS files from image..."
            # 3.8.7修复：用docker export+管道tar解压，避免docker cp在/tmp创建子目录时permission denied
            if docker export "$GMS_TMP_CONTAINER" 2>>"$LOG" | tar -x -C "$GMS_TMP" gms/ 2>>"$LOG"; then
                # export出来的文件在gms/子目录下，移动到顶层
                if [ -d "$GMS_TMP/gms" ]; then
                    mv "$GMS_TMP/gms/"* "$GMS_TMP/" 2>/dev/null || true
                    rmdir "$GMS_TMP/gms" 2>/dev/null || true
                fi
                GMS_FROM_IMAGE=1
                log "从镜像提取成功 / Extracted from image successfully"
            else
                log "docker export提取失败，尝试docker cp单个文件方式 / docker export failed, trying docker cp single file..."
                # 兜底：尝试docker cp单个tar.gz文件（如果镜像里有的话）
                if docker cp "$GMS_TMP_CONTAINER:/gms_files.tar.gz" "$GMS_TMP/gms_files.tar.gz" >>"$LOG" 2>&1; then
                    tar -xzf "$GMS_TMP/gms_files.tar.gz" -C "$GMS_TMP" >>"$LOG" 2>&1
                    rm -f "$GMS_TMP/gms_files.tar.gz"
                    GMS_FROM_IMAGE=1
                    log "从镜像提取成功（tar.gz方式） / Extracted from image successfully (tar.gz method)"
                fi
            fi
            docker rm -f "$GMS_TMP_CONTAINER" >/dev/null 2>&1 || true
        fi
    else
        log "警告：所有镜像源均拉取失败，尝试本地包兜底 / Warning: all image sources failed, trying local package fallback"
    fi
fi

# 方法B：本地tar.gz兜底 / Method B: Local tar.gz fallback
if [ "$GMS_FROM_IMAGE" -eq 0 ]; then
    log "尝试本地GMS包 / Trying local GMS package..."
    GMS_TAR=""
    for F in "$VAR_DIR/gms_files_${GMS_ARCH}.tar.gz" "$VAR_DIR/gms_files.tar.gz" "$VAR_DIR"/gms*.tar.gz "$SCRIPT_DIR/gms_files_${GMS_ARCH}.tar.gz" "$SCRIPT_DIR/gms_files.tar.gz"; do
        if [ -f "$F" ]; then
            SIZE=$(stat -c%s "$F" 2>/dev/null || echo 0)
            if [ "$SIZE" -gt 10000000 ]; then
                GMS_TAR="$F"
                log "找到本地GMS包 / Found local GMS package: $F（$((SIZE/1024/1024))MB）"
                break
            fi
        fi
    done

    if [ -n "$GMS_TAR" ]; then
        log "正在解压本地GMS包 / Extracting local GMS package..."
        if ! tar -xzf "$GMS_TAR" -C "$GMS_TMP" 2>>"$LOG"; then
            log "错误：解压失败 / Error: extraction failed"
            gms_fail_exit
        fi
    else
        log "错误：镜像拉取失败且未找到本地GMS包 / Error: image pull failed and no local GMS package found"
        log "请检查网络连接，或手动准备GMS包放到 / Please check network, or manually prepare GMS package at: $VAR_DIR/"
        if [ "$GMS_ARCH" = "x86_64" ]; then
            log "x86_64 版 GMS 需从「与目标 Android 版本匹配」的 MindTheGapps 载体镜像提取（例如社区提供的 redroid+gapps 镜像）"
            log "参考命令 / Reference: docker create --name gms_extract <redroid+gapps 镜像> && docker cp gms_extract:/system ./gms && docker rm gms_extract && tar -czf gms_files_x86_64.tar.gz gms/"
        else
            log "arm64版本GMS下载地址 / arm64 GMS download: https://github.com/MindTheGapps/12.1.0-arm64/releases"
        fi
        gms_fail_exit
    fi
fi

# 验证提取的文件 / Verify extracted files
FILE_COUNT=$(find "$GMS_TMP" -type f 2>/dev/null | wc -l)
log "GMS文件准备完成 / GMS files ready: $FILE_COUNT 个文件 / files"
if [ "$FILE_COUNT" -lt 5 ]; then
    log "错误：GMS文件过少，可能提取失败 / Error: too few GMS files, extraction may have failed"
    gms_fail_exit
fi

log "目录结构 / Directory structure:"
ls -la "$GMS_TMP/" >> "$LOG" 2>&1

### 3. 等待容器运行并boot_completed / Wait for container running and boot_completed
log "等待容器启动 / Waiting for container to start..."
BOOT_OK=0
for _i in $(seq 1 120); do
    if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]; then
        if [ "$(docker exec -u 0 "$C" sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')" = "1" ]; then
            log "容器已boot_completed / Container boot_completed"
            BOOT_OK=1
            break
        fi
    fi
    sleep 2
done

if [ "$BOOT_OK" -eq 0 ]; then
    log "错误：等待容器boot_completed超时（240秒），GMS安装中止 / Error: boot_completed timeout (240s), GMS install aborted"
    log "容器状态 / Container status: $(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null || echo 'unknown')"
    log "请检查容器是否正常启动 / Please check if container started normally"
    # 不删除标记文件，下次容器启动后会重试
    exit 1
fi

### 4. 复制GMS文件到容器的各分区 / Copy GMS files to container partitions
log "正在复制GMS文件到容器 / Copying GMS files to container..."

# 兼容两种目录结构：直接在根目录 或 在 system/ 子目录下
# Support both layouts: files at the archive top level or under system/ subdirectory
if [ -d "$GMS_TMP/system" ]; then
    SRC_BASE="$GMS_TMP/system"
else
    SRC_BASE="$GMS_TMP"
fi

# product/priv-app - 核心GMS组件（GmsCore、Phonesky等）/ Core GMS components
if [ -d "$SRC_BASE/product/priv-app" ]; then
    for d in "$SRC_BASE"/product/priv-app/*/; do
        [ -d "$d" ] || continue
        dirname=$(basename "$d")
        log "  安装 / Installing product/priv-app/$dirname"
        docker cp "$d" "$C:/system/product/priv-app/" 2>>"$LOG"
    done
fi

# product/app - Google同步适配器 / Google sync adapters
if [ -d "$SRC_BASE/product/app" ]; then
    for d in "$SRC_BASE"/product/app/*/; do
        [ -d "$d" ] || continue
        dirname=$(basename "$d")
        log "  安装 / Installing product/app/$dirname"
        docker cp "$d" "$C:/system/product/app/" 2>>"$LOG"
    done
fi

# system_ext/priv-app - Google服务框架 / Google Services Framework
if [ -d "$SRC_BASE/system_ext/priv-app" ]; then
    for d in "$SRC_BASE"/system_ext/priv-app/*/; do
        [ -d "$d" ] || continue
        dirname=$(basename "$d")
        log "  安装 / Installing system_ext/priv-app/$dirname"
        docker cp "$d" "$C:/system/system_ext/priv-app/" 2>>"$LOG"
    done
fi

# product/etc/permissions
if [ -d "$SRC_BASE/product/etc/permissions" ]; then
    for f in "$SRC_BASE"/product/etc/permissions/*; do
        [ -f "$f" ] || continue
        docker cp "$f" "$C:/system/product/etc/permissions/" 2>>"$LOG"
    done
    log "  安装 / Installing product/etc/permissions"
fi

# product/etc/default-permissions
if [ -d "$SRC_BASE/product/etc/default-permissions" ]; then
    for f in "$SRC_BASE"/product/etc/default-permissions/*; do
        [ -f "$f" ] || continue
        docker cp "$f" "$C:/system/product/etc/default-permissions/" 2>>"$LOG"
    done
    log "  安装 / Installing product/etc/default-permissions"
fi

# product/etc/sysconfig
if [ -d "$SRC_BASE/product/etc/sysconfig" ]; then
    for f in "$SRC_BASE"/product/etc/sysconfig/*; do
        [ -f "$f" ] || continue
        docker cp "$f" "$C:/system/product/etc/sysconfig/" 2>>"$LOG"
    done
    log "  安装 / Installing product/etc/sysconfig"
fi

# product/etc/security/fsverity
if [ -d "$SRC_BASE/product/etc/security/fsverity" ]; then
    for f in "$SRC_BASE"/product/etc/security/fsverity/*; do
        [ -f "$f" ] || continue
        docker cp "$f" "$C:/system/product/etc/security/fsverity/" 2>>"$LOG"
    done
    log "  安装 / Installing product/etc/security/fsverity"
fi

# product/overlay
if [ -d "$SRC_BASE/product/overlay" ]; then
    for f in "$SRC_BASE"/product/overlay/*; do
        [ -f "$f" ] || continue
        docker cp "$f" "$C:/system/product/overlay/" 2>>"$LOG"
    done
    log "  安装 / Installing product/overlay"
fi

# product/framework
if [ -d "$SRC_BASE/product/framework" ]; then
    for f in "$SRC_BASE"/product/framework/*; do
        [ -f "$f" ] || continue
        docker cp "$f" "$C:/system/product/framework/" 2>>"$LOG"
    done
    log "  安装 / Installing product/framework"
fi

# product/lib 和 lib64 / product/lib and lib64
if [ -d "$SRC_BASE/product/lib" ]; then
    for f in "$SRC_BASE"/product/lib/*; do
        [ -f "$f" ] || continue
        docker cp "$f" "$C:/system/product/lib/" 2>>"$LOG"
    done
    log "  安装 / Installing product/lib"
fi
if [ -d "$SRC_BASE/product/lib64" ]; then
    for f in "$SRC_BASE"/product/lib64/*; do
        [ -f "$f" ] || continue
        docker cp "$f" "$C:/system/product/lib64/" 2>>"$LOG"
    done
    log "  安装 / Installing product/lib64"
fi

# system_ext/etc/permissions
if [ -d "$SRC_BASE/system_ext/etc/permissions" ]; then
    for f in "$SRC_BASE"/system_ext/etc/permissions/*; do
        [ -f "$f" ] || continue
        docker cp "$f" "$C:/system/system_ext/etc/permissions/" 2>>"$LOG"
    done
    log "  安装 / Installing system_ext/etc/permissions"
fi

log "文件复制完成 / File copy completed"

### 5. 设置文件权限 / Set file permissions
log "正在设置权限 / Setting permissions..."
docker exec -u 0 "$C" sh -c '
# 设置目录权限 / Set directory permissions
find /system/product/priv-app -type d -exec chmod 755 {} \; 2>/dev/null
find /system/product/app -type d -exec chmod 755 {} \; 2>/dev/null
find /system/system_ext/priv-app -type d -exec chmod 755 {} \; 2>/dev/null

# 设置APK权限 / Set APK permissions
find /system/product/priv-app -name "*.apk" -exec chmod 644 {} \; 2>/dev/null
find /system/product/app -name "*.apk" -exec chmod 644 {} \; 2>/dev/null
find /system/system_ext/priv-app -name "*.apk" -exec chmod 644 {} \; 2>/dev/null
find /system/product/overlay -name "*.apk" -exec chmod 644 {} \; 2>/dev/null

# 设置配置文件权限 / Set config file permissions
find /system/product/etc -type f -exec chmod 644 {} \; 2>/dev/null
find /system/product/framework -type f -exec chmod 644 {} \; 2>/dev/null
find /system/product/lib -type f -exec chmod 644 {} \; 2>/dev/null
find /system/product/lib64 -type f -exec chmod 644 {} \; 2>/dev/null
find /system/system_ext/etc -type f -exec chmod 644 {} \; 2>/dev/null

echo "权限设置完成 / Permissions set"
' >> "$LOG" 2>&1

### 6. 软重启安卓系统让GMS生效（不重启容器，速度更快）/ Soft-restart Android to activate GMS (faster than container restart)
log "正在重启安卓系统 / Restarting Android system..."
# 先尝试软重启（stop/start），比docker restart快很多
docker exec -u 0 "$C" sh -c 'stop; sleep 2; start' 2>/dev/null || true
# 软重启后等待系统boot完成
for i in $(seq 1 60); do
    BOOT=$(docker exec "$C" getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    if [ "$BOOT" = "1" ]; then
        log "安卓系统已重启完成 / Android system restarted successfully"
        break
    fi
    sleep 2
done
# 如果软重启失败，兜底用docker restart
if [ "$BOOT" != "1" ]; then
    log "软重启未完成，使用容器重启兜底 / Soft restart incomplete, falling back to container restart"
    docker restart "$C" 2>/dev/null || true
    sleep 10
fi

### 7. 删除标记文件，避免重复安装 / Remove marker to prevent re-install
### 3.9.7：**不删标记**。以前装完就删，容器一旦重建（升级/重装/换镜像）/system 回退
### 到原始状态，GMS 消失且标记已无 → 永远不会再装，用户看到「装了 GMS 但没有 Play 商店」。
### 现在保留标记，由 boot_guard 每轮巡检「标记=yes 且 容器内无 GMS」时自动补装；
### 脚本开头的「已装则跳过」保证不会重复装。
rm -f "$VAR_DIR/install_gms_fails" 2>/dev/null || true

### 3.9.7：GMS 装完立即禁用 Google 设置向导 —— 容器无 WiFi 硬件，它的 WifiService
### 请求会被拒绝并抛 FATAL EXCEPTION（实测反复崩溃），桌面使用不受影响但日志很脏。
docker exec "${C:-androidemu-android}" sh -c 'pm disable-user --user 0 com.google.android.setupwizard' >/dev/null 2>&1 || true

### 8. 清理临时文件 / Cleanup temp files
rm -rf "$GMS_TMP"
docker rm -f "$GMS_TMP_CONTAINER" >/dev/null 2>&1 || true

### 9. 安装成功后自动删除GMS镜像，释放约700MB空间 / Auto-remove GMS image after success to free ~700MB
if [ "$GMS_FROM_IMAGE" -eq 1 ]; then
    log "正在清理GMS镜像以释放空间 / Removing GMS image to free space..."
    # 彻底删除所有androidemu-gms相关镜像（不管标签和来源）
    docker images --format '{{.Repository}}:{{.Tag}}' | grep "androidemu-gms" | while read img; do
        docker rmi -f "$img" >/dev/null 2>&1 || true
    done
    log "GMS镜像已清理 / GMS image removed"
fi

log "GMS安装完成！安卓系统重启后谷歌服务将自动启动。 / GMS installation complete! Google services will start automatically after Android system restart."
log "首次启动谷歌服务初始化约需3-5分钟，期间穿云投屏可能反复连接/离线，属正常现象。 / First-time initialization takes about 3-5 minutes, during which ScrcpyOverWebRTC may reconnect repeatedly, this is normal."

exit 0

# 本应用基于开源项目 Redroid (https://github.com/remote-android/redroid-doc) 与穿云投屏 ScrcpyOverWebRTC 集成，致谢上游开发者 / This app is built upon open-source projects Redroid and ScrcpyOverWebRTC; credits to upstream developers.
