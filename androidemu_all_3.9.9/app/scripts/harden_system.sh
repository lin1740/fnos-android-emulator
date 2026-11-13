#!/bin/bash
### harden_system.sh — 容器"新手机"画像（去 调试特征）
###
### 作用：redroid 的 userdebug 构建自带 /system/xbin/su、ro.build.type=userdebug、
###       test-keys、ro.debuggable=1 —— 反 环境检测的应用一眼识别。本脚本在容器
###       创建后执行一次：删 su + build.prop 改为 user/release-keys/非 debuggable，
###       使系统对应用呈现"未调试的新手机"画像。
###
### 安全边界：
###   · 管理通道不受影响——adbd 本来就以 shell 身份运行（非系统身份），本应用全部
###     管理命令（settings/getprop/agent）均为 shell 权限级；
###   · 幂等：已处理则跳过，不重启容器；
###   · 容器 overlay 持久：重启不回退；仅容器重建（compose 重建）后需再次执行。
###
### 调用方：boot_guard 巡检（健康分支）或安装流程，容器运行时执行。
set +e
C="${ANDROIDEMU_CONTAINER:-androidemu-android}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
mkdir -p "$VAR_DIR" 2>/dev/null || true

### 3.9.2 热修：锁/标记文件可能是早期以系统身份跑的安装流程创建的（0:0 644），
### 之后以普通用户 docker-androidemu 运行的巡检写不了 → 节流与互斥双双失效
### （实测 /vol1/@appdata/androidemu/harden_system.lock: Permission denied 每分钟刷屏）。
### 统一改成：不可写就退到可写的临时目录。
_ae_wpath(){ # $1=文件名，输出一个可写的路径
    local n="$1" fb="${TMPDIR:-/tmp}/androidemu_$(id -u)"
    if [ -d "$VAR_DIR" ] && [ -w "$VAR_DIR" ] && { [ ! -e "$VAR_DIR/$n" ] || [ -w "$VAR_DIR/$n" ]; }; then
        printf '%s\n' "$VAR_DIR/$n"
    else
        mkdir -p "$fb" 2>/dev/null
        printf '%s\n' "$fb/$n"
    fi
}
STAMP=$(_ae_wpath harden_system.stamp)

# 仅容器在运行时处理
[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ] && exit 0

### 3.9.2 热修（升级后安卓起不来的真凶）：
###   原先没有节流也没有互斥 —— boot_guard 每次巡检都可能判定"仍是 userdebug"并
###   重启容器。实测升级场景 6 秒内连重启两次（两个守护实例并发），安卓 zygote 被
###   反复打断，最后 boot_completed 为空、zygote/surfaceflinger 全 stopped，
###   用户看到的就是"更新完全用不了，全新安装反而正常"。
###   现改为：① 互斥锁，同一时刻只允许一个实例；② 30 分钟内最多尝试一次，
###   失败也不再反复重启（失败信息写日志，留给人看）。
if command -v flock >/dev/null 2>&1; then
    _AE_LOCK=$(_ae_wpath harden_system.lock)
    if exec 9>"$_AE_LOCK" 2>/dev/null; then
        flock -n 9 2>/dev/null || exit 0
    fi
fi
### 标记内容 = "<容器短ID> <时间戳>"。只在**同一个容器**上节流：
### 容器被重建（重装/升级/compose 重建）后 /system 会恢复镜像原样，
### 必须重新清理调试特征，否则 su / userdebug / test-keys 又回来了（实测踩过：
### 重装后 30 分钟内被旧标记挡住，调试特征一直留着）。
_CID=$(docker inspect -f '{{.Id}}' "$C" 2>/dev/null | cut -c1-12)
if [ -f "$STAMP" ]; then
    read -r _scid _sts < "$STAMP" 2>/dev/null || true
    if [ "$_scid" = "$_CID" ]; then
        _age=$(( $(date +%s) - ${_sts:-0} ))
        if [ "$_age" -lt 1800 ]; then
            exit 0
        fi
    fi
fi

