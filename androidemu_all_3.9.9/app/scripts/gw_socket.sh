#!/bin/bash
### gw_socket.sh — 兼容外壳（3.0.3 起；3.0.5 起带 bash 启动兜底）
###
### 2.x 时代这个文件是「bash 守护 + 内嵌 python 代理」两个进程的实现；3.0.3 起统一网关
### 改由单进程 Go 实现：server/gateway_<arch>（内部自带守护循环与自愈）。
###
### 保留本文件名与参数（start|stop|restart|status|supervise|probe），是为了让
### scripts/start_pull_bg.sh、cmd/* 的回调，以及各处调用点里点名的
### 脚本名继续有效，外部看到的行为与旧版一致。
###
### 3.0.5（ARM 实测）：飞牛安装/升级回调的运行环境里，Python 的 subprocess.Popen 会直接
### 报 PermissionError(13)，于是"安装期拉起的网关"总是失败（安装日志实证）。因此这里对
### start 做兜底：先按正常方式调用 Go 网关（内含探活校验）；若没起来，再用 bash 原生的
### nohup + setsid 直接拉起守护（这正是 2.x 一直稳定可用的启动方式）。
set -u
### 3.9.9-r2：补齐 /usr/sbin 与常用系统目录，飞牛安装回调的 PATH 常不完整。
case ":${PATH:-}:" in
    *:/usr/sbin:*) ;;
    *) export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/sbin:/sbin" ;;
esac
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
ARCH=$(uname -m 2>/dev/null)
GOBIN="$APP_DIR/server/gateway_arm64"
case "$ARCH" in
    x86_64|amd64|i*86) GOBIN="$APP_DIR/server/gateway_amd64" ;;
esac
ACT="${1:-start}"

running() {
    # 3.9.9-r2：改为按「本应用路径」匹配，不再按当前用户过滤。
    # 安装回调以系统身份运行，而统一网关由包用户常驻；旧写法按 id -un 过滤，
    # 系统身份视角恒判「未就绪」→ 误走兜底再拉起一个网关，安装日志出现
    # 「Go 网关直启未就绪 / 兜底启动后仍未就绪」的噪音（x86 实体机实测）。
    # 用 APP_DIR 限定路径，不会把别的应用/历史残留的同类进程算进来。
    ps -eo args 2>/dev/null | grep -F "$APP_DIR/server/gateway" \
        | grep -E 'gateway(_amd64|_arm64|\.py) (serve|supervise)' | grep -v grep >/dev/null 2>&1
}

case "$ACT" in
    start|restart)
        # 3.9.1：优先 Go 版二进制（内含幂等判断、残留清理、探活校验）
        if [ -x "$GOBIN" ]; then
            TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" "$GOBIN" "$ACT" || true
            if running; then echo "gw_socket: Go 网关已在运行"; fi
        fi
        # Go 网关直启失败时的兜底（历史 3.0.5：安装期 Popen 报 PermissionError）
        if ! running; then
            echo "gw_socket: Go 网关直启未就绪，改用 bash nohup/setsid 兜底"
            mkdir -p "$VAR_DIR" 2>/dev/null || true
            if [ "$(id -u)" = "0" ] && id docker-androidemu >/dev/null 2>&1; then
                nohup setsid su -s /bin/bash docker-androidemu -c "'$GOBIN' supervise" >>"$VAR_DIR/gateway.log" 2>&1 &
            else
                nohup setsid "$GOBIN" supervise >>"$VAR_DIR/gateway.log" 2>&1 &
            fi
            ### 3.9.9-r2：网关起来需要几秒，单次 3 秒探活容易误判「仍未就绪」。
            _gwok=0
            for _gwi in 1 2 3; do
                sleep 3
                if running; then _gwok=1; break; fi
            done
            if [ "$_gwok" = "1" ]; then
                echo "gw_socket: 网关入口已就绪（bash 兜底启动）"
            else
                echo "gw_socket: 兜底启动后仍未就绪，详见 $VAR_DIR/gateway.log" >&2
                exit 1
            fi
        fi
        ;;
    *)
        exec "$GOBIN" "$ACT"
        ;;
esac
exit 0
