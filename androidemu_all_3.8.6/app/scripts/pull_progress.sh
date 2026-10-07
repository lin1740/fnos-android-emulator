#!/bin/bash
### pull_progress.sh — 解析 docker pull --progress=plain 日志，
### 输出三个数值（空格分隔）：
###   PULL_PERCENT  DONE_BYTES  TOTAL_BYTES
### 无法解析进度时输出：-1 0 0
###
### 用法：pull_progress.sh <进度日志路径>

LOG="${1:-/tmp/androidemu-pull-progress.log}"

if [ ! -f "$LOG" ]; then
    echo "-1 0 0"
    exit 0
fi

awk '
  function parse(s,   n, u, mul) {
    n = s; sub(/[KMG]i?B$/, "", n)
    u = s; sub(/^[0-9.]+/, "", u)
    mul = 1
    if (u ~ /^[G]/) mul = 1073741824
    else if (u ~ /^[M]/) mul = 1048576
    else if (u ~ /^[K]/) mul = 1024
    return n * mul
  }
  /Downloading|Extracting/ {
    if (match($0, /[0-9.]+[KMG]?i?B\/[0-9.]+[KMG]?i?B/)) {
      pair = substr($0, RSTART, RLENGTH)
      split(pair, a, "/")
      done = parse(a[1]); total = parse(a[2])
      if (total > 0) last[$1] = done SUBSEP total
    }
  }
  END {
    D = 0; T = 0
    for (k in last) { split(last[k], v, SUBSEP); D += v[1]; T += v[2] }
    if (T > 0) {
      p = (D >= T) ? 100 : int(D * 100 / T)
      # 用 print 而非 printf %d：%d 在 busybox awk 下为 32 位整数，
      # 镜像总大小超过 2.147GB（2^31-1）时会溢出为负数，导致进度条
      # 不显示总大小与 ETA；print 使用双精度浮点，可完整输出大字节数。
      print p, D, T
    } else {
      printf "%d 0 0\n", -1
    }
  }
' "$LOG"
