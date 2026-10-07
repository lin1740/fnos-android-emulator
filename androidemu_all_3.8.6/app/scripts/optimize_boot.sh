#!/bin/bash
# 3.8.3 启动优化脚本：解决redroid 12启动慢、lmkd过于激进的问题
# 在容器启动后由gateway或install脚本调用一次

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

echo "[optimize_boot] 完成"
