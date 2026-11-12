#!/bin/bash
### 3.9.1：启动前设备自愈。
### 背景：compose 模板的 devices 段包含 /dev/binder 与 /dev/net/tun。宿主上这些节点
### 一旦不存在（binder_linux 驱动被停用 / tun 模块未加载），docker compose up 会在
### 创建阶段直接失败，应用中心表现为「compose 或 container 异常」并反复启用失败。
### 安装阶段有检查（install_init），但运行期驱动可能被停用，故启动前必须再兜一次。
set +e
CHANGED=0

### 3.9.2：依赖应用「binder_linux」被停用后，飞牛应用中心会直接拒绝启用本应用
### （实测 appcenter-cli start 返回：Required application [binder_linux_driver] status stopped，
###  前端只显示「compose或者container异常 / docker不可用」这类笼统文案，用户完全看不出原因）。
### 应用用户自己不会想到要去启用它，故这里在检测到 binder 缺失时主动把依赖应用拉起来
### （幂等；已经是运行状态时 appcenter-cli 会直接返回 success）。仅在本应用自己的启动
### 链路里执行，不触碰其它应用。
### 注意：appcenter-cli 的权限是 700/系统账号（实测包用户执行报 Permission denied），
### 所以本应用**无权**替用户启用依赖应用；这里只在有能力时（以系统身份运行）顺手拉起，
### 读不到状态就如实标记为 unreadable，由自检报告与安装向导去提示用户。
_AE_DEP_STATE="unknown"
ensure_dep_app() {
    _AE_DEP_STATE="unknown"
    command -v appcenter-cli >/dev/null 2>&1 || { _AE_DEP_STATE="cli-missing"; return 0; }
    _st=$(appcenter-cli status binder_linux_driver 2>/dev/null | tr -d '\r\n')
    if [ -z "$_st" ]; then
        _AE_DEP_STATE="unreadable"
        return 0
    fi
    if [ "$_st" = "running" ]; then
        _AE_DEP_STATE="running"
        return 0
    fi
    appcenter-cli start binder_linux_driver >/dev/null 2>&1 || true
    sleep 2
    _st2=$(appcenter-cli status binder_linux_driver 2>/dev/null | tr -d '\r\n')
    if [ "$_st2" = "running" ]; then _AE_DEP_STATE="started"; else _AE_DEP_STATE="stopped"; fi
    return 0
}

ensure_binder() {
    [ -e /dev/binder ] && return 0
    if [ -e /dev/binder_linux ]; then
        ln -sf /dev/binder_linux /dev/binder 2>/dev/null && [ -e /dev/binder ] && return 0
    fi
    if [ -d /dev/binderfs ] && [ -n "$(ls -A /dev/binderfs 2>/dev/null)" ]; then
        [ -e /dev/binderfs/binder ] && { ln -sf /dev/binderfs/binder /dev/binder 2>/dev/null; [ -e /dev/binder ] && return 0; }
    fi
    ### 先补依赖应用（它会拉起内核 binder 驱动并创建 binderfs），再尝试 modprobe
    ensure_dep_app
    [ -e /dev/binder ] && return 0
    [ -e /dev/binderfs/binder ] && { ln -sf /dev/binderfs/binder /dev/binder 2>/dev/null; [ -e /dev/binder ] && return 0; }
    modprobe binder_linux 2>/dev/null || modprobe binder 2>/dev/null
    # 加载模块后节点可能自动出现
    [ -e /dev/binder ] && return 0
    mkdir -p /dev/binderfs 2>/dev/null
    mount -t binder binder /dev/binderfs 2>/dev/null
    if [ -e /dev/binderfs/binder ]; then
        ln -sf /dev/binderfs/binder /dev/binder 2>/dev/null
        [ -e /dev/binder ] && return 0
    fi
    # 静态节点兜底（x86 上 binder 主设备号固定为 10:45）
    mknod /dev/binder c 10 45 2>/dev/null && chmod 666 /dev/binder 2>/dev/null
    [ -e /dev/binder ] && return 0
    return 1
}

ensure_tun() {
    [ -e /dev/net/tun ] && return 0
    mkdir -p /dev/net 2>/dev/null
    modprobe tun 2>/dev/null
    mknod /dev/net/tun c 10 200 2>/dev/null && chmod 666 /dev/net/tun 2>/dev/null
    [ -e /dev/net/tun ] && return 0
    return 1
}

### 依赖应用优先：飞牛的依赖校验只看「依赖应用是否处于启用状态」，与设备节点是否存在无关。
### 只要它被停用（用户手动停 / 它自己开机没起来），应用中心就会拒绝启用本应用并给出
### 笼统的「compose或者container异常」，所以每次启动链路都先把它拉起来。
ensure_dep_app
case "$_AE_DEP_STATE" in
    running)  echo "ensure_devices: 依赖应用 binder_linux：运行中" ;;
    started)  echo "ensure_devices: 依赖应用 binder_linux：已顺手拉起" ;;
    stopped)  echo "ensure_devices: 依赖应用 binder_linux：已停用 —— 请在应用中心启用它，否则应用中心会拒绝启用本应用" ;;
    unreadable|cli-missing)
              echo "ensure_devices: 依赖应用 binder_linux：状态不可读（appcenter-cli 仅系统账号可执行，不影响运行）；若应用中心提示无法启用，请先在应用中心启用 binder_linux" ;;
    *)        echo "ensure_devices: 依赖应用 binder_linux：状态未知" ;;
esac

if ensure_binder; then
    echo "ensure_devices: binder 可用"
else
    echo "ensure_devices: binder 不可用（请在应用中心启用依赖应用 binder_linux 后重试启用本应用）"
    CHANGED=1
fi

if ensure_tun; then
    echo "ensure_devices: tun 可用"
else
    echo "ensure_devices: tun 不可用（VPN/代理类应用将无法使用，容器仍可开机）"
    CHANGED=1
fi

[ "$CHANGED" = "0" ] && echo "ensure_devices: 全部就绪"
exit 0
