#!/bin/bash
# resolution_guard.sh —— 分辨率 16 对齐护栏（3.9.9）
#
# 作用：保证送进浏览器的 H.264 永远不带 frame_cropping。
#
# 背景（2026-11-09 实测，ffmpeg trace_headers 解 SPS）：
#   504x1088   -> mbs=32(512px), frame_cropping_flag=1, crop_right=4
#   1080x2340  -> mbs=68(1088px), frame_cropping_flag=1, crop_right=4 / crop_bottom=6
#   576x1280   -> mbs=36(576px), frame_cropping_flag=0
# H.264 宏块是 16x16，宽高不是 16 的倍数时编码器会补齐宏块再写 frame_cropping。
# WASM 软解自己算裁剪所以正常；浏览器硬解按未裁剪尺寸取 stride，
# 画面出现彩色条带 / 文字重影（花屏）。
# 外部独立佐证：51CTO《webrtc硬件编解码的坑》「没有对齐16的大小…直接花屏」。
#
# 结论：跟用哪个投屏服务、浏览器走硬解还是软解都无关，
#       只要 SPS 不带裁剪，两条路径都不会花屏。所以这里做的是「兜底收口」：
# 三处入口全部对齐到 16 的倍数：
#   1) 运行期 wm size / wm density（覆盖前端动态切换、用户手填、adb 改动）
#   2) docker-compose.yaml 的 androidboot.redroid_width/height/dpi（覆盖容器重建）
#   3) resolution.conf 的 PC/PHONE/TABLET（覆盖下次切换脚本读取）
#
# 设计约束（避免影响其它功能与安全）：
#   · 幂等：全部对齐时只写一次状态文件，不改任何东西、不重启容器
#   · 只在检测到「非 16 对齐」时才动作，正常情况零副作用
#   · 向下对齐（1080x2340 -> 1072x2336），保留用户想调大/调小的意图
#   · 不碰端口、不碰容器、不碰网关、不碰档位配置
#   · 状态文件由包用户写入，属主变更交给 install/upgrade 收尾统一处理

set +e

### 3.9.9-r2：飞牛安装回调 / 看护进程的 PATH 常不含 /usr/sbin（实测 environ 无 PATH），
### runuser 在 /usr/sbin/runuser。缺它时 `setsid -f runuser` 报
### "failed to execute runuser: No such file or directory"，护栏常驻根本起不来
### （2026-11-10 x86 实体机真实全新安装实测，日志累计 12 条）。只补缺失段。
case ":${PATH:-}:" in
    *:/usr/sbin:*) ;;
    *) export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/sbin:/sbin" ;;
esac

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
C="${ANDROID_CONTAINER:-androidemu-android}"
RES_CONF="$VAR_DIR/resolution.conf"
COMPOSE="$APP_DIR/docker/docker-compose.yaml"
STATUS="$VAR_DIR/resolution-guard.status"
LOG="$VAR_DIR/resolution-guard.log"

# 3.9.9：首次执行可能是系统身份（安装回调），留下的 644 文件会让包用户常驻写不进去。
# 这里主动把本脚本产生的文件交还包用户，避免刷 Permission denied 噪音。
_fix_owner() {
    local f
    for f in "$LOG" "$STATUS" "$VAR_DIR/resolution-guard.last" \
             "$VAR_DIR/resolution-guard.pid" "$VAR_DIR/resolution-guard.last_run"; do
        [ -f "$f" ] || continue
        if [ "$(id -u)" = "0" ] && [ -n "${TRIM_RUN_USERNAME:-}" ]; then
            chown "$TRIM_RUN_USERNAME" "$f" 2>/dev/null || true
        else
            # 包用户身份：若文件是 系统属主（历史残留 / 安装回调先跑过），
            # 用 >> 触碰会因权限失败。此时用同目录临时文件 + mv 原子替换自愈：
            # 依赖的是目录可写，不需要文件本身可写。
            if [ ! -w "$f" ]; then
                local t="${f}.$$"
                cat "$f" > "$t" 2>/dev/null || : > "$t"
                chmod 644 "$t" 2>/dev/null || true
                mv -f "$t" "$f" 2>/dev/null || rm -f "$t"
            fi
        fi
    done
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }
dex() { docker exec -u 0 "$C" sh -c "$1" 2>/dev/null | tr -d '\r\n'; }

