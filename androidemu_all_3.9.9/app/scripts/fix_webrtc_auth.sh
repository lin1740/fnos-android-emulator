#!/bin/bash
### fix_webrtc_auth.sh — 修复「更新后云手机画面 bad gateway / 网关自动登录 401」
###
### 【现象】（群友实测，多次更新后复现，只有全新安装才正常）
###   应用中心点开 → bad gateway；gateway.log 里：
###     网关自动登录失败：上游返回 401
###     上游 401: GET /api/me
###
### 【根因（本机实测确认）】
###   云手机画面服务把账号存在数据卷 androidemu-webrtc-data 的 /app/data/users.json。
###   升级时该卷被保留，为了安全口令被改过（或由更早版本写入过别的哈希），
###   于是网关内置的默认口令（admin / admin123）跟文件里的 bcrypt 哈希对不上
###   → POST /api/login 恒返回 401 → 网关拿不到 token → 页面 bad gateway。
###   实测：把 users.json **删掉**再重启 webrtc，服务会用内置默认口令重新生成管理员，
###   登录立即恢复 200（说明服务本身有自举逻辑，只是文件存在时不会触发）。
###
### 【做法（保守、可回滚）】
###   1) 先用默认口令/ gw_admin.conf 里的口令试登录；成功就什么都不做（幂等）。
###   2) 失败才出手：备份 users.json → 删除 → 重启 webrtc 容器 → 等就绪 → 再验登录。
###   3) 仍失败 → 把备份还原回去（不破坏现场），只记录日志。
###   4) 成功 → 记录日志 + 状态文件，面板/文档可据此告知用户口令已恢复为默认。
###
### 【不做什么】
###   · 不动宿主网络/防火墙/其他容器；
###   · 不碰安卓数据；只在本应用自己的 webrtc 容器数据目录里动 users.json；
###   · 用户若在 var/gw_admin.conf 里显式写过口令，视为「自定义口令」，一律不重置。
###
### 用法：fix_webrtc_auth.sh [--force|--status]
###   --force   即使 gw_admin.conf 存在也尝试修复（用户明确要求时用）
###   --status  只报告当前登录状态与文件情况

set -u
C="${FIXAUTH_CNAME:-androidemu-webrtc}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
LOG="$VAR_DIR/webrtc_auth.log"
ADMIN_CONF="$VAR_DIR/gw_admin.conf"
STAMP="$VAR_DIR/webrtc_auth.repaired"
mkdir -p "$VAR_DIR" 2>/dev/null || true
log(){ echo "[$(date '+%F %T')] fix_webrtc_auth: $*" >>"$LOG" 2>/dev/null || true; }

running(){ [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]; }

### 端口与协议：优先 ports.conf，其次 compose，最后 8443
PORT=8443
for f in "$VAR_DIR/ports.conf" "/vol1/@appcenter/androidemu/docker/docker-compose.yaml"; do
    [ -f "$f" ] || continue
    v=$(sed -n 's/^WEB_PORT=//p' "$f" 2>/dev/null | head -n1)
    case "$v" in ''|*[!0-9]*) ;; *) PORT="$v" ;; esac
done

### 读凭据：gw_admin.conf > 环境变量 > 内置默认
U="admin"; P="admin123"
### 是否「用户自己改过口令」：**不能只看文件是否存在** —— 网关在用户从面板改密码时会
### 自动写这个文件（3.9.2 起），即使口令仍是内置默认值也会写。所以按内容比较：
### 用户名/口令与内置默认一致 → 视为未自定义，401 时允许自动修复；
### 不一致 → 视为用户自定义口令，默认不动（尊重用户设置）。
CUSTOM_PW=0
if [ -f "$ADMIN_CONF" ]; then
    line=$(head -n1 "$ADMIN_CONF" 2>/dev/null | tr -d '\r')
    case "$line" in
        *:*) U="${line%%:*}"; P="${line#*:}" ;;
    esac
    if [ "$U" != "admin" ] || [ "$P" != "admin123" ]; then
        CUSTOM_PW=1
    fi
fi

