#!/bin/bash
### fix_gpu_perms.sh — 容器启动后，自动放开容器内 /dev/dri 权限并重启渲染服务。
###
### 背景：redroid 镜像没有 /bin/sh，无法在 entrypoint 里执行 chmod；
###       宿主侧 chmod 在部分机器上会被 udev / 设备节点重置，导致容器内
###       surfaceflinger 打开 /dev/dri 时 Permission denied、系统 boot 无法完成。
###       因此需在容器启动后，经 docker exec（root）在容器内再 chmod 一次并
###       重启 surfaceflinger。仅 GPU 直通（/dev/dri 存在）时有效，软件渲染自动跳过。
###
### 幂等：容器未运行 / 容器内无 /dev/dri 时直接退出，无副作用。

C="${CNAME:-androidemu-android}"

### 宿主无 GPU 直通条件（无 /dev/dri）时直接跳过（软件渲染不需要）
[ -e /dev/dri ] || exit 0

### 等待容器进入运行态（最多 30 秒）
for _i in $(seq 1 30); do
    state=$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)
    [ "$state" = "true" ] && break
    sleep 1
done

### 给系统初始化留出时间
sleep 5

### 容器内没有 /dev/dri（说明已回退软件渲染）则跳过
docker exec -u 0 "$C" test -e /dev/dri 2>/dev/null || exit 0

### 放开容器内 DRM 设备权限。
### 竞态说明：容器刚进入 Running 时，容器内的 /dev/dri 设备节点可能尚未就绪，
### 一次性 chmod 会因「文件不存在」失败（被 || true 静默吞掉）后不再重试，
### 导致 surfaceflinger 仍打不开 /dev/dri、boot 永远无法完成。
### 因此改为轮询重试：最多 120 秒，直到 chmod 成功为止。
chmod_ok=0
for _i in $(seq 1 60); do
    if docker exec -u 0 "$C" chmod 666 /dev/dri/card0 /dev/dri/renderD128 2>/dev/null; then
        chmod_ok=1
        break
    fi
    sleep 2
done
[ "$chmod_ok" = "1" ] || exit 0

### 给 init 一点时间，避免在 surfaceflinger 尚未被 init 拉起时 restart 无效
sleep 3

### 权限放开后重启渲染服务（此前因 EGL 权限失败无法启动，重启后即可完成 boot）
docker exec -u 0 "$C" sh -c 'setprop ctl.restart surfaceflinger' 2>/dev/null || true

exit 0
