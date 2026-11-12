#!/bin/bash
### 3.9.1：产品身份伪装（去除 redroid 标识，对外呈现为 Redmi Note 11 / Android 12）
### 原理：Android 12 的产品属性来自各分区 build.prop 的 ro.product.<分区>.* 形式，
### ro.product.brand 等为 init 运行时合成值；ro.build.fingerprint 由
### brand/name/device/version/id/incremental/type/tags 合成，故必须整套替换。
### 【3.9.1 修订】安全策略：先写入 props.new 临时目录，全部校验通过后才原子切换；
### 任一步失败则放弃（保留原有 props 与 compose 挂载），绝不让 compose 出现指向
### 不存在文件的挂载行——那会导致「应用中心启用失败：compose 或 container 异常」。
set +e
V=${TRIM_PKGVAR:-/var/apps/androidemu/var}
### 3.9.7：路径自愈 —— 默认值原来少了 /target，导致找不到 compose，Python 注入
### 静默退出（sys.exit(0)），props 文件生成了但挂载行永远不写进去，容器内 brand
### 一直是 redroid（实测）。这里按候选顺序探测真实 compose，保证注入一定落到生效文件。
A_PKG=${TRIM_PKGAPPDIR:-/var/apps/androidemu/target}
if [ ! -f "$A_PKG/docker/docker-compose.yaml" ]; then
    for _cand in /var/apps/androidemu/target /vol1/@appcenter/androidemu; do
        if [ -f "$_cand/docker/docker-compose.yaml" ]; then
            A_PKG="$_cand"
            break
        fi
    done
fi
IMG=$(grep -m1 '^[[:space:]]*image:' "$A_PKG/docker/docker-compose.yaml" 2>/dev/null | awk '{print $2}')
[ -z "$IMG" ] && IMG=docker.fnnas.com/redroid/redroid:12.0.0-latest
FP="Xiaomi/veux/veux:12/SKQ1.211103.001/V13.0.5.0.SKCMIXM:user/release-keys"
DESC="veux-user 12 SKQ1.211103.001 V13.0.5.0.SKCMIXM release-keys"
FILES="/system/build.prop /system/product/etc/build.prop /system/system_ext/etc/build.prop /vendor/build.prop /vendor/odm/etc/build.prop /vendor/odm_dlkm/etc/build.prop /vendor/vendor_dlkm/etc/build.prop"

# 0) 快速路径：props 已完整且 compose 已有挂载 → 直接返回（避免每次执行 docker create）
_need=0
for F in $FILES; do
    [ -s "$V/props$F" ] || { _need=1; break; }
done
### 3.9.7：快速路径原来只判「props 文件存在 + compose 有挂载行」，老版本生成的 props
### 里 ro.hardware 仍是 redroid、也没有 HAL 兼容库，会永远停留在旧伪装级别（实测）。
### 这里加两项版本特征校验，不满足就强制重建一次；两项都满足才真正跳过。
if [ "$_need" = "0" ]; then
    grep -q '^ro\.hardware=veux' "$V/props/vendor/build.prop" 2>/dev/null || _need=1
    [ -s "$V/props/hw/hwcomposer.veux.so" ] || _need=1
fi
### 3.9.9-r4：快速路径再校验「各分区 build.tags/type 是否仍残留 调试特征」。
### 背景（2026-11-11 实测）：旧版只替换了 ro.build.tags / ro.build.type，7 个分区
### build.prop 里的 ro.system/vendor/product/odm/system_ext/odm_dlkm/vendor_dlkm
### .build.tags 仍是 test-keys、.build.type 仍是 userdebug，getprop 可读，
### Momo / 金融类自研检测会据此判「环境被修改」。残留时强制重建一次 props。
if [ "$_need" = "0" ]; then
    for _f in $FILES; do
        grep -qE 'test-keys|userdebug' "$V/props$_f" 2>/dev/null && { _need=1; break; }
    done
fi
if [ "$_need" = "0" ] && grep -q "/props.*build.prop" "$A_PKG/docker/docker-compose.yaml" 2>/dev/null; then
    echo "apply_rebrand: 已就绪，跳过"
    exit 0
fi

# 1) 探测容器：失败直接放弃，不触碰任何现有配置
docker rm -f ae_propchk >/dev/null 2>&1
if ! docker create --name ae_propchk "$IMG" >/dev/null 2>&1; then
    echo "apply_rebrand: 跳过（无法基于镜像 $IMG 创建探测容器）"
    exit 0