try_login(){
    # 返回 0 = 登录成功
    local _u="$1" _p="$2" _code
    for _scheme in https http; do
        _code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 -X POST \
            "$_scheme://127.0.0.1:$PORT/api/login" \
            -H 'Content-Type: application/json' \
            -d "{\"username\":\"$_u\",\"password\":\"$_p\"}" 2>/dev/null)
        case "$_code" in
            200) return 0 ;;
        esac
    done
    return 1
}

status_show(){
    echo "容器：$C（$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null || echo 未知)）"
    echo "端口：$PORT"
    if try_login "$U" "$P"; then
        echo "登录：成功（用户 $U）"
    else
        echo "登录：失败（401/不可达）—— 若页面 bad gateway，即是本脚本要修的场景"
    fi
    echo "users.json：$(docker exec "$C" sh -c 'ls -l /app/data/users.json 2>/dev/null | awk "{print \$5\" 字节  \"\$6\" \"\$7\" \"\$8}"' 2>/dev/null || echo 缺失)"
    echo "gw_admin.conf：$([ -f "$ADMIN_CONF" ] && echo 存在（视为自定义口令，默认不重置） || echo 不存在)"
    echo "上次修复：$(cat "$STAMP" 2>/dev/null || echo 无)"
}

case "${1:-}" in
    --status) status_show; exit 0 ;;
esac

running || { log "容器 $C 未运行，跳过"; exit 0; }

### 已经能登录 → 幂等返回
if try_login "$U" "$P"; then
    [ "${1:-}" = "--force" ] || { exit 0; }
fi

### 3.9.9 C1：默认不自动重置，除非显式 --force。
### 背景：gw_admin.conf 只在「经网关的面板改密」时自动更新；用户从 8443 直连改密码，
### 或用 0.4.4 的 /api/admin/users/rename 改了管理员用户名时，这个文件可能仍是默认值。
### 旧逻辑按 CUSTOM_PW=0 判定「未自定义」就删 users.json 自举默认管理员，会把用户
### 自己改的口令/用户名抹掉。现在默认只告警 + 给引导，避免任何情况下回到默认口令。
if [ "${1:-}" != "--force" ]; then
    if [ "$CUSTOM_PW" = "1" ]; then
        log "登录失败，且 gw_admin.conf 为自定义凭据 → 不重置（尊重用户设置）"
    else
        log "登录失败，且无法确认用户是否改过凭据（gw_admin.conf 可能漏捕获）→ 按保守策略不重置"
    fi
    log "若只是改过密码或用户名，请更新 var/gw_admin.conf（格式 用户名:密码）；确认要恢复默认管理员才手动执行 fix_webrtc_auth.sh --force"
    exit 0
fi

log "（--force）登录失败，开始修复：备份 users.json → 删除 → 重启容器让它自举默认管理员"

### 备份
BK="/app/data/users.json.bak.$(date +%s)"
if docker exec "$C" sh -c "test -f /app/data/users.json" >/dev/null 2>&1; then
    docker exec "$C" sh -c "cp -a /app/data/users.json $BK" >/dev/null 2>&1 \
        && log "已备份到 $BK（容器内）" || log "备份失败，继续（原文件将被删除）"
    docker exec "$C" sh -c 'rm -f /app/data/users.json' >/dev/null 2>&1
else
    log "users.json 本来就不存在（服务未自举过）"
fi

### 重启让它重新生成
docker restart "$C" >/dev/null 2>&1 || { log "重启容器失败"; exit 0; }

OK=0
for i in $(seq 1 20); do
    sleep 5
    if try_login "admin" "admin123"; then OK=1; break; fi
done

if [ "$OK" = "1" ]; then
    date '+%F %T' > "$STAMP" 2>/dev/null || true
    log "修复成功：已恢复默认管理员 admin / admin123（原 users.json 备份在容器内 $BK）"
    echo "fix_webrtc_auth: 已恢复默认口令（admin / admin123），原文件备份在 $BK"
    exit 0
fi

### 失败回滚
if docker exec "$C" sh -c "test -f $BK" >/dev/null 2>&1; then
    docker exec "$C" sh -c "cp -af $BK /app/data/users.json" >/dev/null 2>&1 && \
        docker restart "$C" >/dev/null 2>&1 && log "修复失败，已回滚原 users.json"
else
    log "修复失败，且无备份可回滚"
fi
echo "fix_webrtc_auth: 修复失败，已尝试回滚；详见 $LOG"
exit 0
