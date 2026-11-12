#!/bin/bash
### net_util.sh — 局域网 IP 探测（3.9.1）
###
### 为什么需要它：飞牛上 `hostname -I` 会把 Docker 网桥排在前面
### （实测返回 "172.18.0.1 172.17.0.1 192.168.1.11"），若直接取第一个，
### PUBLIC_IP / ICE_SERVERS 会写成 docker 网桥地址 → 客户端拿到不可达的
### ICE 候选 → 「有画面列表但 WebRTC 握手失败」。群友实测故障即此原因。
###
### 探测顺序：
###   1) 默认路由的源地址（ip route get 1.1.1.1）——OVS/bond/vlan 下也准确
###   2) 枚举网卡，排除 lo/docker*/br-*/veth*/virbr*/tun*/tap*，并跳过 172.16-31 网段
###   3) 同上但允许 172.16-31（真实内网可能是 172.x）
###   4) 最后回退 hostname -I，跳过 docker 网段与回环
ae_lan_ip() {
    local _ip=""
    if command -v ip >/dev/null 2>&1; then
        _ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9][0-9.]*\).*/\1/p' | head -n1)
        [ -n "$_ip" ] && { echo "$_ip"; return 0; }
        _ip=$(ip -4 -o addr show 2>/dev/null \
            | awk '$2 !~ /^(lo|docker|br-|veth|virbr|tun|tap)/ {print $4}' \
            | cut -d/ -f1 \
            | grep -vE '^(172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.)' \
            | head -n1)
        [ -n "$_ip" ] && { echo "$_ip"; return 0; }
        _ip=$(ip -4 -o addr show 2>/dev/null \
            | awk '$2 !~ /^(lo|docker|br-|veth|virbr|tun|tap)/ {print $4}' \
            | cut -d/ -f1 | head -n1)
        [ -n "$_ip" ] && { echo "$_ip"; return 0; }
    fi
    for _ip in $(hostname -I 2>/dev/null); do
        case "$_ip" in
            127.*) : ;;
            172.1[6-9].*|172.2[0-9].*|172.3[01].*) : ;;
            *) echo "$_ip"; return 0 ;;
        esac
    done
    echo ""
}
