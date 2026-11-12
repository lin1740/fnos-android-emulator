package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// StartAPI 启动HTTP API
func StartAPI(ctx context.Context) {
	mux := http.NewServeMux()
	mux.HandleFunc("/status", handleStatus)
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/recover/agent", handleRecoverAgent)
	mux.HandleFunc("/recover/webrtc", handleRecoverWebrtc)

	addr := fmt.Sprintf("127.0.0.1:%d", cfg.HTTPPort)
	srv := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	go func() {
		logger.Printf("HTTP API 监听: %s", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Printf("HTTP API 错误: %v", err)
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(shutdownCtx)
	logger.Println("HTTP API 已停止")
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	stateMux.RLock()
	defer stateMux.RUnlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(state)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	stateMux.RLock()
	defer stateMux.RUnlock()
	healthy := state.AndroidContainer.Running && state.WebrtcContainer.Running
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"healthy": healthy,
		"android": state.AndroidContainer.Running,
		"webrtc":  state.WebrtcContainer.Running,
		"agent":   state.AgentProcess.Running,
	})
}

func handleRecoverAgent(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	go func() {
		lastRecoverTime = time.Time{} // 清除冷却
		if recoverAgent() {
			logger.Println("手动触发agent恢复成功")
		}
	}()
	w.WriteHeader(http.StatusAccepted)
	json.NewEncoder(w).Encode(map[string]string{"status": "recovering"})
}

func handleRecoverWebrtc(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	go func() {
		lastRecoverTime = time.Time{} // 清除冷却
		if recoverWebrtc() {
			logger.Println("手动触发WebRTC恢复成功")
		}
	}()
	w.WriteHeader(http.StatusAccepted)
	json.NewEncoder(w).Encode(map[string]string{"status": "recovering"})
}
