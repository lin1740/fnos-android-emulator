package main

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	version    = "3.8.5"
	container  = "androidemu-android"
	xmlPath    = "/vendor/etc/media_codecs.xml"
	bakPath    = "/vendor/etc/media_codecs.xml.androidemu.bak"
	codec      = "c2.android.opus.encoder"
	listenAddr = "127.0.0.1:18443"
	cooldown   = 60 // 分辨率切换冷却时间（秒）
)

var (
	varDir     = getEnv("TRIM_PKGVAR", "/var/apps/androidemu/var")
	logFile    = filepath.Join(varDir, "androidemu_daemon.log")
	pidFile    = filepath.Join(varDir, "audio_watchdog.pid")
	lockFile   = filepath.Join(varDir, ".audio.lock")
	statusFile = filepath.Join(varDir, "audio.status")
	resConf    = filepath.Join(varDir, "resolution.conf")
	resPidFile = filepath.Join(varDir, "resolution_autoswitch.pid")
	interval   = 30 // 音频检查间隔（秒）

	// 分辨率切换状态
	lastSwitch time.Time
	currentDev string
	resMu      sync.Mutex
	switchCh   = make(chan string, 16)

	logger *log.Logger
)

var codecBlock = `        <MediaCodec name="c2.android.opus.encoder" type="audio/opus">
            <Limit name="channel-count" max="2" />
            <Limit name="sample-rate" ranges="8000-48000" />
            <Limit name="bitrate" range="6000-510000" />
        </MediaCodec>
`

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func initLogger() {
	os.MkdirAll(varDir, 0755)
	f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		logger = log.New(os.Stderr, "", log.LstdFlags)
		return
	}
	logger = log.New(f, "", log.LstdFlags)
}

func logMsg(msg string) {
	if logger != nil {
		logger.Println(msg)
	}
}

// ========== 通用工具 ==========

func dsh(cmd string, stdin []byte, timeout int) (int, string, string) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
	defer cancel()
	args := []string{"exec", "-i", "-u", "0", container, "sh", "-c", cmd}
	c := exec.CommandContext(ctx, "docker", args...)
	if stdin != nil {
		c.Stdin = bytes.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	c.Stdout = &stdout
	c.Stderr = &stderr
	err := c.Run()
	rc := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			rc = exitErr.ExitCode()
		} else {
			rc = -1
		}
	}
	return rc, stdout.String(), stderr.String()
}

func containerRunning() bool {
	rc, out, _ := dsh("echo ok", nil, 10)
	return rc == 0 && strings.Contains(out, "ok")
}

func readRemote(path string) []byte {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c := exec.CommandContext(ctx, "docker", "exec", "-u", "0", container, "cat", path)
	out, err := c.Output()
	if err != nil {
		return nil
	}
	return out
}

func writeRemote(path string, data []byte) (bool, string) {
	rc, _, err := dsh("cat > "+path, data, 30)
	if rc != 0 {
		return false, strings.TrimSpace(err)
	}
	return true, ""
}

func fileExists(path string) bool {
	rc, _, _ := dsh("[ -f "+path+" ]", nil, 10)
	return rc == 0
}

// ========== 音频修复 ==========

func setStatus(ok bool, msg string) {
	okStr := "0"
	if ok {
		okStr = "1"
	}
	content := fmt.Sprintf("OK=%s\nMSG=%s\nTS=%d\nVER=%s\n", okStr, msg, time.Now().Unix(), version)
	os.WriteFile(statusFile, []byte(content), 0644)
}

func libExists() bool {
	cmd := "[ -e /system/lib64/libcodec2_soft_opusenc.so ] || " +
		"[ -e /system/apex/com.android.media.swcodec/lib64/libcodec2_soft_opusenc.so ] || " +
		"[ -e /system/lib/libcodec2_soft_opusenc.so ]"
	rc, _, _ := dsh(cmd, nil, 10)
	return rc == 0
}

func codecCount(text string) int {
	return strings.Count(text, codec)
}

func insertBlock(text string) string {
	for _, anchor := range []string{"</Encoders>", "</MediaCodecs>", "</media_codecs>"} {
		if i := strings.Index(text, anchor); i >= 0 {
			lineStart := strings.LastIndex(text[:i], "\n") + 1
			return text[:lineStart] + codecBlock + text[lineStart:]
		}
	}
	if i := strings.LastIndex(text, "</"); i >= 0 {
		lineStart := strings.LastIndex(text[:i], "\n") + 1
		return text[:lineStart] + codecBlock + text[lineStart:]
	}
	return text
}

