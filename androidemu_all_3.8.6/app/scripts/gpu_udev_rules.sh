#!/bin/bash
### gpu_udev_rules.sh — 安装/移除宿主 DRM 设备放权 udev 规则。
###
### 背景：GPU 直通机器上，Android 内降权后的渲染进程（surfaceflinger/graphics）
###       需要以普通权限打开 /dev/dri/card*、renderD*。宿主 udev 在每次开机时会把
###       节点权限重置为 660 root:video|render，导致容器随系统自启（未经安装/升级
###       回调放权）时 surfaceflinger 反复 EGLConfig 失败、boot 无法完成。
###       本规则让 udev 在节点创建时就置为 0666，覆盖「NAS 重启 + 容器自启」路径。
###
### 用法：gpu_udev_rules.sh install | remove
### 幂等：重复执行结果一致；无 /dev/dri（无 GPU/软件渲染）时 install 直接跳过。
### 影响面：仅新增/删除本应用自己的规则文件，只作用于 card*/renderD* 两个 DRM 节点类。
###
### 【2.0.15 重要说明】
###   本应用以包用户运行（config/privilege: run-as=package → 用户 docker-androidemu），
###   通常没有 /etc/udev/rules.d 的写权限：本脚本在那种情况下会明确「记录并跳过」，
###   不再静默失败。也就是说 —— 除非管理员以 root 手动执行本脚本，否则这条 udev 规则
###   并不会被安装（2.0.14 及更早版本的《权限说明》里「安装时写入该规则」的说法与
###   实际不符，已在 2.0.15 更正）。放权主路径是 scripts/gpu_release.sh：在启动容器
###   之前借容器内 root 通过 bind mount 给 /dev/dri 节点 chmod 666，不需要宿主 root。
###   管理员若希望开机时由 udev 直接置 0666，可自行执行：
###       sudo bash <应用目录>/scripts/gpu_udev_rules.sh install

set -u
RULE="/etc/udev/rules.d/99-androidemu-drm.rules"
ACTION="${1:-install}"

case "$ACTION" in
    install)
        ### 无 DRM 设备（无 GPU 直通 / 纯软件渲染机器）无需规则
        [ -e /dev/dri ] || exit 0
        ### 应用是包用户，通常写不了 /etc/udev/rules.d：明确记录并跳过，不再静默失败。
        if [ ! -w /etc/udev/rules.d ]; then
            LOG_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
            mkdir -p "$LOG_DIR" 2>/dev/null || true
            echo "[$(date '+%F %T')] gpu_udev_rules: 当前用户无 /etc/udev/rules.d 写权限，跳过安装（放权由 scripts/gpu_release.sh 在启动容器前完成；管理员可用 sudo 执行本脚本安装规则）" >> "$LOG_DIR/gpu_fix.log" 2>/dev/null || true
            exit 0
        fi
        mkdir -p /etc/udev/rules.d 2>/dev/null || exit 0
        cat > "$RULE" <<'EOF'
# androidemu: 放开 DRM 设备权限（GPU 直通机器 Android 降权渲染进程需要打开设备完成 boot）
# 注意：应用自身以包用户运行、无法写入本目录；本文件通常由管理员以 root 执行
#       scripts/gpu_udev_rules.sh install 时创建（应用内主路径为 scripts/gpu_release.sh）。
# 仅作用于 card*/renderD* 节点。
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", MODE="0666"
EOF
        chmod 644 "$RULE" 2>/dev/null || true
        if command -v udevadm >/dev/null 2>&1; then
            udevadm control --reload-rules 2>/dev/null || true
            udevadm trigger --subsystem-match=drm 2>/dev/null || true
        fi
        echo "gpu_udev_rules: installed $RULE"
        ;;
    remove)
        ### 非 root 时删除同样会失败：记录并跳过
        if [ ! -w /etc/udev/rules.d ]; then
            LOG_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
            mkdir -p "$LOG_DIR" 2>/dev/null || true
            echo "[$(date '+%F %T')] gpu_udev_rules: 当前用户无 /etc/udev/rules.d 写权限，跳过删除（若曾以 root 安装过该规则，请 sudo 手动删除 $RULE）" >> "$LOG_DIR/gpu_fix.log" 2>/dev/null || true
            exit 0
        fi
        rm -f "$RULE" 2>/dev/null || true
        if command -v udevadm >/dev/null 2>&1; then
            udevadm control --reload-rules 2>/dev/null || true
        fi
        echo "gpu_udev_rules: removed $RULE"
        ;;
    *)
        echo "gpu_udev_rules: unknown action '$ACTION' (use install|remove)" >&2
        exit 0
        ;;
esac

exit 0
