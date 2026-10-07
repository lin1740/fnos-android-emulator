#!/bin/bash
### gpu_release.sh — 在「启动安卓容器之前」给宿主 DRM 节点放权（GPU 直通机器必需）。
###
### 【实测事实】（2026-09-19，AMD Kaveri + fnOS 1.2.0701）
###   1) 宿主 udev 开机把 /dev/dri/card*、renderD* 置为 660 root:video|render；
###   2) compose 里用 `devices:` 直通时，docker 是在「创建容器的那一刻」按宿主节点的
###      权限生成容器内节点：实测宿主 660 → 容器内也是 660；宿主 666 → 容器内 666。
###      也就是说容器内的节点权限是宿主的副本，容器内 chmod 改不到宿主节点；
###      容器一旦以 660 起来，surfaceflinger 打不开设备 → 反复报
###      "no suitable EGLConfig found" 崩溃 → Android 永远到不了 boot_completed=1
###      → adbd 停在 USB 模式（service.adb.tcp.port=0、容器内不监听 5555）
###      → adb 连接表现为 offline / 失败、云手机画面黑屏。
###      并且此时「只重启 surfaceflinger」或「容器内 chmod + 重启」都救不回来
###      （实测 120 秒仍是 restarting），必须让宿主节点先变 666、再重建容器。
###   3) 本应用以包用户运行（config/privilege: run-as=package），没有权限直接
###      chmod 宿主 /dev/dri 下的 root:video 节点（EPERM）。
###
### 【因此的做法】
###   用本应用自己的另一个上游镜像（穿云投屏 webrtc 镜像，busybox 提供 /bin/sh）
###   起一个 --rm 临时容器，绑定挂载 -v /dev/dri:/dev/dri（与宿主共享同一 inode），
###   在容器内以 root 执行 chmod 666 —— 实测宿主节点随即变为 666。
###   之后才创建安卓容器，容器内节点也就是 666，surfaceflinger 首次启动即可成功。
###   · 不需要宿主 root、不需要 --privileged、不常驻、用完即删；
###   · 权限面与之前完全一致（仍是容器内 root 改设备节点），未扩大任何声明；
###   · 无 /dev/dri（软件渲染）或节点本来就是 666 时直接跳过。
###
### 用法：gpu_release.sh [--image <带 /bin/sh 的镜像>]
### 退出码：恒为 0（放权失败不阻断启动；容器起来后 fix_gpu_perms.sh 仍会兜底）。
### 结果写入 ${TRIM_PKGVAR}/gpu_fix.log（含放权前后的真实权限，便于排查）。

set -u

IMAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="${2:-}"; shift 2 ;;
        *)       shift ;;
    esac
done

VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
LOG="${VAR_DIR}/gpu_fix.log"
mkdir -p "$VAR_DIR" 2>/dev/null || true
log() { echo "[$(date '+%F %T')] gpu_release: $*" >> "$LOG" 2>/dev/null || true; }

### 无 DRM 设备（无 GPU 直通 / 软件渲染机器）→ 无需放权
[ -e /dev/dri ] || exit 0

list_nodes() { ls /dev/dri/card* /dev/dri/renderD* 2>/dev/null; }
node_modes() {
    for d in /dev/dri/card* /dev/dri/renderD*; do
        [ -e "$d" ] && printf ' %s:%s' "$(basename "$d")" "$(stat -c %a "$d" 2>/dev/null)"
    done
}
all_666() {
    for d in /dev/dri/card* /dev/dri/renderD*; do
        [ -e "$d" ] || continue
        [ "$(stat -c %a "$d" 2>/dev/null)" = "666" ] || return 1
    done
    return 0
}
BEFORE="$(node_modes)"

### 已经是 666（例如上次已放权、或管理员装了 udev 规则）→ 无需处理
if all_666; then
    log "节点已是 666，跳过（${BEFORE}）"
    exit 0
fi

### 候选镜像：命令行指定 > 穿云投屏（随包必备，busybox /bin/sh）> 常见带 sh 的镜像
CANDS="${IMAGE} buutuu/scrcpy-over-webrtc:latest alpine:latest busybox:latest debian:stable-slim"
USED=""
for img in $CANDS; do
    [ -n "$img" ] || continue
    docker image inspect "$img" >/dev/null 2>&1 || continue
    if docker run --rm --network none \
            -v /dev/dri:/dev/dri \
            --entrypoint /bin/sh \
            "$img" \
            -c 'for d in /dev/dri/card* /dev/dri/renderD*; do [ -e "$d" ] && chmod 666 "$d" 2>/dev/null; done' \
            >/dev/null 2>&1; then
        USED="$img"
        break
    fi
done

AFTER="$(node_modes)"
if all_666; then
    log "启动前放权成功（helper 镜像 ${USED:-未使用}）：${BEFORE} →${AFTER}"
else
    log "启动前放权未完全成功（helper 镜像 ${USED:-无可用镜像}）：${BEFORE} →${AFTER}；容器启动后由 fix_gpu_perms.sh 继续尝试"
fi

exit 0
