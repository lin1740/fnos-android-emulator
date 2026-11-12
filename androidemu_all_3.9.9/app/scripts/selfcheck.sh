#!/bin/bash
### selfcheck.sh — 启用前/排障用一键自检（只读，不改任何配置）
###
### 用途：用户反馈「启用失败 / 打不开 / 提示 compose或者container异常」时，
###      跑一次就能定位是哪一项前置条件不满足。结果同时写入
###      ${TRIM_PKGVAR}/selfcheck.txt，方便直接发给开发者。
###
### 用法： bash selfcheck.sh            # 打印并写文件
###        bash selfcheck.sh --quiet    # 只写文件
set +e

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
OUT="$VAR_DIR/selfcheck.txt"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

mkdir -p "$VAR_DIR" 2>/dev/null
if [ -f "$APP_DIR/scripts/rtconf.sh" ]; then
    # shellcheck disable=SC1091
    . "$APP_DIR/scripts/rtconf.sh"; rtconf_load
fi
: "${CANON_REDROID:=docker.fnnas.com/redroid/redroid:12.0.0-latest}"
: "${CANON_WEBRTC:=docker.fnnas.com/buutuu/scrcpy-over-webrtc:latest}"

FAIL=0
WARN=0
BUF=""
say(){ BUF="$BUF$1
"; }
ok(){   say "  [正常] $1"; }
bad(){  say "  [失败] $1"; FAIL=$((FAIL+1)); }
warn(){ say "  [注意] $1"; WARN=$((WARN+1)); }

say "================ androidemu 自检 $(date '+%F %T') ================"
say ""
say "一、系统与内核"
say "  架构：$(uname -m)　内核：$(uname -r)"
say "  内存：$(awk '/MemTotal/{printf "%d MB", $2/1024}' /proc/meminfo 2>/dev/null)"
say "  可用磁盘（应用目录）：$(df -h "$APP_DIR" 2>/dev/null | tail -1 | awk '{print $4}')"
if [ -e /dev/binder ]; then
    ok "内核 binder 设备存在（$(ls -l /dev/binder 2>/dev/null | sed 's/.*-> //')）"
else
    bad "内核 binder 设备 /dev/binder 不存在 —— 安卓容器无法创建"
fi

say ""
say "二、依赖应用 binder_linux（飞牛强制校验：它被停用时应用中心会直接拒绝启用本应用）"
if command -v appcenter-cli >/dev/null 2>&1; then
    _dep="$(appcenter-cli status binder_linux_driver 2>/dev/null | tr -d '\r\n')"
    case "$_dep" in
        running) ok "binder_linux_driver：running" ;;
        "")      warn "无法读取 binder_linux_driver 状态" ;;
        *)       bad "binder_linux_driver：$_dep —— 请到应用中心把它启用（这是「无法启用」最常见的原因）" ;;
    esac
else
    warn "未找到 appcenter-cli，跳过依赖应用检查"
fi

say ""
say "三、Docker 与 compose"
if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        ok "Docker 守护进程可用（$(docker version --format '{{.Server.Version}}' 2>/dev/null)）"
    else
        bad "Docker 守护进程不可用 —— 应用中心会提示「docker不可用」"
    fi
    if docker compose version >/dev/null 2>&1; then
        ok "docker compose 插件可用（$(docker compose version --short 2>/dev/null)）"
    else
        bad "缺少 docker compose 插件 —— 应用中心会提示「docker不可用」"
    fi
else
    bad "未找到 docker 命令"
fi

say ""
say "四、镜像"
for IMG in "$CANON_REDROID" "$CANON_WEBRTC"; do
    if docker image inspect "$IMG" >/dev/null 2>&1; then
        ok "已就绪：$IMG（$(docker image inspect -f '{{.Size}}' "$IMG" 2>/dev/null | awk '{printf "%.2f GB", $1/1073741824}')）"
    else
        bad "缺失：$IMG —— 首次安装需联网下载约 2GB，下载完成前「启用」会失败，请等下载完成或重试"
    fi
done

