#!/bin/bash
### repair.sh — 一键修复「无法启用 / compose 建不出容器 / docker不可用」
###
### 做什么（只动本应用自己的东西，不动其它应用、不删数据）：
###   1) 检查 Docker 与 compose 插件是否可用（不可用时给出明确结论，不再让你猜）
###   2) 把依赖应用 binder_linux 拉起（它被停用时应用中心会直接拒绝启用本应用）
###   3) 补齐 /dev/binder、/dev/net/tun 设备节点
###   4) 幂等创建两个数据卷（外部卷缺失时 compose 会直接失败）
###   5) 清掉本应用「已停止」的旧容器与空网络（避免 container name in use / network exists）
###   6) 重新按本机硬件校准 compose（GPU/内存/端口/seccomp 路径）
###   7) 两个镜像缺哪个就拉哪个（带进度，可能几分钟）
###   8) 真正执行一次 docker compose up -d —— **完整保留报错输出**，写进 var/repair.log
###
### 用法： sudo bash repair.sh
### 说明：不改端口、不删数据卷、不删镜像、不动其它应用。
set +e

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
[ -d "$APP_DIR" ] || APP_DIR="$(readlink -f "$(dirname "$0")/.." 2>/dev/null)"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
LOG="$VAR_DIR/repair.log"
mkdir -p "$VAR_DIR" 2>/dev/null

if [ "$(id -u)" != "0" ]; then
    echo "需要管理员权限：请执行  sudo bash $0"
    exit 1
fi

exec > >(tee -a "$LOG") 2>&1
echo "================ androidemu 一键修复 $(date '+%F %T') ================"
echo "应用目录：$APP_DIR"
echo "数据目录：$VAR_DIR"
echo

FAIL=0
step(){ echo; echo "—— $1 ——"; }

step "1/8 检查 Docker"
if ! command -v docker >/dev/null 2>&1; then
    echo "[失败] 未找到 docker 命令：请先在飞牛「应用中心 → Docker」安装并启动 Docker。"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "[失败] Docker 守护进程不可用：这是应用中心提示「docker不可用」的直接原因。"
    echo "       请到飞牛「系统设置 / 应用中心」确认 Docker 服务已启动后重试。"
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    echo "[失败] 缺少 docker compose 插件（docker-compose-plugin）：所有 docker 应用都会报「docker不可用」。"
    echo "       请在飞牛应用中心重装 Docker，或在终端执行： apt-get install -y docker-compose-plugin"
    exit 1
fi
echo "[正常] Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)，compose $(docker compose version --short 2>/dev/null)"

step "2/8 启用依赖应用 binder_linux"
if command -v appcenter-cli >/dev/null 2>&1; then
    _st="$(appcenter-cli status binder_linux_driver 2>/dev/null | tr -d '\r\n')"
    echo "      当前状态：${_st:-未知}"
    if [ "$_st" != "running" ]; then
        appcenter-cli start binder_linux_driver >/dev/null 2>&1
        sleep 2
        echo "      已尝试启用，现状态：$(appcenter-cli status binder_linux_driver 2>/dev/null | tr -d '\r\n')"
    fi
else
    echo "      [注意] 未找到 appcenter-cli，跳过（请手动确认 binder_linux 处于启用状态）"
fi

step "3/8 补齐设备节点"
if [ -x "$APP_DIR/scripts/ensure_devices.sh" ]; then
    bash "$APP_DIR/scripts/ensure_devices.sh"
else
    echo "      [注意] 缺少 scripts/ensure_devices.sh"
fi

step "4/8 创建数据卷"
docker volume create androidemu-data >/dev/null 2>&1
docker volume create androidemu-webrtc-data >/dev/null 2>&1
docker volume inspect androidemu-data >/dev/null 2>&1 && echo "[正常] androidemu-data" || { echo "[失败] androidemu-data 创建失败"; FAIL=1; }
docker volume inspect androidemu-webrtc-data >/dev/null 2>&1 && echo "[正常] androidemu-webrtc-data" || { echo "[失败] androidemu-webrtc-data 创建失败"; FAIL=1; }

