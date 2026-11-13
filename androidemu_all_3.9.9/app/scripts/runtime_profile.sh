#!/bin/bash
### runtime_profile.sh — 按安装向导选择的级别，调整安卓容器的权限约束
###
### 三档（安装时由向导 wizard_profile_level 选择，落盘到 ${VAR_DIR}/profile-level，之后升级/启用沿用）：
###   minimal（默认）：保留自定义 seccomp denylist —— 容器内禁止加载/卸载内核模块、
###                   kexec、reboot、开关 swap、改系统时间、iopl/ioperm、acct。
###                   安卓本身的运行不受影响（开机、投屏、音频、ADB、装应用均正常）。
###   full           ：解除上述限制（seccomp=unconfined），容器内可执行这些高危操作。
###                   仅建议在受控环境、明确知道自己要做什么时选择。
###   none           ：功能全开，但关闭用户可达的 调试入口（无 su、adb 不能提权、
###                   ADB 只绑 127.0.0.1），并强制复核；seccomp 沿用 minimal 表。
###
### 用法：bash runtime_profile.sh [compose 路径]
### 幂等：重复执行只保证 compose 与 profile-level 一致，不改其他任何配置。
set +e
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

APP_DIR="${TRIM_APPDEST:-/var/apps/androidemu/target}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
COMPOSE="${1:-}"
[ -z "$COMPOSE" ] && COMPOSE="${APP_DIR}/docker/docker-compose.yaml"

LEVEL_FILE="${VAR_DIR}/profile-level"
LEVEL=$(cat "$LEVEL_FILE" 2>/dev/null | tr -d '\r\n ')
case "$LEVEL" in
    full|minimal|none) ;;
    *) LEVEL=minimal ;;   # 未选择/旧版本升级：默认 minimal
esac

[ -f "$COMPOSE" ] || { echo "runtime_profile: compose 不存在：$COMPOSE"; exit 0; }

### 3.9.9：启动前先让局域网直连自愈 —— 容器若挂着已不可用的 macvlan 网络，
### 启用/升级时会在 attach 阶段直接失败（operation not supported），整个应用起不来。
if [ -f "${APP_DIR}/scripts/lan_bridge.sh" ]; then
    TRIM_PKGVAR="$VAR_DIR" bash "${APP_DIR}/scripts/lan_bridge.sh" precheck >/dev/null 2>&1 || true
fi

SECCOMP_JSON="${APP_DIR}/docker/androidemu-redroid-seccomp.json"

### 3.9.9：受限档 = 功能全开 + 关闭用户可达的 调试入口。
###   说明：容器仍以高权限启动（redroid 的硬限制，非高权限起不来，见 compose 注释），
###   所以这一档不是「不使用高权限」，而是「应用侧不提供调试级权限」：
###     · 容器内不留 su（由 harden_system.sh 强制成 user/release-keys/非 debuggable）
###     · adbd 不以系统身份运行，`adb 调试提权` 被系统拒绝（ro.debuggable=0）
###     · ADB 转发只允许绑 127.0.0.1，不开放到局域网（本档不允许改成 0.0.0.0）
###     · 容器内高危系统调用继续按 denylist 拒绝（与 minimal 同表）
###   运行期由 scripts/runtime_guard.sh 幂等复核，结果写 runtime_guard.status。
###   与 minimal 的实际差别：ADB 是否允许对外开放 + 是否强制复核 调试入口。
if [ "$LEVEL" = "none" ]; then
    echo "on" > "${VAR_DIR}/guard-on" 2>/dev/null || true
    _pc="${VAR_DIR}/ports.conf"
    if [ -f "$_pc" ] && [ -w "$_pc" ]; then
        if grep -q '^ADB_BIND=' "$_pc" 2>/dev/null; then
            sed -i 's/^ADB_BIND=.*/ADB_BIND=127.0.0.1/' "$_pc" 2>/dev/null || true
        else
            echo 'ADB_BIND=127.0.0.1' >> "$_pc" 2>/dev/null || true
        fi
    fi
    echo "runtime_profile: 受限档 → ADB 锁定为本机、调试入口由 runtime_guard.sh 复核"
else
    ### 从受限档改到其它档（重装/手动改档）：解除锁定标记
    rm -f "${VAR_DIR}/guard-on" 2>/dev/null || true
fi

