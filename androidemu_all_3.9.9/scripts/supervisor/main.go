package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

const version = "1.0.0"

var (
	cfg      *Config
	logger   *log.Logger
	stopCh   chan struct{}
	wg       sync.WaitGroup
	state    *State
	stateMux sync.RWMutex
)

type State struct {
	AndroidContainer ContainerStatus `json:"android_container"`
	WebrtcContainer  ContainerStatus `json:"webrtc_container"`
	AgentProcess     ProcessStatus   `json:"agent_process"`
	AudioService     ServiceStatus   `json:"audio_service"`
	LastRecover      string          `json:"last_recover"`
	Uptime           string          `json:"uptime"`
}

type ContainerStatus struct {
	Running bool   `json:"running"`
	Status  string `json:"status"`
	Memory  string `json:"memory"`
}

type ProcessStatus struct {
	Running bool   `json:"running"`
	Pid     string `json:"pid"`
}

type ServiceStatus struct {
	Healthy bool   `json:"healthy"`
	Message string `json:"message"`
}

func main() {
	logger = log.New(os.Stdout, "[supervisor] ", log.LstdFlags|log.Lshortfile)
	stopCh = make(chan struct{})
	state = &State{}

	var err error
	cfg, err = LoadConfig()
	if err != nil {
		logger.Fatalf("加载配置失败: %v", err)
	}

	logger.Printf("androidemu 统一守护进程 v%s 启动", version)
	logger.Printf("配置: 安卓容器=%s, WebRTC容器=%s, 监控间隔=%ds, HTTP端口=%d",
		cfg.AndroidContainer, cfg.WebrtcContainer, cfg.Interval, cfg.HTTPPort)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 启动HTTP API
	go StartAPI(ctx)

	// 启动监控循环
	wg.Add(1)
	go MonitorLoop(ctx)

	// 等待信号
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	logger.Println("收到退出信号，正在停止...")
	close(stopCh)
	cancel()
	wg.Wait()
	logger.Println("已退出")
}