### 安卓还没开机完成时不要重启（会把正在进行的开机打断）
_BOOT=$(docker exec "$C" sh -c "getprop sys.boot_completed" 2>/dev/null | tr -d '\r\n')
if [ "$_BOOT" != "1" ]; then
    log_early(){ echo "[$(date '+%F %T')] harden_system: $*"; }
    log_early "安卓尚未开机完成（boot_completed=${_BOOT:-空}），本次不做任何重启"
    exit 0
fi

### 3.9.3 修正（重要）：把「是否重启容器」的判据拆成两级。
### 旧逻辑把 ro.hw_timeout_multiplier 为空也算进 NEED，而宿主身份伪装 props 文件里
### 本来就没有这一行、容器内 /system/build.prop 又是只读绑定挂载（append 必然失败）
### → 每次巡检都判「需要处理」，节流一过（30 分钟）就再重启一次容器。
### 实测 NAS：04:58 / 05:28 / 05:58 / 06:28 整点各重启一次，用户侧表现是
### 「内存从 2G 掉到几百 MB、应用全被清掉、然后画面重连」。
### 现在：真正的 调试特征（su / userdebug / test-keys / debuggable=1）才触发重启；
###      超时阈值这类「软属性」缺失只在宿主侧补写，不重启、也不进入节流计时。
HARD=0
if docker exec "$C" sh -c 'ls /system/xbin/su >/dev/null 2>&1 || ls /system/bin/su >/dev/null 2>&1' 2>/dev/null; then
    HARD=1
fi
BT=$(docker exec "$C" sh -c "getprop ro.build.type" 2>/dev/null | tr -d '\r\n')
[ "$BT" = "userdebug" ] && HARD=1
TAGS=$(docker exec "$C" sh -c "getprop ro.build.tags" 2>/dev/null | tr -d '\r\n')
[ "$TAGS" = "test-keys" ] && HARD=1
DBG=$(docker exec "$C" sh -c "getprop ro.debuggable" 2>/dev/null | tr -d '\r\n')
[ "$DBG" = "1" ] && HARD=1

### 软属性：宿主 props 文件里有就自然生效；没有则只在可写时补，不重启容器。
HTM=$(docker exec "$C" sh -c "getprop ro.hw_timeout_multiplier" 2>/dev/null | tr -d '\r\n')
if [ -z "$HTM" ]; then
    _pf="$VAR_DIR/props/system/build.prop"
    if [ -f "$_pf" ] && [ -w "$_pf" ] && ! grep -q '^ro\.hw_timeout_multiplier=' "$_pf" 2>/dev/null; then
        echo 'ro.hw_timeout_multiplier=5' >> "$_pf" 2>/dev/null \
            && echo "[$(date '+%F %T')] harden_system: 已补写宿主身份伪装属性 ro.hw_timeout_multiplier=5（下次容器重建生效，不重启）" || true
    fi
fi

[ "$HARD" = "0" ] && exit 0

log(){ echo "[$(date '+%F %T')] harden_system: $*"; }

### 3.9.9：先判断 /system 到底能不能写。
###   redroid 的 /system 是镜像只读层，且本应用并没有把 build.prop 绑定挂载进容器
###   （tune_compose.sh 里没有这一项），所以 ro.build.type / ro.build.tags /
###   ro.debuggable 在容器内**改不掉**。而旧逻辑仍然走「改 → docker restart → 复核」：
###   复核必然失败，30 分钟节流一过又重启一次。实测日志 21:06:34 与 21:10:56 连续两次，
###   redroid 的 init 不响应 SIGTERM，每次 restart 都被 SIGKILL（退出码 137），
###   boot_guard 看到容器宕机 301 秒就判定「应用已停用」，直接停掉画面服务 ——
###   用户看到的就是「应用莫名其妙没了 + 启用时报 docker不可用」。
###   现在：只读时只做「删 su」这一件真正有意义的安全动作，属性改不掉就记录在案，
###   不再重启容器。可写时（例如以后接入身份伪装挂载）才走原来的改写+重启流程。
_WRITABLE=$(docker exec "$C" sh -c 'if echo x > /system/.ae_wtest 2>/dev/null; then rm -f /system/.ae_wtest; echo 1; else echo 0; fi' 2>/dev/null | tr -d '\r\n')
if [ "$_WRITABLE" != "1" ]; then
    docker exec "$C" sh -c 'rm -f /system/xbin/su /system/bin/su /sbin/su 2>/dev/null; true' >/dev/null 2>&1 || true
    _SUCHK=$(docker exec "$C" sh -c 'ls /system/xbin/su /system/bin/su 2>/dev/null' | tr -d '\r\n')
    if [ -n "$_SUCHK" ]; then
        log "系统分区只读：su 仍存在（$_SUCHK），需人工处理；调试特征无法在容器内持久修改，跳过改写与容器重启（避免反复重启被判为应用停用）"
    else
        log "系统分区只读：已确认无 su；调试特征（type/tags/debuggable）无法在容器内持久修改，跳过改写与容器重启（避免反复重启被判为应用停用）"
    fi
    echo "$_CID $(date +%s)" > "$STAMP" 2>/dev/null || true
    exit 0
