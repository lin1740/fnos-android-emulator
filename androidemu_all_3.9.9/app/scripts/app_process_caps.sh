#!/bin/bash
### app_process_caps.sh — 让「降权后的投屏核心进程」能启动 app_process
###
### 【它解决什么问题】（2026-11-08 主 NAS 实测，Android 12）
###   上游 cloudphone agent（0.4.3 与 0.4.4 均如此）强制把 CoreService 降权到 shell(uid 2000)
###   （日志：Executing CoreService with auto-dropped privileges (shell UID 2000)）；
###   而 redroid 的 /system/bin/app_process 在非 系统身份下启动时会先对
###   /data/dalvik-cache/<abi> 做 chown + chmod，shell 没有 CAP_CHOWN / CAP_FOWNER，
###   于是直接 abort：
###     Error changing dalvik-cache ownership : Operation not permitted
###     Error changing dalvik-cache permissions : Operation not permitted
###   面板表现为点「连接」即失败：
###     CoreService exited unexpectedly … UID=2000 GID=0 LookPath=/system/bin/app_process
###   实测：uid 0 运行同一命令正常；uid 2000 必定 abort；补 ANDROID_DATA 也一样。
###   agent 的降权写死在二进制里（旧启动参数已废弃）、PATH 也固定，没法从启动方式绕开。
###
### 【做法】三步，全部幂等：
###   1) 把 /system/bin/app_process64 复制到数据卷（/data/local/tmp/app_process）；
###   2) 在**宿主**给该副本加 cap_chown/cap_fowner/cap_dac_override/cap_dac_read_search
###      （只这四项文件权限类能力，不授予 setuid/setgid/cap_sys_admin 等提权类能力）；能力挂在文件 xattr 上，随数据卷持久，容器重建后仍在；
###   3) 容器内 bind mount 覆盖 /system/bin/app_process64 —— agent 的 PATH 固定包含
###      /system/bin，只能从这里生效。副本内容与系统文件完全一致，只多了两个能力。
###   宿主侧仍是普通用户运行；容器内进程身份仍是 shell(2000)，宿主 ps 看不到高权限 agent。
###
### 用法：app_process_caps.sh [--install|--runtime|--preflight|--status]
###   --install  安装/升级回调、启用（系统身份）用：复制 + 校正执行位 + setcap + mount
###   --runtime  看护（包用户）用：缺副本则复制、执行位不对则纠正、缺 mount 则挂载；
###              cap 缺失只记录告警（包用户设不了 cap，需系统身份时机补）
###   --preflight agent 启动前用：可用就秒退，不可用立刻修（保证 agent 起时就能投屏）
###   --status   打印当前状态（含「shell 可执行」一项）
### 退出码恒为 0（失败不阻断安装/启动，后续巡检会重试）。
###
### 【2026-11-15 补充】副本的**属主**改成 shell(2000)，这是「用户不需要手工敲命令」的关键：
###   实测（群友两台机器 + 主 NAS 当天共 4 次）副本会莫名其妙掉到 700：
###     -rwx------ 1 docker-androidemu docker
###   属主是包用户(961)时，others 无 x → 降权到 shell(2000) 的 agent 被内核直接拒绝，
###   面板报 failed to start scrcpy-server: fork/exec /system/bin/app_process: permission denied。
###   过去只能靠「60 秒巡检改回 755」或让用户手工 chmod，体验就是「时不时抽一下」。
###   把属主改成 2000 后，同一份 700 文件对 2000 是**属主可执行**，实测：
###     chown 2000:2000 + chmod 700 → 以 2000 身份 exec 成功跑起来（只在缺 ANDROID_DATA 时 abort）。
###   于是即使有人再把 mode 改成 700，用户侧也不再失败。属主由 exec_ok 里的 stat 校验兜住。
###
### 【2026-11-10 补充】副本的**执行位**是比 capability 更前置的必要条件：
###   实测副本被写成 700（others 无 x）时，agent 降权到 shell(2000) 后 exec 直接被
###   内核拒绝，面板报「Failed to start scrcpy-server: fork/exec /system/bin/app_process:
###   permission denied」，连 dalvik-cache 那一步都走不到。同一份文件去掉全部
###   capability、只留 755，CoreService 仍能正常 RuntimeInit uid 2000 —— 说明 cap 是
###   保险项、执行位才是硬门槛。因此自检必须**用 shell(2000) 身份**判断（系统身份对 700
###   文件也能执行，用系统身份判断会漏检），且「已挂载」不等于「可执行」，不能作为早退条件。