func restartMedia() {
	dsh("setprop ctl.restart media.swcodec", nil, 10)
	dsh("setprop ctl.restart media", nil, 10)
}

func fixAudio(force bool) (bool, string) {
	lockFd, err := os.OpenFile(lockFile, os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return true, "已有实例正在修复，跳过"
	}
	defer lockFd.Close()
	if err := syscall.Flock(int(lockFd.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return true, "已有实例正在修复，跳过"
	}
	defer syscall.Flock(int(lockFd.Fd()), syscall.LOCK_UN)

	if !containerRunning() {
		return false, "安卓容器未运行，跳过"
	}
	if !libExists() {
		logMsg("Opus 编码器库不存在，跳过")
		return false, "容器内缺少 Opus 编码器库"
	}

	_, ccodecVal, _ := dsh("getprop debug.stagefright.ccodec", nil, 10)
	ccodecVal = strings.TrimSpace(ccodecVal)
	_, c2swVal, _ := dsh("getprop debug.stagefright.c2software", nil, 10)
	c2swVal = strings.TrimSpace(c2swVal)

	_, encoderCheck, _ := dsh("dumpsys media.player 2>/dev/null | grep -A1 'audio/opus' | grep Encoder", nil, 15)
	opusAvailable := strings.Contains(encoderCheck, "c2.android.opus.encoder") ||
		strings.Contains(encoderCheck, "OMX.google.opus.encoder")

	if opusAvailable && ccodecVal == "1" && !force {
		return true, "Opus 编码器已可用（CCodec 已启用）"
	}

	logMsg(fmt.Sprintf("启用 Codec2：debug.stagefright.ccodec=1 (当前=%s), c2software=0 (当前=%s)", ccodecVal, c2swVal))
	dsh("setprop debug.stagefright.ccodec 1", nil, 10)
	dsh("setprop debug.stagefright.c2software 0", nil, 10)

	restartMedia()
	time.Sleep(3 * time.Second)

	_, verify, _ := dsh("dumpsys media.player 2>/dev/null | grep -A1 'audio/opus' | grep Encoder", nil, 15)
	if strings.Contains(verify, "c2.android.opus.encoder") {
		logMsg("Opus 编码器已启用：c2.android.opus.encoder")
		return true, "已启用 Codec2，Opus 编码器可用"
	}

	logMsg("CCodec 启用后 opus 仍未出现，尝试备用方案（注入 media_codecs.xml）")
	return fixAudioXML(force)
}

func fixAudioXML(force bool) (bool, string) {
	if !fileExists(xmlPath) {
		return false, xmlPath + " 不存在"
	}
	raw := readRemote(xmlPath)
	if raw == nil {
		return false, "读取 media_codecs.xml 失败"
	}
	text := string(raw)

	blockRe := regexp.MustCompile(`[ \t]*<MediaCodec\b[^>]*name\s*=\s*"` + regexp.QuoteMeta(codec) + `"[\s\S]*?</MediaCodec>[ \t]*\n?`)
	blocks := blockRe.FindAllString(text, -1)
	count := codecCount(text)

	if count == 1 && len(blocks) == 1 && !force {
		return true, "Opus 编码器声明已存在（1 条）"
	}

	newText := blockRe.ReplaceAllString(text, "")
	newText = insertBlock(newText)
	if newText == text {
		return true, "无需改动"
	}

	if !fileExists(bakPath) {
		ok, err := writeRemote(bakPath, raw)
		if !ok {
			logMsg("备份 media_codecs.xml 失败：" + err)
		}
	}

	ok, err := writeRemote(xmlPath, []byte(newText))
	if !ok {
		dsh("mount -o remount,rw /vendor 2>/dev/null || mount -o rw,remount /vendor 2>/dev/null", nil, 15)
		ok, err = writeRemote(xmlPath, []byte(newText))
	}
	if !ok {
		msg := "写入 media_codecs.xml 失败：" + err
		logMsg(msg)
		return false, msg
	}

	restartMedia()
	return true, "已注入 Opus 编码器声明（备用方案）"
}

func fixWithWait(maxWait, intervalSec int) (bool, string) {
	waited := 0
	for !containerRunning() && waited < maxWait {
		logMsg(fmt.Sprintf("容器未运行，等待启动（已等 %d 秒，最多等 %d 秒）", waited, maxWait))
		fmt.Printf("容器未启动，等待中...（已等 %d 秒）\n", waited)
		time.Sleep(time.Duration(intervalSec) * time.Second)
		waited += intervalSec
	}
	if !containerRunning() {
		msg := fmt.Sprintf("等待 %d 秒后容器仍未启动，跳过本次修复，交由守护进程兜底", maxWait)
		logMsg(msg)
		return false, msg
	}
	logMsg(fmt.Sprintf("容器已启动（等待 %d 秒），开始执行修复", waited))
	return fixAudio(false)
}

// ========== 分辨率自动切换 ==========

func getResolution(device string) string {
	key := strings.ToUpper(device) + "="
	data, err := os.ReadFile(resConf)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, key) {
			return strings.TrimSpace(strings.TrimPrefix(line, key))
		}
	}
	return ""
}

