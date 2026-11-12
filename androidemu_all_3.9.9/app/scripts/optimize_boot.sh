#!/bin/bash

set -e

CONTAINER="androidemu-android"

# 等待容器启动
echo "[optimize_boot] 等待容器启动..."
for i in $(seq 1 60); do
    if docker exec "$CONTAINER" getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
        echo "[optimize_boot] 安卓启动完成"
        break
    fi
    sleep 2
done

# 1. 调高lmkd阈值（原阈值最高仅315MB，对大内存系统过于激进）
# 格式: minfree_pages:oom_adj_score，1页=4KB
# 新阈值: 512MB,768MB,1024MB,1280MB,2048MB,3072MB
echo "[optimize_boot] 调高lmkd阈值..."
docker exec "$CONTAINER" setprop sys.lmk.minfree_levels "131072:0,196608:100,262144:200,327680:250,524288:900,786432:950" 2>/dev/null || true

# 2. 提升system_server和surfaceflinger优先级
echo "[optimize_boot] 提升关键进程优先级..."
docker exec "$CONTAINER" sh -c 'for pid in $(pidof system_server surfaceflinger); do echo -10 > /proc/$pid/oom_score_adj 2>/dev/null; done' 2>/dev/null || true

# 3. 禁用dex2oat后台编译（减少启动时CPU/IO压力）
echo "[optimize_boot] 优化dex2oat..."
docker exec "$CONTAINER" setprop pm.dexopt.boot verify 2>/dev/null || true
docker exec "$CONTAINER" setprop pm.dexopt.first-boot verify 2>/dev/null || true

# 4. 3.9.0：画面流畅度微调（SurfaceFlinger，均为上游 AOSP 支持的调试开关）
#   · latch_unsignaled=1：不等 vsync 信号就锁存新帧，降低一帧合成延迟（画面跟手）
#   · enable_gl_backpressure=1：GPU 渲染积压时主动背压，减少掉帧与卡顿尖峰
#   注意：debug.* 属性由 SurfaceFlinger 在**启动时**读取，运行中设置必须重启一次合成服务
#   才生效（实测：重启后 SF PID 变化、系统与画面均正常）。已生效时不做任何动作，
#   避免每次开机多一次无谓重启。
echo "[optimize_boot] 应用画面流畅度参数..."
_cur_latch=$(docker exec "$CONTAINER" getprop debug.sf.latch_unsignaled 2>/dev/null | tr -d '\r')
_cur_bp=$(docker exec "$CONTAINER" getprop debug.sf.enable_gl_backpressure 2>/dev/null | tr -d '\r')
if [ "$_cur_latch" != "1" ] || [ "$_cur_bp" != "1" ]; then
    docker exec "$CONTAINER" setprop debug.sf.latch_unsignaled 1 2>/dev/null || true
    docker exec "$CONTAINER" setprop debug.sf.enable_gl_backpressure 1 2>/dev/null || true
    docker exec "$CONTAINER" setprop ctl.restart surfaceflinger 2>/dev/null || true
    echo "[optimize_boot] 已设置并重启 SurfaceFlinger 使其生效"
else
    echo "[optimize_boot] 画面参数已生效，跳过"
fi

echo "[optimize_boot] 完成"