step "5/8 清理本应用已停止的旧容器与空网络"
for C in androidemu-android androidemu-webrtc; do
    if docker inspect "$C" >/dev/null 2>&1; then
        if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ]; then
            docker rm -f "$C" >/dev/null 2>&1 && echo "      已删除已停止的容器 $C"
        else
            echo "      容器 $C 正在运行，保留"
        fi
    fi
done
for N in androidemu_default; do
    if docker network inspect "$N" >/dev/null 2>&1 && [ "$(docker network inspect -f '{{len .Containers}}' "$N" 2>/dev/null || echo 1)" = "0" ]; then
        docker network rm "$N" >/dev/null 2>&1 && echo "      已删除空网络 $N"
    fi
done

step "6/8 按本机硬件重新校准 compose"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"
if [ -f "$COMPOSE" ]; then
    [ -f "$APP_DIR/scripts/tune_compose.sh" ] && bash "$APP_DIR/scripts/tune_compose.sh" "$COMPOSE"
    [ -f "$APP_DIR/scripts/tune_resources.sh" ] && bash "$APP_DIR/scripts/tune_resources.sh" "$COMPOSE"
else
    echo "[失败] 找不到 compose：$COMPOSE（应用文件可能不完整，请卸载后重新安装）"
    exit 1
fi

step "7/8 检查镜像"
if [ -f "$APP_DIR/scripts/rtconf.sh" ]; then
    # shellcheck disable=SC1091
    . "$APP_DIR/scripts/rtconf.sh"; rtconf_load
fi
: "${CANON_REDROID:=docker.fnnas.com/redroid/redroid:12.0.0-latest}"
: "${CANON_WEBRTC:=docker.fnnas.com/buutuu/scrcpy-over-webrtc:latest}"
_NEED_PULL=0
for IMG in "$CANON_REDROID" "$CANON_WEBRTC"; do
    if docker image inspect "$IMG" >/dev/null 2>&1; then
        echo "[正常] 已就绪 $IMG"
    else
        echo "[缺失] $IMG"; _NEED_PULL=1
    fi
done
if [ "$_NEED_PULL" = "1" ]; then
    if [ -x "$APP_DIR/scripts/pull_image.sh" ]; then
        echo "      开始拉取（首次约 2GB，视网速需要几分钟到几十分钟）…"
        TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" PROGRESS_LOG="$VAR_DIR/pull-progress.log" \
            bash "$APP_DIR/scripts/pull_image.sh"
    else
        echo "      [注意] 缺少 pull_image.sh，跳过拉取"
    fi
fi

step "8/8 启动容器（保留完整报错）"
_COMP_ERR="$VAR_DIR/compose.err"
( cd "$(dirname "$COMPOSE")" && docker compose -p androidemu up -d ) 2>&1 | tee "$_COMP_ERR"
_rc=${PIPESTATUS[0]}
echo "compose 退出码：$_rc"
if [ "$_rc" != "0" ]; then
    echo
    echo "[失败] compose 启动失败 —— 上面这段（以及 $_COMP_ERR）就是应用中心那个「compose或者container异常」的真实原因。"
    echo "       请把 $LOG 与 $_COMP_ERR 一起反馈： https://www.lin1740.de5.net/"
    FAIL=1
else
    sleep 6
    docker ps -a --filter name=androidemu --format '      {{.Names}}  {{.Status}}'
    echo "[完成] 容器已启动；安卓首次开机需要 1~3 分钟，可在应用面板查看进度。"
fi

echo
echo "—— 自检报告 ——"
[ -x "$APP_DIR/scripts/selfcheck.sh" ] && bash "$APP_DIR/scripts/selfcheck.sh"
echo
echo "日志：$LOG　自检：$VAR_DIR/selfcheck.txt"
[ "$FAIL" = "0" ] && echo "结论：修复流程执行完毕，未发现失败项。" || echo "结论：仍有失败项，请按上面的提示处理或把日志发给发布者。"
exit 0