func doSwitchResolution(device string) {
	resMu.Lock()
	defer resMu.Unlock()

	now := time.Now()
	if now.Sub(lastSwitch).Seconds() < cooldown {
		return
	}
	if device == currentDev {
		return
	}

	target := getResolution(device)
	if target == "" {
		return
	}
	if !regexp.MustCompile(`^\d+x\d+$`).MatchString(target) {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "docker", "exec", container, "wm", "size", target)
	output, err := cmd.CombinedOutput()

	if err != nil {
		logMsg(fmt.Sprintf("分辨率切换失败 %s: %s, output=%s, err=%v",
			device, target, strings.TrimSpace(string(output)), err))
		return
	}

	currentDev = device
	lastSwitch = now
	logMsg(fmt.Sprintf("自动切换分辨率为 %s: %s", device, target))
}

func switchWorker() {
	for device := range switchCh {
		doSwitchResolution(device)
	}
}

func resHandler(w http.ResponseWriter, r *http.Request) {
	device := r.URL.Query().Get("device")
	if device == "pc" || device == "phone" || device == "tablet" {
		select {
		case switchCh <- device:
		default:
		}
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Content-Length", "0")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
}

// ========== 守护进程管理 ==========

func pidCmdline(pid int) string {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return ""
	}
	return strings.ReplaceAll(string(data), "\x00", " ")
}

func pidAlive(pid int) bool {
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return proc.Signal(syscall.Signal(0)) == nil
}

func ownPid(pid int) bool {
	info, err := os.Stat(fmt.Sprintf("/proc/%d", pid))
	if err != nil {
		return false
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		return int(stat.Uid) == os.Getuid()
	}
	return false
}

func daemonPid() int {
	if data, err := os.ReadFile(pidFile); err == nil {
		if pid, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
			if pidAlive(pid) && ownPid(pid) && strings.Contains(pidCmdline(pid), "androidemu_daemon") {
				return pid
			}
		}
	}
	me := os.Getpid()
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return 0
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid == me || !ownPid(pid) {
			continue
		}
		cmd := pidCmdline(pid)
		if strings.Contains(cmd, "androidemu_daemon") {
			return pid
		}
	}
	return 0
}

func dropPrivileges() {
	if os.Getuid() != 0 {
		return
	}
	for _, user := range []string{"docker-androidemu", "trim"} {
		out, err := exec.Command("id", "-u", user).Output()
		if err != nil {
			continue
		}
		uid, _ := strconv.Atoi(strings.TrimSpace(string(out)))
		gidOut, _ := exec.Command("id", "-g", user).Output()
		gid, _ := strconv.Atoi(strings.TrimSpace(string(gidOut)))
		if uid > 0 {
			syscall.Setgroups([]int{})
			syscall.Setgid(gid)
			syscall.Setuid(uid)
			os.Setenv("HOME", "/home/"+user)
			os.Setenv("USER", user)
			return
		}
	}
}

