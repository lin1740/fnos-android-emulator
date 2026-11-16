#!/bin/bash
### androidemu 后端看护的 systemd 托管（3.9.9-r28）
###
### 背景（2026-11-16 官方口径）：前台进程不要 root，后端可以酌情允许 root。
### 于是把「开机自启 + 容器自愈」交给 systemd 托管的 root 看护进程，
### 而用户可见的前端网关仍由看护降权到包用户启动。
###
### 为什么必须这么做：
###   飞牛只会调用 cmd/main 的 status 轮询，**从不主动调 start**（2026-11-15
###   20:25-20:32 的 main.log 13 条 status、0 条 start 已证实）。NAS 重启后
###   容器被 docker 的 restart 策略拉起，但宿主侧的网关与看护没人管 →
###   飞牛反代连不上 app.sock → Bad Gateway，且永远不恢复。
###   systemd 的 WantedBy=multi-user.target 正好补上这一环。
###
### 用法：
###   guard_service.sh install   安装/更新服务并启动（root）
###   guard_service.sh remove    停止并删除服务（卸载时）
###   guard_service.sh status    查看状态
set -u

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
PKG_USER="${TRIM_RUN_USERNAME:-docker-androidemu}"
SVC_NAME="androidemu-guard"
SVC_FILE="/etc/systemd/system/${SVC_NAME}.service"
LOG="$VAR_DIR/guard_service.log"

log(){ echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null || true; }

[ "$(id -u)" = "0" ] || { echo "需要 root 身份"; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "本机没有 systemd"; exit 1; }

write_unit(){
    cat > "$SVC_FILE" <<EOF
[Unit]
Description=Android emulator backend guard (fnOS app androidemu)
Documentation=https://github.com/hqw700/ScrcpyOverWebRTC
After=docker.service network-online.target local-fs.target
Wants=docker.service network-online.target
### 数据目录在存储空间上：等它挂载好再起，避免开机时 VAR_DIR 还不存在
RequiresMountsFor=${VAR_DIR}
### 看护内部自带限频与日志轮转，不让 systemd 因短时间多次退出而放弃拉起
StartLimitIntervalSec=0

[Service]
Type=simple
### 3.9.9-r28 修正（官方口径：前台禁止 root，后端也尽量不用 root）：
### 包用户 docker-androidemu 已经在 docker 组（994），docker.sock 是 root:docker 660，
### 它本来就能直接操作容器 —— 所以本服务**整条链路不以 root 运行**。
### systemd 负责「开机拉起 + 挂了重拉」，进程身份仍是包用户，宿主上不会出现 root 常驻。
User=${PKG_USER}
### 显式带上 docker / video / render，避免不同机型上用户主组缺失导致 docker 权限丢失
SupplementaryGroups=docker video render
WorkingDirectory=${APP_DIR}
Environment=TRIM_APPDEST=${APP_DIR}
Environment=TRIM_PKGVAR=${VAR_DIR}
Environment=TRIM_RUN_USERNAME=${PKG_USER}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash ${APP_DIR}/scripts/boot_guard.sh supervise
ExecStop=/bin/bash ${APP_DIR}/scripts/boot_guard.sh stop
Restart=always
RestartSec=20
TimeoutStartSec=90
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SVC_FILE"
}

do_install(){
    mkdir -p "$VAR_DIR" 2>/dev/null || true
    ### 包用户必须存在且具备 docker 权限，否则服务起来也管不了容器
    if ! id "$PKG_USER" >/dev/null 2>&1; then
        log "install 失败：包用户 $PKG_USER 不存在"
        echo "androidemu-guard: 包用户不存在"; return 1
    fi
    if ! id -nG "$PKG_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        log "install 警告：$PKG_USER 不在 docker 组，看护将无法操作容器"
    fi
    write_unit
    ### 先停历史实例（可能是包用户起的，root 能杀），否则新实例会卡在 flock
    /bin/bash "$APP_DIR/scripts/boot_guard.sh" stop >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$SVC_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SVC_NAME" >/dev/null 2>&1 || true
    sleep 2
    _st=$(systemctl is-active "$SVC_NAME" 2>/dev/null)
    log "install: 服务已写入并启动，active=${_st:-unknown}"
    echo "androidemu-guard: ${_st:-unknown}"
}

do_remove(){
    systemctl stop "$SVC_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SVC_NAME" >/dev/null 2>&1 || true
    rm -f "$SVC_FILE" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    log "remove: 服务已停止并删除"
    echo "androidemu-guard: removed"
}

do_status(){
    echo "unit: $SVC_FILE $([ -f "$SVC_FILE" ] && echo '(存在)' || echo '(不存在)')"
    systemctl is-enabled "$SVC_NAME" 2>/dev/null || true
    systemctl is-active "$SVC_NAME" 2>/dev/null || true
    systemctl status "$SVC_NAME" --no-pager -n 8 2>/dev/null | tail -12
}

case "${1:-status}" in
    install) do_install ;;
    remove)  do_remove ;;
    status)  do_status ;;
    *) echo "用法：$0 {install|remove|status}" ;;
esac
