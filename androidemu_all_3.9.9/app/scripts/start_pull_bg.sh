#!/bin/bash
### start_pull_bg.sh — 后台拉取镜像并在就绪后自动启动容器（不阻塞调用方）。
###
### 快速安装版三入口统一复用：
###   1) install_callback  安装完成后调用 → 安装秒完成，后台自动拉镜像并自动启动容器，
###      无需用户手动启用；
###   2) cmd/main start    用户点「启用」时调用 → 立即返回，不阻塞、不卡界面；
###   3) 面板 index.cgi    打开面板/点「一键拉取」时调用 → 展示实时进度条。
###
### 拉取去重：若已有后台拉取进程在跑，直接返回，避免重复拉取。

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
mkdir -p "$VAR_DIR"
PULL_LOG="${VAR_DIR}/pull.log"
PULL_PID="${VAR_DIR}/pull.pid"
PROGRESS_LOG="${VAR_DIR}/pull-progress.log"

### 已在拉取则直接返回（防止安装/启用/面板重复触发）
if [ -f "$PULL_PID" ] && kill -0 "$(cat "$PULL_PID" 2>/dev/null)" 2>/dev/null; then
    exit 0
fi

rm -f "$PROGRESS_LOG"
rm -f "${VAR_DIR}/eta.state"

