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
    if ensure_redroid_image && ensure_webrtc_image; then
        echo "[$(date +%F\ %T)] 镜像就绪，正在启动容器…"
        ### 缓存标签：给两个镜像打备份 tag（androidemu-cache/*）。
        ### 飞牛升级时按 compose 官方名清理镜像，备份 tag 能存活；
        ### upgrade_init 用它秒级恢复官方 tag，升级不再重下 2GB。
        ### 3.8.7：使用 pull_image.sh 中设置的动态变量，支持标准版和 GMS 版。
        docker tag "$CANON_REDROID" androidemu-cache/redroid:12.0.0 2>/dev/null || true
        docker tag "$OFF_REDROID" androidemu-cache/redroid:12.0.0 2>/dev/null || true
        docker tag "$CANON_WEBRTC" androidemu-cache/webrtc:latest 2>/dev/null || true
        docker tag "$OFF_WEBRTC" androidemu-cache/webrtc:latest 2>/dev/null || true
        # GPU 直通（2.0.15 修正）：必须在「启动容器之前」放权，容器内 surfaceflinger
        # 第一次启动才能打开 /dev/dri。旧版此处直接 chmod，但应用以包用户运行
        # （config/privilege run-as=package），对 root:video/render 的节点没有 chmod
        # 权限，EPERM 被 || true 吞掉 → 实际从未生效 → surfaceflinger 反复
        # "no suitable EGLConfig found" 崩溃、Android 不 boot、adbd 停在 USB 模式，
        # 表现为「adb 连不上 / device offline」。现改由 gpu_release.sh 处理：
        # 借 redroid 镜像自身的 shell，以容器内 root 通过 bind mount 放权，
        # 不需要宿主 root，也不改变权限声明。
        if [ -f "'"$APP_DIR"'"/scripts/gpu_release.sh ]; then
            bash "'"$APP_DIR"'"/scripts/gpu_release.sh --compose "'"$APP_DIR"'"/docker/docker-compose.yaml >/dev/null 2>&1 || true
        fi
        cd "'"$APP_DIR"'"/docker
        ### 启动容器，最多重试 3 次，每次失败都记录日志不静默吞掉
        START_OK=0
        for TRY in 1 2 3; do
            echo "[$(date +%F\ %T)] 第 ${TRY} 次尝试启动容器…"
            if docker compose -p androidemu up -d 2>&1; then
                START_OK=1
                echo "[$(date +%F\ %T)] 容器启动命令执行成功"
                break
            else
                echo "[$(date +%F\ %T)] 第 ${TRY} 次启动失败，5秒后重试…"
                sleep 5
            fi
        done
        ### 2.0.45：确保 webrtc 容器一定存在（曾因 --remove-orphans 在 compose 被中途
        ### 改写时把它当孤儿删除，导致画面服务消失、黑屏/公网穿透全打不开）
        ### 2.0.47：守护自身的输出（含 stderr）只进它自己的日志，绝不写进 pull.log
        ### （面板会展示 pull.log 尾部，之前会把手守护的报错当成面板内容显示出来）
        if [ -f "'"$APP_DIR"'"/scripts/webrtc_watchdog.sh ]; then
            bash "'"$APP_DIR"'"/scripts/webrtc_watchdog.sh ensure >/dev/null 2>&1 || true
        fi
        if [ "$START_OK" = "1" ]; then
            # 等待容器进入运行态（最多 60 秒）
            for _i in $(seq 1 60); do
                STATE=$(docker inspect -f "{{.State.Running}}" androidemu-android 2>/dev/null)
                [ "$STATE" = "true" ] && break
                sleep 1
            done
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
            nohup bash "'"$APP_DIR"'"/scripts/webrtc_watchdog.sh start >/dev/null 2>&1 &            nohup bash "'"$APP_DIR"'"/scripts/gw_socket.sh start >/dev/null 2>&1 &
### 2.0.22：自动把云手机 Agent 部署进安卓容器并连上本机信令（无需任何手工命令）。
### 幂等：agent 已在运行则直接返回；安卓未 boot 时脚本内部会等待或交给守护重试。
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