set -u
ACTION="${1:---runtime}"
C="${AE_CONTAINER:-androidemu-android}"
APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
LOG="$VAR_DIR/app_process_caps.log"
mkdir -p "$VAR_DIR" 2>/dev/null || true
if [ -f "$LOG" ] && [ ! -w "$LOG" ]; then LOG="/tmp/androidemu-app_process_caps.log"; fi
if ! ( : >> "$LOG" ) 2>/dev/null; then LOG="/tmp/androidemu-app_process_caps.log"; fi
log(){ echo "[$(date '+%F %T')] app_process_caps: $*" >>"$LOG" 2>/dev/null || true; }

running(){ [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]; }
mounted(){ docker exec -u 0 "$C" sh -c 'awk "\$2==\"/system/bin/app_process64\"{f=1} END{exit !f}" /proc/mounts 2>/dev/null'; }
has_copy(){ docker exec -u 0 "$C" sh -c 'test -s /data/local/tmp/app_process' >/dev/null 2>&1; }
### 关键自检：**以 shell(2000) 的身份**判断能否执行 /system/bin/app_process64。
### 不能用系统身份判断 —— 系统身份对 700 文件也能执行，会漏掉真问题（2026-11-10 实测：
### 副本被写成 700（others 无 x），agent 降权到 shell 后 exec 直接被内核拒，
### 面板报 Failed to start scrcpy-server: fork/exec /system/bin/app_process: permission denied）。
### 【2026-11-15】从「test -x」升级为「真跑一次」：
###   test -x 只看权限位，三种真故障它看不出来 ——
###     (a) 挂载点带 noexec（位是 x，exec 仍 EACCES）；
###     (b) 文件残留无效的 security.capability（内核 exec 返回 EACCES）；
###     (c) 上层再叠一层只读/特殊挂载把我们的副本遮住。
###   三者对 agent 的表现完全一样（permission denied），所以自检必须等价于 agent 的
###   真实行为：以 shell(2000) 身份真启动一次，只在输出里出现 permission denied 时
###   判为不可用。无参数启动会以 "ANDROID_DATA environment variable unset" abort，
###   那是**程序已跑起来**的正常表现，不算失败。
exec_ok(){
    docker exec -u 2000 "$C" sh -c '
        test -x /system/bin/app_process64 || exit 1
        ### 3.9.9-r22：属主必须是 shell(2000)。见下方 ensure_mode 里关于 700 的说明：
        ### 属主是包用户(961)时，一旦 mode 掉到 700（others 无 x），降权后的 agent
        ### 就会被内核拒绝；属主是 2000 时同样的 700 仍可执行，用户不会再撞到失败。
        [ "$(stat -c %u /data/local/tmp/app_process 2>/dev/null)" = "2000" ] || exit 1
        _o=$(/system/bin/app_process64 2>&1 | head -3)
        case "$_o" in
            *ermission\ denied*) exit 1 ;;
        esac
        exit 0' >/dev/null 2>&1
}

ensure_copy(){
    if has_copy && exec_ok; then return 0; fi
    ### 已经挂载时源与目标是同一个 inode，此时 cp 等于"自己覆盖自己"，必须交给
    ### ensure_mode 修执行位（2026-11-10 实测场景：挂载在、副本却是 700）。
    if has_copy && mounted; then return 0; fi
    ### 副本缺失、为空、或不可执行时才重取；cp 后显式校正模式，
    ### 避免"cp 用了更严格的 umask（容器内 077 时会直接生成 700）"。
    ### 3.9.9-r22：同时把属主改成 shell(2000) —— 见 ensure_mode 里的说明。
    docker exec -u 0 "$C" sh -c '
        cp -f /system/bin/app_process64 /data/local/tmp/app_process 2>/dev/null
        chmod 755 /data/local/tmp/app_process 2>/dev/null
        chown 2000:2000 /data/local/tmp/app_process 2>/dev/null' >/dev/null 2>&1
    if has_copy; then
        log "已复制 app_process64 → /data/local/tmp/app_process（并校正为 755、属主 shell）"
        return 0
    fi
    log "复制 app_process64 失败"
    return 1
}