nohup bash -c '
    . "'"$APP_DIR"'"/scripts/pull_image.sh
    export PROGRESS_LOG="'"$PROGRESS_LOG"'"
    GMS_MARKER="'"$VAR_DIR"'/install_gms"
    if [ -f "$GMS_MARKER" ] && grep -qi "yes" "$GMS_MARKER" 2>/dev/null; then
        logline "检测到GMS安装请求，后台并行预下载GMS镜像..."
        ( ensure_gms_image ) &
        GMS_PULL_PID=$!
    fi
    ### 3.9.6：起容器前先清孤儿（<hash>_androidemu-*），否则会抢端口/抢 agent 连接
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^[0-9a-f]{12}_androidemu-' | while read -r _orph; do
        docker rm -f "$_orph" >/dev/null 2>&1 && logline "清理孤儿容器：$_orph"
    done
    if ensure_redroid_image && ensure_webrtc_image; then
        # 等待GMS镜像预下载完成（最多等60秒，容器启动后install_gms.sh会继续等）
        if [ -n "$GMS_PULL_PID" ]; then
            logline "安卓镜像就绪，等待GMS镜像预下载完成..."
            wait "$GMS_PULL_PID" 2>/dev/null || true
        fi
        echo "[$(date +%F\ %T)] 镜像就绪，正在启动容器…"
        ### 缓存标签：给两个镜像打备份 tag（androidemu-cache/*）。
        ### 飞牛升级时按 compose 官方名清理镜像，备份 tag 能存活；
        ### upgrade_init 用它秒级恢复官方 tag，升级不再重下 2GB。
        docker tag "$CANON_REDROID" "${CACHE_REDROID:-androidemu-cache/redroid:12.0.0}" 2>/dev/null || true
        docker tag "$OFF_REDROID" "${CACHE_REDROID:-androidemu-cache/redroid:12.0.0}" 2>/dev/null || true
        docker tag "$CANON_WEBRTC" "${CACHE_WEBRTC:-androidemu-cache/webrtc:latest}" 2>/dev/null || true
        docker tag "$OFF_WEBRTC" "${CACHE_WEBRTC:-androidemu-cache/webrtc:latest}" 2>/dev/null || true
        # GPU 直通（3.9.8 修正）：容器内的 /dev/dri 是「创建那一刻」按宿主权限生成的副本，
        # 宿主节点本身不需要也不应该被改动。放权动作改到「容器起来之后」立刻做
        # （见下文 START_OK 分支），此时 surfaceflinger 还没打开设备。
        cd "'"$APP_DIR"'"/docker
        ### 启动容器，最多重试 3 次，每次失败都记录日志不静默吞掉
        START_OK=0
        for TRY in 1 2 3; do
            echo "[$(date +%F\ %T)] 第 ${TRY} 次尝试启动容器…"
            ### 3.9.4 修复：强制重建 —— 安装阶段可能已用旧版镜像建过容器（卸载"保留镜像"
            ### 留下旧 tag），镜像就绪后若只做普通 up，容器不会按新镜像重建，用户会一直
            ### 停留在旧版。--force-recreate 保证容器一定使用刚就绪的镜像内容
            ###（安卓数据在外部卷，重建不影响数据）。
            ### 3.9.7：必须给足停止超时。redroid 容器正常停机要 40-50 秒，而
            ### compose 的 --force-recreate 默认只等 10 秒就 SIGKILL —— 实测
            ### 「停用→启用」后容器停在 Exited(137)、boot_completed 始终读不到，
            ### 表现为启用无效（两遍复现）。--timeout 60 让旧容器体面退出后再重建。
            if docker compose -p androidemu up -d --force-recreate --timeout 60 2>&1; then
                START_OK=1
                echo "[$(date +%F\ %T)] 容器启动命令执行成功"
                break
            else
                echo "[$(date +%F\ %T)] 第 ${TRY} 次启动失败，5秒后重试…"
                sleep 5
            fi
        done
        if [ -f "'"$APP_DIR"'"/scripts/webrtc_watchdog.sh ]; then
            bash "'"$APP_DIR"'"/scripts/webrtc_watchdog.sh ensure >/dev/null 2>&1 || true
        fi
        ### 3.9.8：--force-recreate 遇到 container_name 冲突时会先建一个 <hash>_androidemu-*
        ### 临时容器，重建收尾不干净就留在 Created。旧代码只在 up 之前清，up 过程中新产生的
        ### 没人管 —— 实测全新安装后出现 2 个孤儿（用户/群友看到「多个同名前缀容器」）。
        ### 这里 up 之后立刻再清一遍（本段在外层单引号里，只能用双引号，禁止再写单引号）。
        docker ps -a --format "{{.Names}}" 2>/dev/null | grep -E "^[0-9a-f]{12}_androidemu-" | while read -r _orph2; do
            docker rm -f "$_orph2" >/dev/null 2>&1 && logline "清理 compose 临时容器：$_orph2"
        done
        if [ "$START_OK" = "1" ]; then
            # 等待容器进入运行态（最多 60 秒）
            for _i in $(seq 1 60); do
                STATE=$(docker inspect -f "{{.State.Running}}" androidemu-android 2>/dev/null)
                [ "$STATE" = "true" ] && break
                sleep 1
            done
            # 3.9.8：容器刚 running 就放权（只改容器内的节点副本，宿主 /dev/dri 不动）
            if [ -f "'"$APP_DIR"'"/scripts/gpu_release.sh ]; then
                bash "'"$APP_DIR"'"/scripts/gpu_release.sh --wait 20 >/dev/null 2>&1 || true
            fi
            # 容器内兜底（2.0.15）：容器内放权；若已陷入崩溃循环则放权 + 重启整个容器
            # （仅重启 surfaceflinger 实测无法从 EGLConfig 崩溃循环中恢复）
            nohup bash "'"$APP_DIR"'"/scripts/fix_gpu_perms.sh >/dev/null 2>&1 &
            # keystore 数据库修复（3.2.5）：检测到 keystore2 崩溃时自动删除损坏数据库并重建，
            # 避免"Phone is starting..."卡死、容器反复重启。
            nohup bash "'"$APP_DIR"'"/scripts/fix_keystore.sh >/dev/null 2>&1 &
            # 音频编码器修复（2.0.3）：镜像带 libcodec2_soft_opusenc.so 但未在 media_codecs.xml
            # 声明，导致开启音频时 audio/opus 创建失败、会话断连；此处幂等注册 Opus 编码器。
            nohup bash "'"$APP_DIR"'"/scripts/fix_audio_codec.sh >/dev/null 2>&1 &
            # 存储目录权限修复（3.2.9）：/sdcard 下 Download/DCIM 等目录权限为 700，
            # 穿云投屏文件中心访问时报 permission denied；容器 boot 后自动改成 777。
            nohup bash "'"$APP_DIR"'"/scripts/fix_storage_perm.sh >/dev/null 2>&1 &
            nohup bash "'"$APP_DIR"'"/scripts/redroid_adb_forward.sh install >/dev/null 2>&1 &
            nohup bash "'"$APP_DIR"'"/scripts/audio_watchdog.sh start >/dev/null 2>&1 &
            nohup bash "'"$APP_DIR"'"/scripts/boot_guard.sh start >/dev/null 2>&1 &
            nohup bash "'"$APP_DIR"'"/scripts/webrtc_watchdog.sh start >/dev/null 2>&1 &            nohup bash "'"$APP_DIR"'"/scripts/gw_socket.sh start >/dev/null 2>&1 &
if [ -f "'"$APP_DIR"'"/scripts/install_gms.sh ]; then
    nohup bash "'"$APP_DIR"'"/scripts/install_gms.sh >/dev/null 2>&1 &
fi
if [ -f "${TRIM_APPDEST}/scripts/agent_autodeploy.sh" ]; then
    nohup bash "${TRIM_APPDEST}/scripts/agent_autodeploy.sh" >/dev/null 2>&1 &
fi
            echo "[$(date +%F\ %T)] 容器已启动，安卓模拟器可用。GPU 自动修复已在后台执行。"
        else
            echo "[$(date +%F\ %T)] 容器启动失败（已重试3次），请检查 docker logs androidemu-android 查看具体错误"
            docker logs androidemu-android --tail 30 2>&1 || true
        fi
    else
        echo "[$(date +%F\ %T)] 免注册加速源与官方仓库均失败，请检查飞牛网络后重试。"
    fi
' > "$PULL_LOG" 2>&1 &
echo $! > "$PULL_PID"

exit 0
