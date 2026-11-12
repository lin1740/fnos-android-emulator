package main

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// dockerExec 在容器内执行命令
func dockerExec(container string, args ...string) (string, error) {
	fullArgs := append([]string{"exec", "-u", "0", container}, args...)
	cmd := exec.Command("docker", fullArgs...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// dockerInspect 获取容器状态
func dockerInspect(container, format string) (string, error) {
	cmd := exec.Command("docker", "inspect", "-f", format, container)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// checkAndroidContainer 检查安卓容器状态
func checkAndroidContainer() ContainerStatus {
	status := ContainerStatus{}
	running, err := dockerInspect(cfg.AndroidContainer, "{{.State.Running}}")
	if err != nil {
		status.Status = "not_found"
		return status
	}
	status.Running = running == "true"
	if status.Running {
		st, _ := dockerInspect(cfg.AndroidContainer, "{{.State.Status}}")
		status.Status = st
		mem, _ := dockerInspect(cfg.AndroidContainer, "{{.MemoryUsage}}")
		if mem == "" {
			mem = "0"
		}
		status.Memory = mem
	}
	return status
}

// checkWebrtcContainer 检查WebRTC容器状态
func checkWebrtcContainer() ContainerStatus {
	status := ContainerStatus{}
	running, err := dockerInspect(cfg.WebrtcContainer, "{{.State.Running}}")
	if err != nil {
		status.Status = "not_found"
		return status
	}
	status.Running = running == "true"
	if status.Running {
		st, _ := dockerInspect(cfg.WebrtcContainer, "{{.State.Status}}")
		status.Status = st
	}
	return status
}

// checkAgentProcess 检查agent进程
func checkAgentProcess() ProcessStatus {
	p := ProcessStatus{}
	out, err := dockerExec(cfg.AndroidContainer, "sh", "-c", "pidof cloudphone-agent 2>/dev/null | head -1")
	if err != nil || out == "" {
		return p
	}
	p.Running = true
	p.Pid = out
	return p
}

// checkBootCompleted 检查安卓是否启动完成
func checkBootCompleted() bool {
	out, err := dockerExec(cfg.AndroidContainer, "sh", "-c", "getprop sys.boot_completed 2>/dev/null")
	if err != nil {
		return false
	}
	return out == "1"
}

// checkSystemReady 检查系统核心服务是否就绪
func checkSystemReady() bool {
	out, err := dockerExec(cfg.AndroidContainer, "sh", "-c",
		"pidof surfaceflinger >/dev/null 2>&1 && pidof mediaserver >/dev/null 2>&1 && pidof adbd >/dev/null 2>&1 && echo ready")
	if err != nil {
		return false
	}
	return out == "ready"
}

// checkAudioService 检查音频服务
func checkAudioService() ServiceStatus {
	s := ServiceStatus{}
	out, err := dockerExec(cfg.AndroidContainer, "sh", "-c",
		"getprop debug.stagefright.ccodec 2>/dev/null")
	if err != nil {
		s.Message = "无法检查音频服务"
		return s
	}
	if out == "1" {
		s.Healthy = true
		s.Message = "Codec2已启用"
	} else {
		s.Healthy = false
		s.Message = "Codec2未启用，需要修复"
	}
	return s
}

// checkPortListening 检查端口是否在监听
func checkPortListening(port int) bool {
	cmd := exec.Command("sh", "-c", fmt.Sprintf("ss -lntp 2>/dev/null | grep -q ':%d '", port))
	return cmd.Run() == nil
}

// MonitorLoop 主监控循环
func MonitorLoop(ctx context.Context) {
	defer wg.Done()
	ticker := time.NewTicker(time.Duration(cfg.Interval) * time.Second)
	defer ticker.Stop()

	// 启动时立即检查一次
	monitorOnce()

	for {
		select {
		case <-ctx.Done():
			logger.Println("监控循环退出")
			return
		case <-ticker.C:
			monitorOnce()
		}
	}
}

func monitorOnce() {
	stateMux.Lock()
	defer stateMux.Unlock()

	// 检查容器状态
	state.AndroidContainer = checkAndroidContainer()
	state.WebrtcContainer = checkWebrtcContainer()

	// 安卓容器运行中才检查agent和音频
	if state.AndroidContainer.Running {
		state.AgentProcess = checkAgentProcess()
		state.AudioService = checkAudioService()

		// 自动恢复逻辑
		autoRecover()
	}

	state.Uptime = time.Now().Format("2006-01-02 15:04:05")
}
