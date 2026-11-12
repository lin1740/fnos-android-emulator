#!/bin/bash
### turn_ports.sh — TURN 中继端口段占用预检（仅在冲突时换段）
###
### 背景：webrtc 容器以 bridge 网络映射整个中继段（默认 50000-50029/udp）。若宿主上
###   已有其它程序占用其中任意一个 UDP 端口（实测 ARM 机 pxy 占着 50054），Docker 全段
###   绑定失败 → 容器停在 Created（现象：装好了但设备永不上线，docker ps 不像崩溃）。
###   3.8.9 曾做过自动避让，后因「不破坏已有端口转发规则」被撤销；本脚本按「只在冲突时
###   才换段」回归该能力：无冲突时**完全不动**（保留 50000-50029），有冲突时换到一段
###   全空闲窗口并同步 compose 映射与容器内 COTURN_MIN/MAX_PORT（coturn 不支持端口
###   转换，两边必须一致），同时打印醒目提示（已做外网映射的用户需同步修改）。
###
### 用法：
###   turn_ports.sh                # 预检并按需换段（幂等；供安装/升级/切网络模式调用）
###   turn_ports.sh --show         # 只打印当前段与占用情况，不修改
###   turn_ports.sh --relay A-B    # 手动指定中继段（仍会做占用预检）
###
### 判定方式：UDP 试绑定（最准确，不受进程归属干扰）。当前运行中的本应用容器已发布的
###   端口会被排除（否则会把自己算成冲突、每次运行都换段 → 段号漂移破坏用户路由映射）。
set -u

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"
CONF="$VAR_DIR/ports.conf"
CONTAINER="androidemu-webrtc"

MIN="${TURN_RELAY_MIN:-50000}"
MAX="${TURN_RELAY_MAX:-50029}"
if [ -f "$CONF" ]; then
    _v=$(sed -n 's/^TURN_RELAY_MIN=//p' "$CONF" | head -n1); case "$_v" in ''|*[!0-9]*) ;; *) MIN="$_v" ;; esac
    _v=$(sed -n 's/^TURN_RELAY_MAX=//p' "$CONF" | head -n1); case "$_v" in ''|*[!0-9]*) ;; *) MAX="$_v" ;; esac
fi

### 3.9.4：中继段默认值由 50000-50100 收窄为 50000-50029。
###   原因：每个已发布的 UDP 端口在宿主要常驻 2 个 docker-proxy 进程（IPv4/IPv6 各一），
###   单进程约 6.5MB —— 101 个端口就是 202 个进程、约 1.3GB 内存，而家用场景通常只有
###   1~2 路观看，属严重过剩。老版本写进 ports.conf / compose 的就是旧默认段，若不识别
###   会被当成「用户自定义」永久保留旧段，故把「旧默认段」等同于「未定制」自动迁移；
###   用户若显式设置 TURN_RELAY_MIN/MAX 环境变量，则完全尊重，不做迁移。
LEGACY_RELAY_DEFAULT="50000-50100"
if [ "${MIN}-${MAX}" = "$LEGACY_RELAY_DEFAULT" ] && [ -z "${TURN_RELAY_MIN:-}" ] && [ -z "${TURN_RELAY_MAX:-}" ]; then
    MIN="50000"; MAX="50029"
fi

MODE="apply"
case "${1:-}" in
    --show) MODE="show" ;;
    --relay)
        R="${2:-}"
        case "$R" in
            [0-9]*-[0-9]*)
                MIN="${R%-*}"; MAX="${R#*-}"
                case "$MIN$MAX" in *[!0-9]*) echo "turn_ports: --relay 参数非法：$R" >&2; exit 1 ;; esac
                MODE="apply" ;;
            *) echo "turn_ports: 用法 --relay 25000-25099" >&2; exit 1 ;;
        esac
        ;;
esac