say ""
say "五、端口"
_PORTS="$VAR_DIR/ports.conf"
pcur(){ sed -n "s/^$1=//p" "$_PORTS" 2>/dev/null | head -n1; }
_WEB="$(pcur WEB_PORT)"; [ -n "$_WEB" ] || _WEB=8443
_TURN="$(pcur TURN_PORT)"; [ -n "$_TURN" ] || _TURN=3478
_ADB="$(pcur ADB_PORT)"; [ -n "$_ADB" ] || _ADB=5556
say "  画面端口 ${_WEB}/tcp　TURN ${_TURN}/tcp+udp　ADB ${_ADB}"
_MAPPED="$(docker ps --filter name=androidemu --format '{{.Ports}}' 2>/dev/null)"
if (exec 3<>/dev/tcp/127.0.0.1/"$_WEB") 2>/dev/null; then
    case "$_MAPPED" in
        *":${_WEB}->"*) ok "画面端口 ${_WEB} 已由本应用占用（正常）" ;;
        *) bad "画面端口 ${_WEB} 被其它程序占用 —— 请改用其它端口或释放它" ;;
    esac
    exec 3<&- 2>/dev/null
else
    ok "画面端口 ${_WEB} 当前空闲（容器未运行时属正常）"
fi

say ""
say "六、容器与数据卷"
for C in androidemu-android androidemu-webrtc; do
    _st="$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null)"
    case "$_st" in
        running)   ok "容器 $C：running" ;;
        restarting) bad "容器 $C 反复重启 —— 看 docker logs $C" ;;
        "")        warn "容器 $C 尚未创建（首次启用会自动创建）" ;;
        *)         warn "容器 $C：$_st" ;;
    esac
done
for V in androidemu-data androidemu-webrtc-data; do
    docker volume inspect "$V" >/dev/null 2>&1 && ok "数据卷 $V 存在" || warn "数据卷 $V 不存在（启用时会自动创建）"
done

say ""
say "七、容器内内核暴露面（只读检测）"
### 3.9.4：本节只读取状态，不修改任何配置。
### 目的：运行环境与宿主共享内核，需要确认三类关键资源是否正常：
###   ① /sys 的挂载形态（该模式下必然是 rw，属预期）；
###   ② /sys/power/state 是否已被 redroid 重定向（避免误以为「可写就会休眠宿主」）；
###   ③ cgroup 可写性（lmkd 分组回收的前提）与宿主 FUSE 连接数。
_RC=androidemu-android
if [ "$(docker inspect -f '{{.State.Running}}' "$_RC" 2>/dev/null)" = "true" ]; then
    _sysk="$(docker exec -u 0 "$_RC" sh -c 'grep -E "^sysfs /sys " /proc/mounts' 2>/dev/null | tr -d '\r\n')"
    case "$_sysk" in
        *" rw,"*|*" rw "*) warn "容器内 /sys 为可写（该模式的既定行为，属预期，不需处理）" ;;
        *)                 ok "容器内 /sys 为只读" ;;
    esac
    ### 判据说明：不能只看 test -w —— 系统身份有 CAP_DAC_OVERRIDE，对只读挂载仍返回「可写」，
    ### 属假阳性（实测确认）。判断是否触达宿主内核节点，要看它被挂到了哪里。
    _pwr_src="$(docker exec -u 0 "$_RC" sh -c 'awk "\$5==\"/sys/power/state\"{print \$4}" /proc/self/mountinfo 2>/dev/null | head -1' 2>/dev/null | tr -d '\r\n')"
    case "$_pwr_src" in
        *"/.empty"*)
            ok "/sys/power/state 已由 redroid 隔离（休眠请求落在 /data/.empty，不会触达宿主）" ;;
        "")
            ok "/sys/power/state 未被重定向（Android 尚未写入时属正常）" ;;
        *)
            ok "/sys/power/state 重定向到：$_pwr_src" ;;
    esac
    _fuse_n="$(docker exec -u 0 "$_RC" sh -c 'ls /sys/fs/fuse/connections 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r\n')"
    if [ "${_fuse_n:-0}" = "0" ]; then
        ok "宿主无 FUSE 连接（vold 关机时的 abort 扫描无对象）"
    else
        warn "宿主存在 ${_fuse_n} 个 FUSE 连接，Android 关机时会向它们写 abort（远程挂载类服务请留意）"
    fi
    _cgrw="$(docker exec -u 0 "$_RC" sh -c '[ -w /sys/fs/cgroup ] && echo yes || echo no' 2>/dev/null | tr -d '\r\n')"
    [ "$_cgrw" = "yes" ] && ok "容器内 cgroup 可写（lmkd 分组回收可正常工作）" \
                         || warn "容器内 cgroup 只读 —— 内存回收会退化为整体 OOM"
    ### APEX 命名空间链接配置：残缺时 new 出来的进程会 dlopen 失败（表现为部分应用起不来）。
    ### 只报大小不做自愈 —— 运行期重新生成会影响新进程的链接行为，风险大于收益。
    _lc="$(docker exec -u 0 "$_RC" sh -c 'wc -c < /linkerconfig/ld.config.txt 2>/dev/null' 2>/dev/null | tr -d '\r\n ')"
    case "$_lc" in
        ""|*[!0-9]*) warn "读不到 /linkerconfig/ld.config.txt（Android 可能未完全启动）" ;;
        *)
            if [ "$_lc" -gt 50000 ]; then
                ok "APEX 链接配置完整（${_lc} 字节）"
            else
                warn "APEX 链接配置偏小（${_lc} 字节）—— 若个别应用启动即退出，可重启本应用重试"
            fi ;;
    esac