fi

# 2) 写入临时目录
NEW="$V/props.new"
rm -rf "$NEW"
OKN=0

### 3.9.7：预取 HAL 兼容库 —— 这是改 ro.hardware 的前提。
### redroid 的图形 HAL 按硬件名命名（gralloc.<hw>.so / hwcomposer.<hw>.so），
### hw_get_module 用 ro.hardware 拼文件名去找。实测容器内只有
### gralloc.redroid.so 与 hwcomposer.redroid.so，且**没有** hwcomposer.default.so 兜底。
### 因此直接把 ro.hardware 改成 veux 会让 hwcomposer.veux.so 找不到 →
### SurfaceFlinger 起不来 → 画面黑屏。这里先把两个库复制成 veux 命名，
### 随 props 一起挂载进 /vendor/lib64/hw，改 ro.hardware 才有意义。
### 任一复制失败则 HW_OK=1：本次不改 ro.hardware，保持现状（绝不冒黑屏风险）。
HW_OK=0
mkdir -p "$NEW/hw" 2>/dev/null
for _pair in "gralloc.redroid.so:gralloc.veux.so" "hwcomposer.redroid.so:hwcomposer.veux.so"; do
    _hw_src=${_pair%%:*}
    _hw_dst=${_pair##*:}
    if docker cp "ae_propchk:/vendor/lib64/hw/${_hw_src}" "$NEW/hw/${_hw_dst}" >/dev/null 2>&1 && [ -s "$NEW/hw/${_hw_dst}" ]; then
        chmod 644 "$NEW/hw/${_hw_dst}" 2>/dev/null || true
    else
        HW_OK=1
    fi
done
if [ "$HW_OK" = "1" ]; then
    rm -rf "$NEW/hw" 2>/dev/null || true
fi
for F in $FILES; do
    DEST="$NEW$F"
    mkdir -p "$(dirname "$DEST")" 2>/dev/null
    docker cp ae_propchk:$F "$DEST" 2>/dev/null || continue
    [ -s "$DEST" ] || continue
    ### 3.9.7：身份收尾 —— flavor / product 与属性文件注释里仍带 redroid_x86_64，
    ### App 读 Build.FLAVOR / Build.PRODUCT 会直接拿到，文件注释也是静态证据。
    ### 先替换含 -userdebug 的长串（否则会先被短串截断成 veux-userdebug），再替换短串。
    _ID_SED=(
        -e 's#redroid_x86_64-userdebug#veux-user#g'
        -e 's#redroid_x86_64#veux#g'
        -e 's#device/redroid/redroid\.prop#device/xiaomi/veux/veux.prop#g'
    )
    ### 3.9.7：ro.hardware —— 仅当 HAL 兼容库已就绪才改，否则保持原值。
    if [ "$HW_OK" = "0" ]; then
        _ID_SED+=(-e 's#^ro\.hardware=.*#ro.hardware=veux#')
    fi
    sed -i -E "${_ID_SED[@]}" \
     -e 's#^(ro\.product\.[a-z_]+\.)brand=.*#\1brand=Redmi#' \
     -e 's#^(ro\.product\.[a-z_]+\.)manufacturer=.*#\1manufacturer=Xiaomi#' \
     -e 's#^(ro\.product\.[a-z_]+\.)model=.*#\1model=2201117TG#' \
     -e 's#^(ro\.product\.[a-z_]+\.)name=.*#\1name=veux#' \
     -e 's#^(ro\.product\.[a-z_]+\.)device=.*#\1device=veux#' \
     -e "s#^(ro\.(product|system|vendor|odm|system_ext|vendor_dlkm|odm_dlkm)\.build\.fingerprint)=.*#\1=$FP#" \
     -e 's#^ro\.build\.id=.*#ro.build.id=SKQ1.211103.001#' \
     -e 's#^ro\.build\.version\.incremental=.*#ro.build.version.incremental=V13.0.5.0.SKCMIXM#' \
     -e "s#^ro\.build\.description=.*#ro.build.description=$DESC#" \
     -e 's#^ro\.build\.tags=.*#ro.build.tags=release-keys#' \
     -e 's#^ro\.build\.type=.*#ro.build.type=user#' \
     -e 's#^(ro\.(product|system|vendor|odm|system_ext|vendor_dlkm|odm_dlkm)\.build\.tags)=.*#\1=release-keys#' \
     -e 's#^(ro\.(product|system|vendor|odm|system_ext|vendor_dlkm|odm_dlkm)\.build\.type)=.*#\1=user#' \
     -e 's#^ro\.debuggable=.*#ro.debuggable=0#' \
     -e 's#^ro\.build\.host=.*#ro.build.host=miui-build#' \
     -e 's#^ro\.build\.user=.*#ro.build.user=builder#' \
     -e 's#^ro\.build\.display\.id=.*#ro.build.display.id=V13.0.5.0.SKCMIXM#' \
     "$DEST"
    ### 3.9.7：props 文件权限统一 644。实测部分分区 build.prop 落成 600（仅属主可读），
    ### 容器内以普通 uid 挂载读取时可能拿不到属性，伪装就白做了。这里只放宽文件本身的
    ### 读权限，不修改任何进程的运行身份，也不改动运行环境的启动配置。
    chmod 644 "$DEST" 2>/dev/null || true
    ### 3.9.2：把 ro.debuggable 一并改成 0。原先只改 type/tags，漏了 debuggable ——
    ### 而 环境检测类工具第一看的就是它；且容器 /system 是只读的（实测报
    ### "Read-only file system"），只能在身份伪装的挂载文件里改。
    if ! grep -q '^ro\.debuggable=' "$DEST" 2>/dev/null; then
        echo 'ro.debuggable=0' >> "$DEST" 2>/dev/null || true
    fi
    ### 3.9.2：补「启动链可信」相关属性 —— 环境检测类工具（Momo、RootBeer、银行类 App）
    ### 除了 debuggable 还会看引导状态；这几个缺失时直接判「Bootloader 已解锁 / 系统被修改」。
    ### 逐条 append-if-missing：已有该键（例如内核命令行已注入）则不覆盖，避免与 ro 写一次语义打架。
    for _kv in \
        'ro.boot.verifiedbootstate=green' \
        'ro.boot.flash.locked=1' \
        'ro.boot.veritymode=enforcing' \
        'ro.boot.warranty_bit=0' \
        'ro.secure=1' \
        'ro.adb.secure=1' \
        'ro.hw_timeout_multiplier=5' \
        'ro.build.selinux=0'; do
        _k=${_kv%%=*}
        grep -q "^${_k}=" "$DEST" 2>/dev/null || echo "$_kv" >> "$DEST" 2>/dev/null || true
    done

    ### 3.9.2：让 Android 的 LMK 不再以「宿主 swap 剩余量」为依据。
    ### 实测背景：redroid 容器内 /proc/swaps 读到的就是宿主那一份；宿主机上跑着
    ### fnOS 自带虚拟机（qemu-system-aarch64，实测占 3.0G swap），4G swap 只剩 8MB。
    ### lmkd 看到「swap 仅剩 8MB」就判定内存严重不足，对已装应用无差别回收
    ### （美团/京东起完就消失）。而容器自身实测只用 1.0G / 5.0G 限额，根本不存在
    ### 真实内存压力 —— 属误杀。这里把 swap 判定阈值调到不再触发：
    ###   swap_util_max=100            swap 用量到 100% 才算高（原默认 80%）
    ###   swap_free_low_percentage=0   不再以「swap 空闲过低」作为低内存判据
    ### 真实内存不足时仍由 cgroup 限额（5G）与内核回收兜底，行为不变、可回退。
    _lmk_set() {
        _lk="$1"; _lv="$2"
        if grep -q "^${_lk}=" "$DEST" 2>/dev/null; then
            sed -i "s|^${_lk}=.*|${_lk}=${_lv}|" "$DEST" 2>/dev/null || true
        else
            echo "${_lk}=${_lv}" >> "$DEST" 2>/dev/null || true
        fi
    }
    _lmk_set ro.lmk.swap_util_max 100
    _lmk_set ro.lmk.swap_free_low_percentage 0
    # 校验：必须含 brand 且体积合理，否则视为无效
    if [ "$(stat -c%s "$DEST" 2>/dev/null || echo 0)" -gt 400 ] && grep -q '^ro\.product\.' "$DEST" 2>/dev/null; then
        OKN=$((OKN + 1))
    else
        rm -f "$DEST"
    fi
done
docker rm -f ae_propchk >/dev/null 2>&1

# 3) 至少要 3 个分区有效才认为整体可用（system/vendor + 至少一个其它）
if [ "$OKN" -lt 3 ]; then
    rm -rf "$NEW"
    echo "apply_rebrand: 放弃（仅 $OKN 个分区文件有效，保持原配置不变）"
    exit 0
fi

# 4) 原子切换 + 注入挂载（只注入真实存在且合格的文件）
# 3.9.4：原写法是「先 rm -rf 再 mv」。实测当 props 下存在系统属主的历史文件时，
#   rm 会报 Permission denied（父目录属于应用用户、但更深层目录属于系统账号，无权删除其内容），
#   目录仍在，紧接着的 mv 就把 props.new 整个塞进 props/props.new —— 既没完成切换，
#   又在应用数据目录里留下嵌套垃圾，日志里只有一行 Permission denied，很难看出发生了什么。
#   现在分三级：正常删除并切换 → 删不掉就逐文件覆盖 → 仍失败则明确放弃并清理临时目录。
if [ -e "$V/props" ]; then
    rm -rf "$V/props" 2>/dev/null || true
fi
if [ -e "$V/props" ]; then
    echo "apply_rebrand: 旧 props 目录未能整体删除（权限不足），改为逐文件覆盖"
    _cp_fail=0
    for F in $FILES; do
        [ -s "$NEW$F" ] || continue
        mkdir -p "$(dirname "$V/props$F")" 2>/dev/null
        if ! cp -f "$NEW$F" "$V/props$F" 2>/dev/null; then
            _cp_fail=1
            echo "apply_rebrand: 覆盖失败 $F"
        fi
    done
    if [ "$_cp_fail" = "1" ]; then
        echo "apply_rebrand: 逐文件覆盖仍有失败 → 放弃切换，保持原配置不变（可执行 sudo chown -R docker-androidemu:AppUsers $V/props 后重试）"
        rm -rf "$NEW" 2>/dev/null || true
        exit 0
    fi
    rm -rf "$NEW" 2>/dev/null || true
else
    mv "$NEW" "$V/props"
fi
python3 - "$A_PKG/docker/docker-compose.yaml" "$V" "$FILES" <<'PY'
import io, os, sys
cmp, V, files = sys.argv[1], sys.argv[2], sys.argv[3].split()
if not os.path.isfile(cmp):
    sys.exit(0)
lines = io.open(cmp, encoding="utf-8").read().split("\n")
lines = [l for l in lines if "/props" not in l]
ins = None
for i, l in enumerate(lines):
    if l.strip() == "volumes:":
        ins = i + 1; break
if ins is None:
    sys.exit(0)
add = []
for f in files:
    p = "%s/props%s" % (V, f)
    # 硬性校验：必须是普通文件且体积合理，否则绝不写入挂载（否则 compose 必挂）
    if os.path.isfile(p) and os.path.getsize(p) > 400:
        add.append("      - %s:%s:ro" % (p, f))
    else:
        print("apply_rebrand: 跳过无效文件 %s" % f)
# 3.9.7：HAL 兼容库（ro.hardware=veux 时 hw_get_module 需要这两个文件）
for _n, _t in (("gralloc.veux.so", "/vendor/lib64/hw/gralloc.veux.so"),
               ("hwcomposer.veux.so", "/vendor/lib64/hw/hwcomposer.veux.so")):
    # 注意：路径必须是 V/props/hw —— props 目录才是挂载源根，少一层就永远挂不上
    # （实测第一版写成 V/hw，库复制成功但 compose 没注入，而 ro.hardware 已改成 veux，
    #   此时容器一重启就会因找不到 hwcomposer.veux.so 黑屏）
    _p = os.path.join(V, "props", "hw", _n)
    if os.path.isfile(_p) and os.path.getsize(_p) > 1000:
        add.append("      - %s:%s:ro" % (_p, _t))
    else:
        print("apply_rebrand: 跳过 HAL 库 %s" % _n)
if add:
    for a in reversed(add):
        lines.insert(ins, a)
    io.open(cmp, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
print("apply_rebrand: compose 挂载已注入 %d 条" % len(add))
PY
echo "apply_rebrand: 完成（$OKN 个分区属性文件生效）"
