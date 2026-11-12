#!/bin/bash
### app_desktop_sync.sh — 把已安装的第三方应用自动补到桌面（3.9.2 新增）
###
### 解决的问题：AOSP Launcher3 对 `pm install` / 面板推送安装的应用不会自动在桌面
### 创建图标（只进抽屉），国内用户预期「装完就在桌面」。本脚本把缺失的第三方应用
### 图标补进 Launcher3 工作区（favorites 表，iconType=0 应用项，4x4 网格自动找空位）。
###
### 原理：force-stop 启动器 → 取最新的 launcher_*.db → python3 对比已装 -3 包与
###       favorites 组件 → 插入缺失行 → 推回并修正属主 → 重启启动器加载。
### 幂等：已在桌面的应用跳过；无缺失时静默退出（零打扰，不动数据库）。
### 触发：boot_guard 巡检（轻量检查，仅在有缺失时才动数据库）。
### 安全：只操作本应用容器的 Launcher3 数据库；只添加应用图标，不改任何现有布局。
set -u
C="${CNAME:-androidemu-android}"
VAR_DIR="${TRIM_PKGVAR:-/var/apps/androidemu/var}"
WORK=/tmp/ae_dsync.$$
mkdir -p "$VAR_DIR" 2>/dev/null || true

### 3.9.2 热修：锁/日志可能是早期以 系统身份跑的安装流程创建的（0:0 644），
### 之后以普通用户 docker-androidemu 运行的开机巡检打不开写入 → exec 9> 失败 →
### flock 报 Bad file descriptor → 整段脚本静默退出（实测补过 22 个图标后再也不动作，
### 用户装完应用桌面一直不出图标）。现改为：不可写就退到可写临时目录，仍失败则无锁执行。
_ae_wpath(){ # $1=文件名，输出一个可写的路径
    local n="$1" fb="${TMPDIR:-/tmp}/androidemu_$(id -u)"
    if [ -d "$VAR_DIR" ] && [ -w "$VAR_DIR" ] && { [ ! -e "$VAR_DIR/$n" ] || [ -w "$VAR_DIR/$n" ]; }; then
        printf '%s\n' "$VAR_DIR/$n"
    else
        mkdir -p "$fb" 2>/dev/null
        printf '%s\n' "$fb/$n"
    fi
}
LOG=$(_ae_wpath app_desktop.log)
LOCKF=$(_ae_wpath .app_desktop.lock)
log(){ echo "[$(date '+%F %T')] app_desktop: $*" >> "$LOG" 2>/dev/null; }

# 并发锁：两次巡检重叠时直接让位（单轮 <5s，正常不触发）；锁不可用则退化为无锁
if exec 9>"$LOCKF" 2>/dev/null; then
    flock -n 9 2>/dev/null || exit 0
fi

[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ] || exit 0

N3=$(docker exec "$C" sh -c 'pm list packages -3 2>/dev/null' 2>/dev/null | wc -l)
[ "$N3" -gt 0 ] 2>/dev/null || exit 0

DB_IN=$(docker exec "$C" sh -c 'ls -t /data/data/com.android.launcher3/databases/launcher_*.db 2>/dev/null' 2>/dev/null | head -1)
[ -n "$DB_IN" ] || exit 0

mkdir -p "$WORK"
docker exec "$C" am force-stop com.android.launcher3 >/dev/null 2>&1
sleep 1
docker cp "$C:$DB_IN" "$WORK/l.db" >/dev/null 2>&1 || { log "取数据库失败：$DB_IN"; rm -rf "$WORK"; exit 0; }
OWNER=$(docker exec "$C" stat -c '%u:%g' "$DB_IN" 2>/dev/null)

python3 - "$WORK/l.db" "$WORK" "$(basename "$DB_IN")" <<'PYEOF' >> "$LOG" 2>&1
import sqlite3, sys, subprocess, re, os

