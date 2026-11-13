package main

// 外部命令定位（3.9.9）
//
// 背景（实测 2026-11-13，x86 飞牛）：网关进程以包用户运行时，进程 PATH 不含 /usr/bin，
// Go 的 exec.Command("docker") 走 LookPath 直接失败 —— 容器明明在跑（docker ps 能查到
// androidemu-android / androidemu-webrtc），网关却拿到空结果，表现为：
//   · 状态页永远显示「正在安装中 / 暂无容器（首次安装正在拉取镜像）」
//   · /api/status 的 containers 为空、3478 UDP 误报「未监听」
//   · 三个「一键修复」动作全部静默失败、翻译层崩溃看护永远不触发
// 而 /stream.mjpg 用的是绝对路径 /usr/bin/docker，画面正常 —— 两者同时成立正是本缺陷特征。
//
// 处理：① 启动时把标准目录补进 PATH（不覆盖已有项）；② 所有外部命令统一走 bin()，
// 先按标准目录找绝对路径，再退回 LookPath；找不到就原样返回，交给调用方按失败处理。

import (
	"os"
	"os/exec"
	"path/filepath"
	"sync"
)

var stdBinDirs = []string{"/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"}

func init() {
	cur := os.Getenv("PATH")
	for _, d := range stdBinDirs {
		if !pathHasDir(cur, d) {
			if cur == "" {
				cur = d
			} else {
				cur += string(os.PathListSeparator) + d
			}
		}
	}
	os.Setenv("PATH", cur)
}

func pathHasDir(list, dir string) bool {
	for _, p := range filepath.SplitList(list) {
		if p == dir {
			return true
		}
	}
	return false
}

var (
	binMu    sync.Mutex
	binCache = map[string]string{}
)

// bin 返回外部命令的可执行绝对路径；找不到时原样返回 name。
func bin(name string) string {
	if name == "" || filepath.IsAbs(name) {
		return name
	}
	binMu.Lock()
	defer binMu.Unlock()
	if v, ok := binCache[name]; ok {
		return v
	}
	for _, d := range stdBinDirs {
		p := filepath.Join(d, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0111 != 0 {
			binCache[name] = p
			return p
		}
	}
	if p, err := exec.LookPath(name); err == nil {
		binCache[name] = p
		return p
	}
	binCache[name] = name
	return name
}