func daemon() {
	dropPrivileges()

	// 三重防重复
	existing := daemonPid()
	if existing != 0 && existing != os.Getpid() {
		logMsg(fmt.Sprintf("已有守护进程（pid %d）在运行，本进程退出", existing))
		return
	}
	time.Sleep(time.Duration(200+(os.Getpid()%7)*70) * time.Millisecond)
	existing = daemonPid()
	if existing != 0 && existing != os.Getpid() {
		logMsg(fmt.Sprintf("已有守护进程（pid %d）在运行，本进程退出", existing))
		return
	}

	os.WriteFile(pidFile, []byte(strconv.Itoa(os.Getpid())), 0644)
	os.WriteFile(resPidFile, []byte(strconv.Itoa(os.Getpid())), 0644)
	time.Sleep(800 * time.Millisecond)
	if data, err := os.ReadFile(pidFile); err == nil {
		if owner, _ := strconv.Atoi(strings.TrimSpace(string(data))); owner != os.Getpid() {
			logMsg(fmt.Sprintf("检测到另一个守护进程（pid %d）已接管，本进程退出", owner))
			return
		}
	}

	logMsg(fmt.Sprintf("androidemu 守护进程启动 pid=%d（音频每 %d 秒检查，分辨率HTTP监听 %s，版本 %s）",
		os.Getpid(), interval, listenAddr, version))

	// 启动分辨率切换 worker
	go switchWorker()

	// 启动 HTTP 服务器
	http.HandleFunc("/", resHandler)
	server := &http.Server{
		Addr:         listenAddr,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
		IdleTimeout:  30 * time.Second,
	}
	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logMsg(fmt.Sprintf("HTTP服务器错误: %v", err))
		}
	}()

	// 信号处理
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	ticker := time.NewTicker(time.Duration(interval) * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-sigCh:
			logMsg("收到退出信号，守护进程停止")
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			server.Shutdown(ctx)
			cancel()
			close(switchCh)
			os.Remove(pidFile)
			os.Remove(resPidFile)
			return
		case <-ticker.C:
			func() {
				defer func() {
					if r := recover(); r != nil {
						logMsg(fmt.Sprintf("守护异常：%v", r))
					}
				}()
				ok, msg := fixAudio(false)
				setStatus(ok, msg)
			}()
		}
	}
}

func startDaemon() int {
	if daemonPid() != 0 {
		fmt.Println("守护进程已在运行")
		return 0
	}
	os.Remove(pidFile)
	os.Remove(resPidFile)

	exe, _ := os.Executable()
	cmd := exec.Command(exe, "daemon")
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.Stdin = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		fmt.Printf("守护进程启动失败：%v\n", err)
		return 1
	}

	time.Sleep(1500 * time.Millisecond)
	if pid := daemonPid(); pid != 0 {
		fmt.Printf("守护进程已启动（pid %d）\n", pid)
		return 0
	}
	fmt.Printf("守护进程启动后未检测到进程，请查看 %s\n", logFile)
	return 1
}

func stopDaemon() int {
	pid := daemonPid()
	if pid == 0 {
		os.Remove(pidFile)
		os.Remove(resPidFile)
		fmt.Println("守护进程未在运行")
		return 0
	}
	syscall.Kill(pid, syscall.SIGTERM)
	for i := 0; i < 15; i++ {
		if !pidAlive(pid) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if pidAlive(pid) {
		syscall.Kill(pid, syscall.SIGKILL)
	}
	os.Remove(pidFile)
	os.Remove(resPidFile)
	logMsg("守护进程已停止")
	fmt.Println("守护进程已停止")
	return 0
}

func showStatus() int {
	pid := daemonPid()
	if pid != 0 {
		fmt.Printf("守护进程: running (pid %d)\n", pid)
	} else {
		fmt.Println("守护进程: not running")
	}
	fmt.Printf("音频检查间隔: %d 秒\n", interval)
	fmt.Printf("分辨率监听: %s\n", listenAddr)
	running := containerRunning()
	fmt.Printf("容器: %s（%s）\n", container, map[bool]string{true: "运行中", false: "未运行"}[running])

	if data, err := os.ReadFile(statusFile); err == nil {
		fmt.Printf("音频最近结果:\n%s", string(data))
	} else {
		fmt.Println("音频最近结果: 暂无（尚未执行过修复）")
	}

	if running && fileExists(xmlPath) {
		raw := readRemote(xmlPath)
		fmt.Printf("Opus 声明: %d 条\n", codecCount(string(raw)))
	}
	return 0
}

func main() {
	os.MkdirAll(varDir, 0755)
	initLogger()

	if v := os.Getenv("AUDIO_CHECK_INTERVAL"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			interval = n
		}
	}

	action := "fix"
	if len(os.Args) > 1 {
		action = os.Args[1]
	}

	switch action {
	case "fix":
		ok, msg := fixWithWait(120, 5)
		setStatus(ok, msg)
		fmt.Printf("音频修复：%s（%s）\n", map[bool]string{true: "成功", false: "未完成"}[ok], msg)
		if ok {
			os.Exit(0)
		}
		os.Exit(1)
	case "daemon", "watchdog":
		daemon()
	case "start":
		os.Exit(startDaemon())
	case "stop":
		os.Exit(stopDaemon())
	case "status":
		os.Exit(showStatus())
	default:
		fmt.Printf("用法：%s {fix|daemon|start|stop|status}\n", os.Args[0])
		os.Exit(1)
	}
}