fi

log "检测到 userdebug 调试特征 → 应用新手机画像（删 su + 属性调整）"
docker exec "$C" sh -c "
rm -f /system/xbin/su /system/bin/su /sbin/su 2>/dev/null
### 关键：/system/build.prop 在本应用里可能是「身份伪装」挂进去的绑定挂载文件，
### sed -i 会先写临时文件再 rename，rename 绑定挂载点必然报
### 'Device or resource busy'（实测 ARM 上就是这里失败，debuggable 一直清不掉）。
### 因此改为：生成新内容 → cat 覆盖回原文件（保持 inode 不变）。
sed -e 's/^ro.build.type=userdebug/ro.build.type=user/' \
    -e 's/^ro.build.tags=test-keys/ro.build.tags=release-keys/' \
    -e 's/^ro\.system\.build\.type=userdebug/ro.system.build.type=user/' \
    -e 's/^ro\.system\.build\.tags=test-keys/ro.system.build.tags=release-keys/' \
    -e 's/^ro.debuggable=1/ro.debuggable=0/' \
    /system/build.prop > /data/local/tmp/.bp.new 2>/dev/null &&
cat /data/local/tmp/.bp.new > /system/build.prop 2>/dev/null
rm -f /data/local/tmp/.bp.new 2>/dev/null
### 3.9.1 热修：放宽安卓系统超时阈值 —— 弱算力 NAS 上 system_server watchdog 超时会导致
### 安卓系统反复软重启（表现为"用到一半突然回桌面/重启"，容器本身并未重启）。
grep -q '^ro.hw_timeout_multiplier=' /system/build.prop 2>/dev/null \
    || echo 'ro.hw_timeout_multiplier=5' >> /system/build.prop 2>/dev/null \
    || log "超时阈值写入失败（/system 只读，属正常——该值由身份伪装挂载提供）"
### 收尾恒为成功：真实效果由下方逐一 getprop 复核，谁没清干净日志里会打 ⚠，
### 不再因单条写入失败而整体报"exec 失败"（实测 NAS 上会误报并干扰节流标记）。
true
" || { log "exec 失败"; exit 1; }

log "重启容器以加载新属性..."
### 先落标记再重启：即使重启后仍被判定需要处理，30 分钟内也不会再触发第二次
echo "$_CID $(date +%s)" > "$STAMP" 2>/dev/null || true
docker restart "$C" >/dev/null 2>&1
for i in $(seq 1 36); do
    sleep 5
    [ "$(docker exec "$C" sh -c "getprop sys.boot_completed" 2>/dev/null | tr -d '\r\n')" = "1" ] && { log "容器重启完成（$((i*5))s）"; break; }
done
BT2=$(docker exec "$C" sh -c "getprop ro.build.type" 2>/dev/null | tr -d '\r\n')
DBG2=$(docker exec "$C" sh -c "getprop ro.debuggable" 2>/dev/null | tr -d '\r\n')
SU2=$(docker exec "$C" sh -c "ls /system/xbin/su 2>/dev/null" | tr -d '\r\n')
[ "$BT2" = "user" ] && [ "$DBG2" = "0" ] && [ -z "$SU2" ] \
    && log "✅ 新手机画像完成（user/release-keys/无su/非debuggable）" \
    || log "⚠ 部分特征未清除（type=$BT2 debuggable=$DBG2 su=${SU2:-无}）"
exit 0