align16() {  # 向下取整到 16 的倍数，最小 16
    local n="$1"
    case "$n" in ''|*[!0-9]*) echo 16; return ;; esac
    n=$(( n / 16 * 16 ))
    [ "$n" -lt 16 ] && n=16
    echo "$n"
}

main() {
    [ -f "$RES_CONF" ] || return 0
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$C" || return 0
    [ "$(dex 'getprop sys.boot_completed' 2>/dev/null)" = "1" ] || return 0

    _fix_owner
    local changed=0 detail=""

    ### 3.9.9-r3：旧版本升级迁移。upgrade_callback 若把 resolution.conf 的旧默认
    ### （1080x2340 / 1920x1080 等）换成了新默认，会留下 .res_default_migrated 标记。
    ### 此时运行期可能仍残留旧默认的 Override（1072x2336 / 1920x1072 / 720x1440 /
    ### 504x1088），需要执行一次 wm size reset 让物理分辨率（compose 新默认）生效。
    ### 只处理这一个白名单，用户自己设的其它值不动。
    if [ -f "$VAR_DIR/.res_default_migrated" ]; then
        local mcur mw mh
        mcur=$(dex 'wm size 2>/dev/null | grep -i "Override size" | tail -1')
        mw=$(echo "$mcur" | sed -E 's/.*: *([0-9]+)x([0-9]+).*/\1/')
        mh=$(echo "$mcur" | sed -E 's/.*: *([0-9]+)x([0-9]+).*/\2/')
        case "${mw}x${mh}" in
            1072x2336|1920x1072|720x1440|504x1088)
                dex 'wm size reset' >/dev/null 2>&1
                log "升级迁移：清除旧默认 Override ${mw}x${mh} -> 恢复物理分辨率"
                detail="${detail} wm-reset:${mw}x${mh}"
                changed=1
                ;;
        esac
        rm -f "$VAR_DIR/.res_default_migrated" 2>/dev/null || true
    fi

    # ---- 1) 运行期 wm size ----
    ### 若当前值非 16 对齐，优先回到 resolution.conf 的 DEFAULT 档（用户选定的值），
    ### 而不是简单向下取整：例如用户默认 576x1280，被前端切成 1080x2340 后，
    ### 直接取整会变成 1072x2336（虽然不花屏，但和用户预期差很多）。
    local def_key def_val def_w def_h
    def_key=$(grep -m1 '^DEFAULT=' "$RES_CONF" 2>/dev/null | cut -d= -f2)
    [ -z "$def_key" ] && def_key=PHONE
    def_val=$(grep -m1 "^${def_key}=" "$RES_CONF" 2>/dev/null | cut -d= -f2)
    def_w=$(echo "$def_val" | sed -E 's/^([0-9]+)x([0-9]+)$/\1/')
    def_h=$(echo "$def_val" | sed -E 's/^([0-9]+)x([0-9]+)$/\2/')
    case "$def_w" in ''|*[!0-9]*) def_w=0 ;; esac
    case "$def_h" in ''|*[!0-9]*) def_h=0 ;; esac
    def_w=$(align16 "$def_w"); def_h=$(align16 "$def_h")

    local cur raw_w raw_h aw ah
    cur=$(dex 'wm size 2>/dev/null | grep -i "Override size" | tail -1')
    raw_w=$(echo "$cur" | sed -E 's/.*: *([0-9]+)x([0-9]+).*/\1/')
    raw_h=$(echo "$cur" | sed -E 's/.*: *([0-9]+)x([0-9]+).*/\2/')
    if [ -z "$cur" ]; then  # 没有 Override，取 Physical
        raw_w=$(dex 'wm size 2>/dev/null | grep -i "Physical size" | tail -1' | sed -E 's/.*: *([0-9]+)x([0-9]+).*/\1/')
        raw_h=$(dex 'wm size 2>/dev/null | grep -i "Physical size" | tail -1' | sed -E 's/.*: *([0-9]+)x([0-9]+).*/\2/')
    fi
    case "$raw_w" in ''|*[!0-9]*) raw_w=0 ;; esac
    case "$raw_h" in ''|*[!0-9]*) raw_h=0 ;; esac
    if [ "$raw_w" -gt 0 ] && [ "$raw_h" -gt 0 ]; then
        aw=$(align16 "$raw_w"); ah=$(align16 "$raw_h")
        ### 3.9.9-r3：只有当前值「非 16 对齐」时才纠正；已对齐的合法值不再被 DEFAULT 档覆盖。
        ### 旧逻辑无条件 aw=$def_w，导致用户/前端动态切换的分辨率在 15 秒内被拉回默认，
        ### 且日志误报「非 16 对齐」（ARM 升级实测：576x1280 被改成 1072x2336）。
        if [ "$aw" != "$raw_w" ] || [ "$ah" != "$raw_h" ]; then
            if [ "$def_w" -ge 16 ] && [ "$def_h" -ge 16 ]; then
                aw=$def_w; ah=$def_h
            fi
            dex "wm size ${aw}x${ah}" >/dev/null 2>&1
            log "运行期分辨率 ${raw_w}x${raw_h} 非 16 对齐 -> 已纠正为 ${aw}x${ah}（避免硬解花屏）"
            detail="${detail} wm:${raw_w}x${raw_h}->${aw}x${ah}"
            changed=1
        fi
    fi

    # ---- 2) compose 里的启动参数（容器重建后生效）----
    if [ -f "$COMPOSE" ]; then
        local cw ch caw cah
        cw=$(grep -m1 'androidboot.redroid_width=' "$COMPOSE" 2>/dev/null | sed -E 's/.*=([0-9]+).*/\1/')
        ch=$(grep -m1 'androidboot.redroid_height=' "$COMPOSE" 2>/dev/null | sed -E 's/.*=([0-9]+).*/\1/')
        case "$cw" in ''|*[!0-9]*) cw=0 ;; esac
        case "$ch" in ''|*[!0-9]*) ch=0 ;; esac
        if [ "$cw" -gt 0 ] && [ "$ch" -gt 0 ]; then
            caw=$(align16 "$cw"); cah=$(align16 "$ch")
            if [ "$caw" != "$cw" ] || [ "$cah" != "$ch" ]; then
                sed -i "s/androidboot.redroid_width=[0-9]*/androidboot.redroid_width=${caw}/" "$COMPOSE" 2>/dev/null
                sed -i "s/androidboot.redroid_height=[0-9]*/androidboot.redroid_height=${cah}/" "$COMPOSE" 2>/dev/null
                log "compose 启动分辨率 ${cw}x${ch} 非 16 对齐 -> 已纠正为 ${caw}x${cah}（容器重建后不再回退）"
                detail="${detail} compose:${cw}x${ch}->${caw}x${cah}"
                changed=1
            fi
        fi
    fi

    # ---- 3) resolution.conf 三档配置 ----
    local key val w h nw nh
    for key in PC PHONE TABLET; do
        val=$(grep -m1 "^${key}=" "$RES_CONF" 2>/dev/null | cut -d= -f2)
        w=$(echo "$val" | sed -E 's/^([0-9]+)x([0-9]+)$/\1/')
        h=$(echo "$val" | sed -E 's/^([0-9]+)x([0-9]+)$/\2/')
        case "$w" in ''|*[!0-9]*) continue ;; esac
        case "$h" in ''|*[!0-9]*) continue ;; esac
        nw=$(align16 "$w"); nh=$(align16 "$h")
        if [ "$nw" != "$w" ] || [ "$nh" != "$h" ]; then
            sed -i "s/^${key}=.*/${key}=${nw}x${nh}/" "$RES_CONF" 2>/dev/null
            log "resolution.conf ${key} ${w}x${h} -> ${nw}x${nh}"
            detail="${detail} ${key}:${w}x${h}->${nw}x${nh}"
            changed=1
        fi
    done

    if [ "$changed" = "1" ]; then
        echo "corrected" > "$STATUS" 2>/dev/null || true
        echo "UPDATED=$(date '+%F %T') ACTIONS=${detail}" > "$VAR_DIR/resolution-guard.last" 2>/dev/null || true
        log "本轮护栏动作完成"
    else
        echo "aligned" > "$STATUS" 2>/dev/null || true
    fi
}