### --relay 显式指定时以命令行为准；否则若 compose 里是用户自定义段（非模板默认、非配置段），
### 采用它并回写配置 —— 尊重用户改动，绝不擅自覆盖。探测前就确定，避免对错误段做冲突判定。
if [ "${1:-}" != "--relay" ] && [ -f "$COMPOSE" ]; then
    _cur_range=$(grep -oE '"?[0-9]+-[0-9]+:[0-9]+-[0-9]+/udp"?' "$COMPOSE" 2>/dev/null | head -n1 | tr -d '"' | cut -d: -f1)
    if [ -n "$_cur_range" ] && [ "$_cur_range" != "${MIN}-${MAX}" ] \
       && [ "$_cur_range" != "50000-50029" ] && [ "$_cur_range" != "$LEGACY_RELAY_DEFAULT" ]; then
        echo "turn_ports: 检测到自定义中继段 ${_cur_range}（与配置不同）→ 采用该段"
        MIN="${_cur_range%-*}"; MAX="${_cur_range#*-}"
    fi
fi

### 本容器已发布的 UDP 端口（运行中才可信；created 状态尚未绑定，不能排除）
### docker port 输出形如 "25000/udp -> 0.0.0.0:25000"，端口是第一段里 "/" 之前的部分。
### 3.9.1 修复：原 awk 取 $2 取到的是 "udp"，导致自己的端口没被排除 → 误判冲突 → 段号漂移。
OWN_PORTS=""
if docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    OWN_PORTS=$(docker port "$CONTAINER" 2>/dev/null | awk '/\/udp/ {split($1,a,"/"); print a[1]}' | tr '\n' ' ')
fi

### UDP 试绑定探测：输出被占用的端口（每行一个）；python3 不可用时退回 ss
probe_occupied(){
    local lohi="$1" lohi_min="${1%-*}" lohi_max="${1#*-}"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$lohi_min" "$lohi_max" "$OWN_PORTS" <<'PY'
import socket, sys
a, b = int(sys.argv[1]), int(sys.argv[2])
own = set(int(x) for x in sys.argv[3].split() if x.isdigit())
for p in range(a, b + 1):
    if p in own:
        continue
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("0.0.0.0", p))
    except OSError:
        print(p)
    finally:
        s.close()
PY
        return
    fi
    ### 兜底：ss 里排除本容器端口后取监听者（docker-proxy 归属无法区分，保守视为占用）
    ss -uln 2>/dev/null | awk -v a="$lohi_min" -v b="$lohi_max" -v own="$OWN_PORTS" '
        NR>1 { n=split($5,f,":"); p=f[n]+0; if (p>=a && p<=b) print p }
    ' | while read -r p; do
        case " $OWN_PORTS " in *" $p "*) continue ;; esac
        echo "$p"
    done | sort -u
}

OCCUPIED="$(probe_occupied "${MIN}-${MAX}" | tr '\n' ' ' | sed 's/ *$//')"

if [ "$MODE" = "show" ]; then
    echo "turn_ports: 当前中继段 ${MIN}-${MAX}"
    if [ -n "$OCCUPIED" ]; then
        echo "turn_ports: 被占用端口：$OCCUPIED"
    else
        echo "turn_ports: 段内无冲突"
    fi
    exit 0
fi

if [ -n "$OCCUPIED" ]; then
    echo "turn_ports: ⚠ 中继段 ${MIN}-${MAX} 存在占用（$OCCUPIED），尝试切换到空闲段…"

    ### 候选段：避开系统临时端口段 32768-60999，也避开当前段
    NEW_MIN=""; NEW_MAX=""
    for CAND in 25000-25029 25100-25129 25200-25229 25300-25329 26000-26029 30000-30029 31000-31029; do
        [ "$CAND" = "${MIN}-${MAX}" ] && continue
        if [ -z "$(probe_occupied "$CAND" | tr -d ' \n')" ]; then
            NEW_MIN="${CAND%-*}"; NEW_MAX="${CAND#*-}"
            break
        fi
    done
    if [ -z "$NEW_MIN" ]; then
        echo "turn_ports: ✗ 未找到可用空闲段，保持 ${MIN}-${MAX}；请用 set_ports.sh 或 --relay 手动指定" >&2
        exit 1
    fi
    OLD_MIN="$MIN"; OLD_MAX="$MAX"
    MIN="$NEW_MIN"; MAX="$NEW_MAX"
