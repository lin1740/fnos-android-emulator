package main

import (
	"fmt"
	"os"
	"os/exec"
	"time"
)

var lastRecoverTime time.Time

// autoRecover 自动恢复异常服务
func autoRecover() {
	now := time.Now()

	// 冷却时间：距离上次恢复不足60秒不执行恢复，避免循环重启
	if !lastRecoverTime.IsZero() && now.Sub(lastRecoverTime) < 60*time.Second {
		return
	}

	// 1. WebRTC容器不在运行 → 重建
	if !state.WebrtcContainer.Running {
		logger.Println("WebRTC容器未运行，尝试重建...")
		if recoverWebrtc() {
			lastRecoverTime = now
			state.LastRecover = fmt.Sprintf("%s 重建WebRTC容器", now.Format("15:04:05"))
		}
		return
	}

	// 2. 安卓容器运行中但agent不在运行 → 重新部署agent
	if state.AndroidContainer.Running && !state.AgentProcess.Running {
		// 检查是否在稳定期内
		if inStablePeriod() {
			logger.Println("agent未运行但在稳定期内，跳过恢复")
			return
		}
		// 检查boot_completed和系统就绪
		if !checkBootCompleted() {
			logger.Println("安卓未boot_completed，跳过agent恢复")
			return
		}
		if !checkSystemReady() {
			logger.Println("系统核心服务未就绪，跳过agent恢复")
			return
		}
		logger.Println("agent未运行，重新部署...")
		if recoverAgent() {
			lastRecoverTime = now
			state.LastRecover = fmt.Sprintf("%s 重新部署agent", now.Format("15:04:05"))
		}
		return
	}

	// 3. 音频服务不健康 → 修复
	if !state.AudioService.Healthy {
		logger.Println("音频服务异常，尝试修复...")
		if recoverAudio() {
			lastRecoverTime = now
			state.LastRecover = fmt.Sprintf("%s 修复音频服务", now.Format("15:04:05"))
		}
		return
	}
}

// inStablePeriod 检查是否在agent稳定期内
func inStablePeriod() bool {
	markFile := cfg.VarDir + "/agent_stable.mark"
	data, err := os.ReadFile(markFile)
	if err != nil {
		return false
	}
	var start int64
	fmt.Sscanf(string(data), "%d", &start)
	if start == 0 {
		return false
	}
	return time.Now().Unix()-start < int64(cfg.StablePeriod)
}

// recoverWebrtc 重建WebRTC容器
func recoverWebrtc() bool {
	composeDir := cfg.AppDir + "/docker"
	cmd := exec.Command("sh", "-c",
		fmt.Sprintf("cd %s && docker compose -p androidemu up -d webrtc 2>&1", composeDir))
	out, err := cmd.CombinedOutput()
	if err != nil {
		logger.Printf("重建WebRTC失败: %v, %s", err, string(out))
		return false
	}
	logger.Println("WebRTC容器重建成功")
	time.Sleep(5 * time.Second)
	return true
}

// recoverAgent 重新部署agent
func recoverAgent() bool {
	script := cfg.AppDir + "/scripts/agent_autodeploy.sh"
	cmd := exec.Command("bash", script, "--force")
	cmd.Env = append(os.Environ(),
		"TRIM_PKGVAR="+cfg.VarDir,
		"TRIM_APPDEST="+cfg.AppDir)
	out, err := cmd.CombinedOutput()
	if err != nil {
		logger.Printf("重新部署agent失败: %v, %s", err, string(out))
		return false
	}
	logger.Println("agent重新部署成功")
	return true
}

// recoverAudio 修复音频服务
func recoverAudio() bool {
	_, err := dockerExec(cfg.AndroidContainer, "sh", "-c",
		"setprop debug.stagefright.ccodec 1")
	if err != nil {
		logger.Printf("修复音频失败: %v", err)
		return false
	}
	logger.Println("音频服务修复成功")
	return true
}
