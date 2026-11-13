#!/bin/bash
### lan_bridge.sh — 局域网直连（macvlan）
###
### 让安卓容器在局域网获得独立 IP（如 192.168.x.x）：
###   · 局域网设备 ↔ 容器双向直连，mDNS/广播发现（飞牛 APP 等）可用
###   · 外网访问不受影响（面板/服务仍走宿主端口映射）
###   · OVS（虚拟机网络）环境不支持：检测到即明确提示并跳过，不做适配
###
### 用法：setup | attach | off | status
set +e
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
CONF="$VAR_DIR/lan_bridge.conf"
C="androidemu-android"
NET="androidemu_lan"
log(){ echo "[$(date '+%F %T')] lan_bridge: $*"; }

detect_net() {
    IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
    GW=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
    CIDR=$(ip -o -4 addr show "$IFACE" 2>/dev/null | awk '{print $4; exit}')
    [ -n "$IFACE" ] && [ -n "$CIDR" ] && [ -n "$GW" ] || return 1
    IPADDR=$(echo "$CIDR" | awk -F/ '{print $1}')
    PREFIX=$(echo "$CIDR" | awk -F/ '{print $2}')
    A=$(echo "$IPADDR" | cut -d. -f1); B=$(echo "$IPADDR" | cut -d. -f2)
    C3=$(echo "$IPADDR" | cut -d. -f3); D=$(echo "$IPADDR" | cut -d. -f4)
    M=$(( 0xFFFFFFFF << (32-PREFIX) & 0xFFFFFFFF ))
    N=$(( (A<<24 | B<<16 | C3<<8 | D) & M ))
    SUBNET="$(( (N>>24)&255 )).$(( (N>>16)&255 )).$(( (N>>8)&255 )).$(( N&255 ))"
    BASE3=$(echo "$SUBNET" | cut -d. -f1-3)
    return 0
}

setup() {
    if command -v ovs-vsctl >/dev/null 2>&1 && [ -n "$(ovs-vsctl list-br 2>/dev/null)" ]; then
        log "检测到 OVS（虚拟机网络，通常为虚拟机功能开启）：局域网直连不支持，已跳过。请关闭 OVS 或改用仅外网模式"
        exit 0
    fi
    detect_net || { log "无法探测局域网信息，跳过（保持 NAT）"; exit 0; }
    log "网卡=$IFACE 网段=$SUBNET/$PREFIX 网关=$GW"
    if ! docker network inspect "$NET" >/dev/null 2>&1; then
        docker network create -d macvlan --subnet="$SUBNET/$PREFIX" --gateway="$GW" \
            --ip-range="${BASE3}.248/29" -o parent="$IFACE" "$NET" >/dev/null 2>&1 \
        || { log "macvlan 创建失败（网卡不支持），保持 NAT 模式，不影响使用"; exit 0; }
    fi
    printf 'LAN_BRIDGE=1\nIFACE=%s\nSUBNET=%s/%s\nGATEWAY=%s\nIPRANGE=%s.248/29\n' \
        "$IFACE" "$SUBNET" "$PREFIX" "$GW" "$BASE3" > "$CONF" 2>/dev/null
    log "配置已写入 $CONF"
    ### 3.9.9：网络建出来不代表能接入（docker network create 不校验网卡能力）。
    ### 容器在跑就立刻试接一次，接不上就清理，绝不把「建得出、接不上」的网络留给下次启动。
    if docker inspect "$C" >/dev/null 2>&1 && [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]; then
        if docker network connect "$NET" "$C" >/dev/null 2>&1; then
            log "已即时接入局域网（macvlan）"
        else
            log "测试接入失败（网卡不支持 macvlan）→ 删除该网络并回退 NAT"
            docker network disconnect -f "$NET" "$C" >/dev/null 2>&1
            docker network rm "$NET" >/dev/null 2>&1
            rm -f "$CONF" 2>/dev/null
        fi
    fi
}

attach() {
    [ -f "$CONF" ] || exit 0
    . "$CONF" 2>/dev/null
    [ "$LAN_BRIDGE" = "1" ] || exit 0
    docker inspect "$C" >/dev/null 2>&1 || exit 0
    docker inspect -f '{{json .NetworkSettings.Networks}}' "$C" 2>/dev/null | grep -q "$NET" && exit 0
    ### 3.9.9 修复（实测 2026-11-13，群友机器重启后起不来）：
    ###   接入失败时若只打一行日志，网络与 conf 都会留着，容器下次 start 会带着
    ###   这个 macvlan 网络重新 attach，而某些网卡/驱动直接拒绝，报
    ###     Error response from daemon: failed to set up container networking:
    ###     failed to create the macvlan port: operation not supported
    ###   整个应用因此起不来（不是「局域网直连失效」，是「应用不可用」）。
    ###   现在一旦接入失败：断开 → 删网络 → 删 conf，彻底回退 NAT，不留下任何
    ###   会在下次启动时拖死容器的残留。
    if docker network connect "$NET" "$C" >/dev/null 2>&1; then
        log "容器已接入局域网（macvlan）"
    else
        log "接入失败（网卡不支持 macvlan 或网络未就绪）→ 关闭局域网直连并回退 NAT，避免下次启动被拖死"
        docker network disconnect -f "$NET" "$C" >/dev/null 2>&1
        docker network rm "$NET" >/dev/null 2>&1
        rm -f "$CONF" 2>/dev/null
        exit 0
    fi
    CIP=$(docker inspect -f "{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}" "$C" 2>/dev/null)
    [ -n "$CIP" ] && { iptables -C INPUT -s "$CIP" -j ACCEPT 2>/dev/null || iptables -I INPUT -s "$CIP" -j ACCEPT 2>/dev/null; }
}

off() {
    docker network disconnect "$NET" "$C" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -f "$CONF" 2>/dev/null
    log "局域网直连已关闭（恢复仅外网）"
}

status() {
    if [ -f "$CONF" ]; then
        echo "局域网直连: 开启"; cat "$CONF"
        docker inspect -f "{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}" "$C" 2>/dev/null | sed 's/^/容器局域网 IP: /'
    else
        echo "局域网直连: 关闭（仅外网访问）"
    fi
}

precheck() {
    ### 3.9.9：启动/启用前的自愈。
    ### 容器若挂着 androidemu_lan 但当前是停止状态，说明上次可能就是因为 macvlan
    ### attach 失败而起不来（"failed to create the macvlan port: operation not
    ### supported"）。此时先把网络摘掉、删掉，让容器按 compose 定义的 NAT 正常启动，
    ### 启动后 attach 阶段再按网卡实际能力决定是否重新接回局域网。
    docker inspect "$C" >/dev/null 2>&1 || { rm -f "$CONF" 2>/dev/null; exit 0; }
    [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ] && exit 0
    if docker inspect -f '{{json .NetworkSettings.Networks}}' "$C" 2>/dev/null | grep -q "$NET"; then
        log "容器未运行且挂着 $NET → 先摘除并删除该网络，避免下次启动报 macvlan operation not supported"
        docker network disconnect -f "$NET" "$C" >/dev/null 2>&1
        docker network rm "$NET" >/dev/null 2>&1
        rm -f "$CONF" 2>/dev/null
    fi
}

case "$1" in
    setup)  setup ;;
    attach) attach ;;
    off)    off ;;
    precheck) precheck ;;
    status) status ;;
    *) echo "用法: $0 {setup|attach|off|status|precheck}"; exit 1 ;;
esac
exit 0