db_path, work = sys.argv[1], sys.argv[2]
db_name = sys.argv[3] if len(sys.argv) > 3 else ''
m = re.search(r'launcher_(\d+)x', db_name)
GRID = int(m.group(1)) if m else 4
pkg = 'androidemu-android'

def sh(cmd):
    r = subprocess.run(['docker', 'exec', '-i', '-u', '0', pkg, 'sh', '-c', cmd],
                       capture_output=True, timeout=60)
    return r.stdout.decode('utf-8', 'replace')

pkgs = [l.replace('package:', '').strip() for l in sh('pm list packages -3').splitlines() if l.strip()]

entries = []
for p in pkgs:
    act = sh(f'cmd package resolve-activity --brief -c android.intent.category.LAUNCHER {p}')
    act = [l for l in act.splitlines() if l.strip()]
    comp = act[-1].strip() if act else ''
    if '/' in comp:
        entries.append((p, comp))
entries.sort()

db = sqlite3.connect(db_path)
existing = set()
occupied = {}
max_screen = 0
for (_id, screen, container, cellX, cellY, intent) in db.execute(
        'select _id, screen, container, cellX, cellY, intent from favorites'):
    if container == -100 and screen is not None:
        occupied.setdefault(screen, set()).add((cellX, cellY))
        max_screen = max(max_screen, screen)
    if intent:
        m = re.search(r'component=([\w.]+)/', intent)
        if m:
            existing.add(m.group(1))

missing = [(p, c) for (p, c) in entries if p not in existing]
if not missing:
    sys.exit(0)

INSERTED = []
def free_cell():
    for s in range(0, max_screen + 2):
        occ = set(occupied.get(s, set()))
        # 第 0 屏第 0 行是启动器自绑的 Google 搜索条（QSB，不在 favorites 表），
        # 放进去会被 LoaderCursor 判"already occupied"丢弃 —— 预留给它。
        if s == 0:
            for x in range(GRID):
                occ.add((x, 0))
        for y in range(GRID):
            for x in range(GRID):
                if (x, y) not in occ:
                    return s, x, y
    return None

for (p, comp) in missing:
    cell = free_cell()
    if not cell:
        print('desktop: 网格已满，剩余 %d 个应用未上桌面' % (len(missing) - len(INSERTED)))
        break
    s, x, y = cell
    intent = ('#Intent;action=android.intent.action.MAIN;'
              'category=android.intent.category.LAUNCHER;'
              'launchFlags=0x10200000;package=%s;component=%s;end' % (p, comp))
    nid = db.execute('select coalesce(max(_id),0)+1 from favorites').fetchone()[0]
    db.execute('insert into favorites (_id,title,intent,container,screen,cellX,cellY,'
               'spanX,spanY,itemType,appWidgetId,iconPackage,iconResource,appWidgetProvider,'
               'modified,restored,profileId,rank,options,appWidgetSource) '
               'values (?,?,?,?,?,?,?,1,1,0,-1,null,null,null,0,0,0,0,0,-1)',
               (nid, p, intent, -100, s, x, y))
    occupied.setdefault(s, set()).add((x, y))
    INSERTED.append('%s@%d(%d,%d)' % (p, s, x, y))

db.commit()
db.close()
if INSERTED:
    open(os.path.join(work, 'changed'), 'w').write(' '.join(INSERTED))
    print('desktop: 已补 %d 个桌面图标：%s' % (len(INSERTED), ' '.join(INSERTED)))
PYEOF

if [ -f "$WORK/changed" ]; then
  docker cp "$WORK/l.db" "$C:$DB_IN" >/dev/null 2>&1 || { log "推回数据库失败"; rm -rf "$WORK"; exit 0; }
  [ -n "$OWNER" ] && docker exec -u 0 "$C" chown "$OWNER" "$DB_IN" >/dev/null 2>&1
  docker exec "$C" rm -f "$DB_IN-journal" >/dev/null 2>&1
  docker exec "$C" am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
  log "桌面图标同步完成（$(cat "$WORK/changed")，数据库 $DB_IN）"
fi
rm -rf "$WORK"
exit 0