# supervise：独立常驻，15 秒一轮。
# 主看护 boot_guard 是 60 秒一轮，前端动态切分辨率若正好落在非对齐值，
# 最长会花屏 1 分钟。这里单独起一个轻量循环，只做幂等检查（对齐时零动作），
# 不重建容器、不碰端口，开销可忽略。
supervise() {
    echo $$ > "$VAR_DIR/resolution-guard.pid" 2>/dev/null || true
    while :; do
        main
        sleep 15
    done
}

case "${1:-once}" in
    once)      main ;;
    supervise) supervise ;;
    start)
        if pgrep -f "scripts/resolution_guard.sh supervise" >/dev/null 2>&1; then
            exit 0
        fi
        _RU="${TRIM_RUN_USERNAME:-docker-androidemu}"
        if [ "$(id -u)" = "0" ]; then
            ### 系统身份（安装 / 升级回调）：先把本脚本产生的文件属主交还包用户，
            ### 再「一次性」降权重新执行 start。runuser 执行完就退出，不常驻；
            ### 常驻的是包用户自己的 supervise，宿主侧不留 高权限父进程
            ### （3.9.9 实测旧写法会留下高权限 runuser 常驻，可能被 环境检测命中）。
            touch "$LOG" "$STATUS" 2>/dev/null || true
            _fix_owner
            _RB=/usr/sbin/runuser
            [ -x "$_RB" ] || _RB="$(command -v runuser 2>/dev/null || echo /usr/sbin/runuser)"
            "$_RB" -u "$_RU" -- \
                env TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" TRIM_RUN_USERNAME="$_RU" \
                bash "$APP_DIR/scripts/resolution_guard.sh" start >>"$LOG" 2>&1 < /dev/null || true
            sleep 2
            pgrep -f "scripts/resolution_guard.sh supervise" | head -1
            exit 0
        fi
        ### 包用户身份（boot_guard 每轮兜底 / 手动 start）：setsid -f 直接 fork，
        ### 父进程立即退出，不留任何 高权限包装进程；包用户可写自己的日志与状态。
        _fix_owner
        setsid -f env TRIM_APPDEST="$APP_DIR" TRIM_PKGVAR="$VAR_DIR" \
            bash "$APP_DIR/scripts/resolution_guard.sh" supervise \
            >>"$LOG" 2>&1 < /dev/null
        sleep 2
        pgrep -f "scripts/resolution_guard.sh supervise" | head -1
        ;;
    stop)
        for _p in $(pgrep -f "scripts/resolution_guard.sh supervise" 2>/dev/null); do
            kill -9 "$_p" 2>/dev/null || true
        done
        rm -f "$VAR_DIR/resolution-guard.pid" 2>/dev/null || true
        ;;
    status)    cat "$STATUS" 2>/dev/null || echo unknown
               cat "$VAR_DIR/resolution-guard.last" 2>/dev/null || true ;;
    *)         echo "用法：$0 {once|start|stop|status|supervise}" ;;
esac