else
    OLD_MIN=""; OLD_MAX=""
fi

### 无条件让 compose 与本配置段保持一致：
###   新包模板里的映射行固定是默认段（50000-50029），升级/重装会把它覆盖回来；
###   若此前因冲突换过段（ports.conf 记着 25000-25099），这里必须把 compose 同步回去，
###   否则「conf 无冲突→不动」会留下 50000 映射 → 同一台机器升级后再次起不来（实测踩到）。
###   无冲突且 compose 已一致时为纯空操作。
if [ -f "$COMPOSE" ]; then
    _gw="$APP_DIR/server/gateway_amd64"
    [ "$(uname -m 2>/dev/null)" = "aarch64" ] && _gw="$APP_DIR/server/gateway_arm64"
    if [ ! -x "$_gw" ]; then
        echo "turn_ports: ✗ 未找到可执行的网关二进制（editcompose 不可用），已放弃写入（避免映射与容器内端口段不一致）" >&2
        exit 1
    fi
    if ! "$_gw" editcompose "$COMPOSE" set-env webrtc "COTURN_MIN_PORT=$MIN" >/dev/null 2>&1 \
       || ! "$_gw" editcompose "$COMPOSE" set-env webrtc "COTURN_MAX_PORT=$MAX" >/dev/null 2>&1; then
        echo "turn_ports: ✗ editcompose 写入 COTURN_MIN/MAX_PORT 失败，已放弃" >&2
        exit 1
    fi
    ### 映射行：匹配任意现有段（默认段或历史段），统一改写为目标段
    sed -i -E "s#^([[:space:]]*-[[:space:]]*)\"?[0-9]+-[0-9]+:[0-9]+-[0-9]+/udp\"?#\1\"${MIN}-${MAX}:${MIN}-${MAX}/udp\"#" "$COMPOSE" 2>/dev/null || true
    grep -q -- "${MIN}-${MAX}:${MIN}-${MAX}/udp" "$COMPOSE" || {
        echo "turn_ports: ✗ compose 映射行改写失败，已放弃" >&2
        exit 1
    }
    chmod 644 "$COMPOSE" 2>/dev/null || true
    ### 同步到 /docker（飞牛 docker-project 读取该路径）
    mkdir -p /docker 2>/dev/null || true
    cp -f "$COMPOSE" /docker/docker-compose.yaml 2>/dev/null || true
    chmod 644 /docker/docker-compose.yaml 2>/dev/null || true
fi

### 写 ports.conf（保留其它键；值未变也重写，保证幂等且与 compose 一致）
if [ -f "$CONF" ]; then
    grep -vE '^TURN_RELAY_(MIN|MAX)=' "$CONF" > "$CONF.tmp" 2>/dev/null || : > "$CONF.tmp"
    mv -f "$CONF.tmp" "$CONF" 2>/dev/null || true
fi
{ echo "TURN_RELAY_MIN=$MIN"; echo "TURN_RELAY_MAX=$MAX"; } >> "$CONF" 2>/dev/null || true

if [ -n "$OLD_MIN" ]; then
    echo "turn_ports: ✓ 中继段已改为 ${MIN}-${MAX}（compose 映射 + COTURN_MIN/MAX_PORT 已同步）"
    echo "turn_ports: ⚠ 若你先前在路由器/防火墙为 ${OLD_MIN}-${OLD_MAX}/udp 做过端口映射，请同步改为 ${MIN}-${MAX}/udp，否则外网中继不通"
    echo "turn_ports: 如已能直连（srflx）则无需改动；重新创建 webrtc 容器后生效"
else
    echo "turn_ports: 中继段 ${MIN}-${MAX} 无冲突，compose/容器配置已与之一致（未做变更即为空操作）"
fi
exit 0
