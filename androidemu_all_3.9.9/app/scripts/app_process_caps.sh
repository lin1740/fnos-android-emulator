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
### 用法：app_process_caps.sh [--install|--runtime|--status]
###   --install  安装/升级回调、启用（系统身份）用：复制 + 校正执行位 + setcap + mount
###   --runtime  看护（包用户）用：缺副本则复制、执行位不对则纠正、缺 mount 则挂载；
###              cap 缺失只记录告警（包用户设不了 cap，需系统身份时机补）
###   --status   打印当前状态（含「shell 可执行」一项）
### 退出码恒为 0（失败不阻断安装/启动，后续巡检会重试）。
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
exec_ok(){ docker exec -u 2000 "$C" sh -c 'test -x /system/bin/app_process64' >/dev/null 2>&1; }

ensure_copy(){
    if has_copy && exec_ok; then return 0; fi
    ### 已经挂载时源与目标是同一个 inode，此时 cp 等于"自己覆盖自己"，必须交给
    ### ensure_mode 修执行位（2026-11-10 实测场景：挂载在、副本却是 700）。
    if has_copy && mounted; then return 0; fi
    ### 副本缺失、为空、或不可执行时才重取；cp 后显式校正模式，
    ### 避免"cp 用了更严格的 umask（容器内 077 时会直接生成 700）"。
    docker exec -u 0 "$C" sh -c '
        cp -f /system/bin/app_process64 /data/local/tmp/app_process 2>/dev/null
        chmod 755 /data/local/tmp/app_process 2>/dev/null' >/dev/null 2>&1
    if has_copy; then
        log "已复制 app_process64 → /data/local/tmp/app_process（并校正为 755）"
        return 0
    fi
    log "复制 app_process64 失败"
    return 1
}

### 只校正执行位，不动属主 —— chmod 不会清除 security.capability（chown 会）。
ensure_mode(){
    exec_ok && return 0
    docker exec -u 0 "$C" sh -c '
        chmod 755 /data/local/tmp/app_process 2>/dev/null
        chmod 755 /system/bin/app_process64 2>/dev/null' >/dev/null 2>&1 || true
    if exec_ok; then
        log "已纠正执行位：app_process 副本此前对 shell(2000) 不可执行（模式非 755）"
        return 0
    fi
    log "纠正执行位失败：shell(2000) 仍无法执行 /system/bin/app_process64"
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
    --status)
        echo "容器运行: $(running && echo 是 || echo 否)"
        echo "副本存在: $(has_copy && echo 是 || echo 否)"
        echo "shell 可执行: $(exec_ok && echo 是 || echo 否)"
        echo "已挂载:   $(mounted && echo 是 || echo 否)"
        _t=$(host_target 2>/dev/null) && [ -n "${_t:-}" ] && echo "能力:     $(getcap "$_t" 2>/dev/null || echo 未知)"
        echo "日志:     $LOG"
        ;;
    *)
        echo "用法：$0 [--install|--runtime|--status]"; exit 1 ;;
esac
exit 0