### 只校正执行位，不动属主 —— chmod 不会清除 security.capability（chown 会）。
ensure_mode(){
    exec_ok && return 0
    ### 3.9.9-r19：记下修复前的真实模式。群友 2026-11-15 那次「明明刚才还能连、
    ### 两分钟后就 permission denied」，事后无法从日志判断被杀成 700 还是别的值，
    ### 这条日志是唯一能回溯的证据，成本只有一次 stat。
    _old=$(docker exec -u 0 "$C" sh -c 'stat -c "%a %U:%G" /data/local/tmp/app_process /system/bin/app_process64 2>/dev/null | tr "\n" " "' 2>/dev/null | tr -d '\r\n')
    docker exec -u 0 "$C" sh -c '
        chmod 755 /data/local/tmp/app_process 2>/dev/null
        chown 2000:2000 /data/local/tmp/app_process 2>/dev/null
        chmod 755 /system/bin/app_process64 2>/dev/null' >/dev/null 2>&1 || true
    if exec_ok; then
        log "已纠正执行位：app_process 副本此前对 shell(2000) 不可执行（修复前：${_old:-未知}）"
        return 0
    fi
    log "纠正执行位失败：shell(2000) 仍无法执行 /system/bin/app_process64（修复前：${_old:-未知}）"
    return 1
}

host_target(){
    _src=$(docker inspect "$C" -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null | tr -d '\r\n')
    [ -n "$_src" ] || return 1
    printf '%s/local/tmp/app_process' "$_src"
}

ensure_cap(){
    [ "$(id -u)" = "0" ] || return 0
    if ! command -v setcap >/dev/null 2>&1; then
        log "宿主没有 setcap，跳过能力设置（投屏可能仍失败；升级/启用时会再试）"
        return 0
    fi
    _t=$(host_target) || { log "未取到 /data 的宿主路径，跳过 setcap"; return 0; }
    [ -f "$_t" ] || { log "副本尚未生成：$_t"; return 0; }
    if setcap cap_chown,cap_fowner,cap_dac_override,cap_dac_read_search+ep "$_t" 2>/dev/null; then
        log "能力已设置：$(getcap "$_t" 2>/dev/null)"
    else
        log "setcap 失败（$_t）"
    fi
}

ensure_mount(){
    mounted && return 0
    if docker exec -u 0 "$C" sh -c 'mount --bind /data/local/tmp/app_process /system/bin/app_process64' >/dev/null 2>&1; then
        log "已挂载：/system/bin/app_process64 ← /data/local/tmp/app_process"
        return 0
    fi
    log "挂载失败（运行环境需处于 running）"
    return 1
}

case "$ACTION" in
    --install)
        if ! running; then
            ### 首次安装时镜像可能还没就绪、容器尚未创建：只等 3 秒，交给
            ### 「启用」（cmd/main）与看护（--runtime）在容器起来后补做。
            log "容器未运行，等待 3 秒后再试一次"
            sleep 3
        fi
        if running; then
            ensure_copy; ensure_mode; ensure_cap; ensure_mount
        else
            log "容器仍未运行，跳过（启用/看护时会重试）"
        fi
        ;;
    --runtime)
        running || exit 0
        ### 注意：不能"已挂载就直接退出" —— 挂载只保证文件被覆盖（同一 inode），
        ### 若该 inode 的执行位丢了，挂载照样存在，但 shell 依然执行不了。
        if mounted && exec_ok; then exit 0; fi
        ensure_copy
        ensure_mode
        ensure_mount
        ;;
    --preflight)
        ### 只在 agent 启动前调用一次：容器不在就静默退出，可用就秒退。
        ### 目的：让「agent 起来的那一刻」app_process 一定可执行，而不是等
        ### 60 秒巡检或用户点「连接」失败之后才补。
        running || exit 0
        exec_ok && exit 0
        log "preflight：shell(2000) 无法执行 app_process64 → 立即修复"
        ensure_copy
        ensure_mode
        ensure_mount
        exec_ok && log "preflight：修复完成" || log "preflight：修复后仍不可执行"
        ;;
    --status)
        echo "容器运行: $(running && echo 是 || echo 否)"
        echo "副本存在: $(has_copy && echo 是 || echo 否)"
        echo "shell 可执行: $(exec_ok && echo 是 || echo 否)"
        echo "已挂载:   $(mounted && echo 是 || echo 否)"
        _t=$(host_target 2>/dev/null) && [ -n "${_t:-}" ] && echo "能力:     $(getcap "$_t" 2>/dev/null || echo 未知)"
        echo "日志:     $LOG"
        ;;
    *)
        echo "用法：$0 [--install|--runtime|--preflight|--status]"; exit 1 ;;
esac
exit 0