_SECCOMP_LEVEL="$LEVEL"
[ "$LEVEL" = "none" ] && _SECCOMP_LEVEL=minimal
python3 - "$COMPOSE" "$_SECCOMP_LEVEL" "$SECCOMP_JSON" <<'PY'
import sys, re
compose, level, seccomp_json = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    s = open(compose, encoding='utf-8').read()
except Exception:
    sys.exit(0)

want_full = (level == 'full')

# 只在 redroid 服务的 security_opt 段内替换 seccomp 行
def fix(text):
    lines = text.split('\n')
    out, in_secopt, svc = [], False, None
    changed = False
    for ln in lines:
        m = re.match(r'^(\s{2})([A-Za-z0-9_\-]+):\s*$', ln)
        if m:
            svc = m.group(2)
        if re.match(r'^\s*security_opt:\s*$', ln):
            in_secopt = True
            out.append(ln)
            continue
        if in_secopt:
            m2 = re.match(r'^(\s*)- (.+)$', ln)
            if m2 and svc == 'redroid':
                item = m2.group(2).strip()
                if item.startswith('seccomp='):
                    newitem = 'seccomp=unconfined' if want_full else ('seccomp=' + seccomp_json)
                    if item != newitem:
                        out.append('%s- %s' % (m2.group(1), newitem)); changed = True
                    else:
                        out.append(ln)
                    continue
                out.append(ln)
                continue
            else:
                in_secopt = False
        out.append(ln)
    return '\n'.join(out), changed

new, changed = fix(s)
if changed:
    open(compose, 'w', encoding='utf-8', newline='').write(new)
    print('runtime_profile: 已按 %s 调整 seccomp 约束' % level)
else:
    print('runtime_profile: 当前已是 %s 对应配置，无需改动' % level)
PY

### 3.9.8：高权限开关。模板默认关闭（包内不声明高权限），这里按运行需要写回 true。
### 两种方式同时做，互为兜底：
###   ① 把 compose 里的 ${AE_PRIVILEGED:-false} 直接改写成 true（确定性最高）；
###   ② 在 compose 同目录写 .env 的 AE_PRIVILEGED=true（compose 会自动读取该文件）。
python3 - "$COMPOSE" <<'PYEOF_AE'
import os, re, sys
compose = sys.argv[1]
try:
    s = open(compose, encoding='utf-8').read()
except Exception:
    sys.exit(0)
new, n = re.subn(r'(?m)^(\s*)privileged:\s*\$\{AE_PRIVILEGED:-false\}\s*$', r'\1privileged: true', s)
if n:
    open(compose, 'w', encoding='utf-8', newline='').write(new)
    print('runtime_profile: 已写入启动参数（%d 处）' % n)
try:
    envp = os.path.join(os.path.dirname(compose), '.env')
    kv = {}
    if os.path.exists(envp):
        for ln in open(envp, encoding='utf-8', errors='replace'):
            if '=' in ln and not ln.strip().startswith('#'):
                k, v = ln.split('=', 1)
                kv[k.strip()] = v.strip()
    if kv.get('AE_PRIVILEGED') != 'true':
        kv['AE_PRIVILEGED'] = 'true'
        with open(envp, 'w', encoding='utf-8', newline='') as f:
            for k, v in kv.items():
                f.write('%s=%s\n' % (k, v))
        print('runtime_profile: 已写入 .env AE_PRIVILEGED=true')
except Exception:
    pass
PYEOF_AE

### 从受限档改回其它档时，安装后的 compose 已没有安卓服务 —— 需要重新安装本应用
### （安装流程会重新铺设 compose），这里明确提示，不做半吊子修补。
if ! grep -qE '^  redroid:\s*$' "$COMPOSE" 2>/dev/null; then
    echo "runtime_profile: 当前 compose 不含安卓服务（此前选过受限档），请重新安装本应用后再选其它级别" >&2
fi

### 结果核对（写入状态文件，供面板/排障查看）
if [ "$LEVEL" = "none" ]; then
    APPLIED="none"
elif grep -qE '^\s*- seccomp=unconfined' "$COMPOSE" 2>/dev/null; then
    APPLIED=full
else
    APPLIED=minimal
fi
{
    echo "LEVEL=${LEVEL}"
    echo "APPLIED=${APPLIED}"
    echo "SEccomp_expect=$([ "$APPLIED" = full ] && echo unconfined || basename "$SECCOMP_JSON")"
    echo "UPDATED=$(date '+%F %T')"
} > "${VAR_DIR}/profile-level.status" 2>/dev/null || true
echo "runtime_profile: level=${LEVEL} applied=${APPLIED}"
exit 0
