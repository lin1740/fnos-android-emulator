#!/bin/bash
### gw_socket.sh — 兼容外壳（3.0.3 起；3.0.5 起带 bash 启动兜底）
###
### 2.x 时代这个文件是「bash 守护 + 内嵌 python 代理」两个进程的实现；3.0.3 起统一网关
### 改由单进程 Python 实现：server/gateway.py（内部自带守护循环与自愈，不再有 PID 互杀）。
###
### 保留本文件名与参数（start|stop|restart|status|supervise|probe），是为了让
### scripts/start_pull_bg.sh、cmd/* 的回调，以及《应用介绍》《权限说明》里点名的
### 脚本名继续有效，外部看到的行为与旧版一致。
###
### 3.0.5（ARM 实测）：飞牛安装/升级回调的运行环境里，Python 的 subprocess.Popen 会直接
### 报 PermissionError(13)，于是"安装期拉起的网关"总是失败（安装日志实证）。因此这里对
### start 做兜底：先按正常方式调用 Python 入口；若没起来，再用 bash 原生的
### nohup + setsid 直接拉起守护（这正是 2.x 一直稳定可用的启动方式）。
set -u
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
PY="$APP_DIR/server/gateway.py"
ACT="${1:-start}"

if [ ! -f "$PY" ]; then
    echo "gw_socket: 缺少网关程序：$PY" >&2
    exit 1
fi

running() {
    # 只看"本用户自己的"常驻进程：别的用户（例如历史测试遗留）跑的同类进程不算数，
    # 否则会误判为"已在运行"而跳过兜底启动（x86 真机实测过这个问题）。
    local me; me=$(id -un)
    ps -eo user=,args 2>/dev/null | awk -v u="$me" '$1==u' | grep -E 'gateway\.py (serve|supervise)' | grep -v grep >/dev/null 2>&1
}

case "$ACT" in
    start|restart)
        # 先走 Python 入口（内含幂等判断、上一版残留清理、探活校验）
        python3 "$PY" "$ACT" || true
        if ! running; then
            echo "gw_socket: Python 入口未能拉起守护，改用 bash nohup/setsid 兜底"
            mkdir -p "$VAR_DIR" 2>/dev/null || true
            # 3.6.5：root环境下降权到应用用户启动（审核要求非root）
            if [ "$(id -u)" = "0" ] && id docker-androidemu >/dev/null 2>&1; then
                nohup setsid su -s /bin/bash docker-androidemu -c "python3 '$PY' supervise" >>"$VAR_DIR/gateway.log" 2>&1 &
            else
                nohup setsid python3 "$PY" supervise >>"$VAR_DIR/gateway.log" 2>&1 &
            fi
            sleep 3
            if running; then
                echo "gw_socket: 网关入口已就绪（bash 兜底启动）"
            else
                echo "gw_socket: 兜底启动后仍未就绪，详见 $VAR_DIR/gateway.log" >&2
                exit 1
            fi
        fi
        ;;
    *)
        exec python3 "$PY" "$ACT"
        ;;
esac
exit 0