else
    warn "安卓容器未运行，跳过容器内检测"
fi

say ""
say "八、compose 配置校验"
if [ -f "$APP_DIR/docker/docker-compose.yaml" ]; then
    if ( cd "$APP_DIR/docker" && docker compose config -q >/dev/null 2>&1 ); then
        ok "compose 配置可解析"
    else
        bad "compose 配置解析失败 —— 执行 cd $APP_DIR/docker && docker compose config 查看具体报错"
    fi
else
    bad "compose 文件缺失：$APP_DIR/docker/docker-compose.yaml"
fi
if [ -f "$APP_DIR/docker/androidemu-redroid-seccomp.json" ]; then
    ok "seccomp 安全配置存在"
else
    warn "seccomp 安全配置缺失（会被自动移除，安全性略降但不影响启动）"
fi

say ""
_PUB="$(sed -n 's/.*PUBLIC_IP=\([0-9.]*\).*/\1/p' "$APP_DIR/docker/docker-compose.yaml" 2>/dev/null | head -n1)"
say "九、画面服务对外地址"
say "  PUBLIC_IP=${_PUB:-未设置}"
case "$_PUB" in
    127.*|"") warn "PUBLIC_IP 仍是回环地址，局域网/外网投屏会连不上（面板「应用设置 → 访问方式」可一键修正）" ;;
    *)        ok "PUBLIC_IP 有效" ;;
esac

say ""
say "================ 结论 ================"
if [ "$FAIL" -gt 0 ]; then
    say "  发现 $FAIL 项失败、$WARN 项注意 —— 请先按上面标注处理，再回到应用中心点「启用」。"
    say "  失败项通常对应应用中心的提示：依赖应用被停用 / 构不成容器 →「compose或者container异常」；"
    say "  Docker 未运行或镜像拉取失败 →「docker不可用」。"
elif [ "$WARN" -gt 0 ]; then
    say "  未发现失败项，$WARN 项注意（多为容器尚未创建，属首次安装正常现象）。"
else
    say "  全部检查通过。若仍打不开，请看 ${VAR_DIR}/boot_guard.log 与 gateway.log。"
fi
say "  本报告已保存：$OUT"
say "  反馈地址：https://www.lin1740.de5.net/"

printf '%s' "$BUF" > "$OUT" 2>/dev/null
[ "$QUIET" = "1" ] || printf '%s' "$BUF"
exit 0
