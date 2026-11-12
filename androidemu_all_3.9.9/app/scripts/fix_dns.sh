#!/bin/bash
### fix_dns.sh — 修正安卓容器「DNS 固定 8.8.8.8 导致国内域名解析到海外节点」（3.9.1 热修）
###
### 【问题现象】
###   同一台机器上，一部分应用联网正常，个别应用/游戏一直「无法联网 / 连接服务器失败」。
###
### 【根因（实测）】
###   redroid 镜像把 eth0 的静态 DNS 写死在 framework-res 里（8.8.8.8）：
###     dumpsys ethernet → "IP assignment: STATIC ... DNS servers: [ 8.8.8.8 ]"
###   Android 的应用 DNS 全部交给 netd，netd 再转发给 8.8.8.8。
###   国内访问 8.8.8.8 得到的多为「按海外出口」的答案，实测：
###     www.baidu.com  → 103.235.47.188（新加坡 wshifen）  而国内应为 183.2.172.177
###     game.163.com   → 42.186.160.148                     而国内应为 45.253.118.141
###   走海外 PoP 的 CDN/游戏服在国内可能完全不可达或极慢，于是表现为
###   「有的应用能联网、有的不能」——取决于该应用是否依赖实时域名解析。
###
### 【为什么不改配置文件】
###   试过改 $DATA/misc/ethernet/ipconfig.txt，重启后会被系统按镜像框架资源
###   覆盖回 8.8.8.8（实测，写进去 223.5.5.5，重启后又是 8.8.8.8）。
###   镜像里的 8.8.8.8 位于 /system/framework/framework-res.apk 资源内，
###   改它等于改系统包，风险远高于收益。
###
### 【本脚本的做法】
###   在容器**自己的网络命名空间**里加 OUTPUT DNAT：
###     发往 8.8.8.8 / 8.8.4.4 的 53 端口（UDP+TCP）→ 改投国内公共 DNS。
###   · 规则只存在于该容器的 netns，容器重建/删除即全部消失，宿主无残留规则；
###   · 只拦 Google 这两个 DNS 地址，不影响应用自行使用 DoH/硬编码 IP；
###   · 选定的国内 DNS 先做可用性探测，全部不可用时**不加规则**（保持原状，不冒险）。
###
### 【前置条件】
###   fnOS 内核默认没加载 legacy iptables 表，容器内 iptables 会报
###   "can't initialize iptables table `nat': Table does not exist"。
###   脚本会先 modprobe iptable_nat / iptable_filter / ip_tables（幂等、无配置残留）。
###
### 用法：fix_dns.sh [--status|--clean]

set -u
C="${FIXDNS_CNAME:-androidemu-android}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
LOG="$VAR_DIR/fix_dns.log"
mkdir -p "$VAR_DIR" 2>/dev/null || true
log(){ echo "[$(date '+%F %T')] fix_dns: $*" >>"$LOG" 2>/dev/null || true; }

running(){ [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]; }
dex(){ docker exec -u 0 "$C" sh -c "$1" 2>/dev/null; }

status_show(){
    echo "容器：$C（$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null || echo 未知)）"
    echo "安卓侧 DNS（netd 实际使用的上游）：$(dex 'dumpsys connectivity 2>/dev/null' | grep -o 'DnsAddresses: \[[^]]*\]' | head -1)"
    echo "容器内 DNS 重定向规则："
    dex 'iptables -t nat -S OUTPUT 2>/dev/null' | grep -E 'dport 53' | sed 's/^/  /' || echo "  （无）"
}

clean_all(){
    running || { echo "容器未运行，无需清理（规则随 netns 消失）"; return 0; }
    dex 'for ip in 8.8.8.8 8.8.4.4; do for p in udp tcp; do iptables -t nat -D OUTPUT -p $p -d $ip --dport 53 -j DNAT --to-destination 223.5.5.5 2>/dev/null; done; done' >/dev/null 2>&1
    echo "已移除 DNS 重定向规则"
}

case "${1:-}" in
    --status) status_show; exit 0 ;;
    --clean)  clean_all; exit 0 ;;
esac

running || { echo "fix_dns: 容器未运行，跳过"; exit 0; }

### 1) 加载 legacy iptables 表（fnOS 默认未加载；已加载时为秒返回）
for _m in iptable_nat iptable_filter ip_tables; do
    modprobe "$_m" >/dev/null 2>&1 || true
done

### 2) 探测可用的国内公共 DNS（全部不可用则不加规则，保持原状）
DNS_SEL=""
for _d in 223.5.5.5 119.29.29.29 114.114.114.114; do
    if command -v nslookup >/dev/null 2>&1; then
        timeout 4 nslookup qq.com "$_d" >/dev/null 2>&1 && { DNS_SEL="$_d"; break; }
    else
        DNS_SEL="$_d"; break
    fi
done
if [ -z "$DNS_SEL" ]; then
    log "国内公共 DNS 均探测失败，本次不修改 DNS 走向（保持镜像默认）"
    echo "fix_dns: 探测失败，保持原状"
    exit 0
fi

### 3) 幂等写入 DNAT 规则（UDP/TCP × 8.8.8.8/8.8.4.4）
_ok=0
for _ip in 8.8.8.8 8.8.4.4; do
    for _p in udp tcp; do
        if dex "iptables -t nat -C OUTPUT -p $_p -d $_ip --dport 53 -j DNAT --to-destination $DNS_SEL" >/dev/null 2>&1; then
            _ok=$((_ok+1))
        elif dex "iptables -t nat -A OUTPUT -p $_p -d $_ip --dport 53 -j DNAT --to-destination $DNS_SEL" >/dev/null 2>&1; then
            _ok=$((_ok+1))
        fi
    done
done

### 4) 校验：规则数 + 安卓侧是否已生效
CNT=$(dex "iptables -t nat -S OUTPUT 2>/dev/null" | grep -c "dport 53")
if [ "$CNT" -ge 4 ]; then
    log "DNS 重定向已生效：8.8.8.8/8.8.4.4:53 → $DNS_SEL（规则 $CNT 条）"
    echo "fix_dns: 已把容器 DNS 查询改投 $DNS_SEL（规则 $CNT 条）"
else
    log "DNS 重定向未完全生效（规则 $CNT 条，期望 4）；容器内 iptables 可能不可用"
    echo "fix_dns: 规则未生效（$CNT/4），保持镜像默认 DNS"
fi
exit 0
