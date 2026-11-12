package main

// 请求处理 / WebSocket / 守护生命周期（对齐 gateway.py 行为）

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

func bytesContains(b, sub []byte) bool { return bytes.Contains(b, sub) }

// ---------------------------------------------------------------- 读写工具

// readHeadLines 读取请求/响应头（含首行），最多 max 行
func readHeadLines(br *bufio.Reader, max int) ([]string, error) {
	var out []string
	for i := 0; i < max; i++ {
		line, err := br.ReadString('\n')
		if err != nil {
			if len(out) > 0 {
				return out, nil
			}
			return out, err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		out = append(out, line)
	}
	return out, nil
}

func headerMap(lines []string) map[string]string {
	m := map[string]string{}
	for _, h := range lines[1:] {
		i := strings.Index(h, ":")
		if i < 0 {
			continue
		}
		m[strings.ToLower(strings.TrimSpace(h[:i]))] = strings.TrimSpace(h[i+1:])
	}
	return m
}

var hopHeaders = map[string]bool{
	"connection": true, "keep-alive": true, "proxy-connection": true, "transfer-encoding": true,
}

// stripHop 去掉 hop-by-hop 与 x-trim-* 头，返回原始头行
func stripHop(lines []string) []string {
	out := []string{}
	for _, h := range lines {
		i := strings.Index(h, ":")
		if i < 0 {
			continue
		}
		k := strings.ToLower(strings.TrimSpace(h[:i]))
		if hopHeaders[k] || strings.HasPrefix(k, "x-trim-") {
			continue
		}
		out = append(out, h)
	}
	return out
}

func readChunked(br *bufio.Reader) []byte {
	var out bytes.Buffer
	for {
		line, err := br.ReadString('\n')
		if err != nil || strings.TrimSpace(line) == "" {
			if err != nil {
				break
			}
			continue
		}
		s := strings.TrimSpace(line)
		n, err := strconv.ParseInt(strings.Split(s, ";")[0], 16, 64)
		if err != nil {
			break
		}
		if n == 0 {
			br.ReadString('\n')
			break
		}
		io.CopyN(&out, br, n)
		br.Read(make([]byte, 2))
	}
	return out.Bytes()
}

func readCLBytes(br *bufio.Reader, cl int64) []byte {
	if cl <= 0 {
		return nil
	}
	buf := make([]byte, cl)
	io.ReadFull(br, buf)
	return buf
}

func sendErr(conn net.Conn, code int, text string) {
	body := []byte(text + "\n")
	reason := httpReason(code)
	hdr := fmt.Sprintf("HTTP/1.1 %d %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
		code, reason, len(body))
	conn.Write(append([]byte(hdr), body...))
}

// sendUpstreamJSON：上游暂时不可用时给 API/静态资源的结构化响应。
// 3.9.7：不再把 "Bad Gateway: xxx" 当纯文本抛给前端 —— 前端会把这串文本
// 弹成全局错误提示（群友实测）。改成 JSON，前端可自行判断是否重试。
// 状态码仍为 502，不改变任何前端已有的错误处理分支。
func sendUpstreamJSON(conn net.Conn, detail string) {
    b := []byte(`{"error":"upstream_not_ready","detail":"` + detail + `"}`)
    hdr := fmt.Sprintf("HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", len(b))
    conn.Write(append([]byte(hdr), b...))
}

func httpReason(code int) string {
	switch code {
	case 400:
		return "Bad Request"
	case 404:
		return "Not Found"
	case 502:
		return "Bad Gateway"
	case 503:
		return "Service Unavailable"
	}
	return "Error"
}

// ---------------------------------------------------------------- 会话注入头

var corsLines = []string{
	"Access-Control-Allow-Origin: *",
	"Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS, PATCH",
	"Access-Control-Allow-Headers: Authorization, Content-Type, X-Requested-With",
}

// ---------------------------------------------------------------- WebSocket

func wsPingFrame(masked bool) []byte {
	pl := []byte("gwke")
	if !masked {
		return append([]byte{0x89, 0x04}, pl...)
	}
	k := []byte{0x11, 0x22, 0x33, 0x44}
	out := append([]byte{0x89, 0x84}, k...)
	for i, b := range pl {
		out = append(out, b^k[i%4])
	}
	return out
}

type wsPair struct {
	cu sync.Mutex // 双向写锁（对齐 Python 的 lock）
}

func wsKeepalive(client, upstream net.Conn, done chan struct{}, p *wsPair) {
	cf := wsPingFrame(false)
	uf := wsPingFrame(true)
	for {
		select {
		case <-done:
			return
		case <-time.After(time.Duration(WS_PING) * time.Second):
		}
		p.cu.Lock()
		_, err1 := client.Write(cf)
		_, err2 := upstream.Write(uf)
		p.cu.Unlock()
		if err1 != nil || err2 != nil {
			return
		}
	}
}

func wsTunnel(a, b net.Conn, done chan struct{}, p *wsPair) {
	defer func() {
		closeOnce(p)
	}()
	buf := make([]byte, 65536)
	for {
		n, err := a.Read(buf)
		if n > 0 {
			p.cu.Lock()
			_, werr := b.Write(buf[:n])
			p.cu.Unlock()
			if werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

var closeOnceMu sync.Mutex
var closedPairs = map[*wsPair]bool{}

func closeOnce(p *wsPair) {
	closeOnceMu.Lock()
	defer closeOnceMu.Unlock()
	if closedPairs[p] {
		return
	}
	closedPairs[p] = true
}

func handleWS(conn net.Conn, method, path string, reqLines []string) {
	u, err := dialUpstream()
	if err != nil {
		// 3.9.7：先重试一次（上游容器可能正在起来），仍失败再给结构化响应
		u, err = dialUpstream()
		if err != nil {
			sendUpstreamJSON(conn, "signaling_unreachable")
			conn.Close()
			return
		}
	}
	logf("WS 升级: %s", path)
	tok := ensureSession()
	wsPath := path
	if tok != "" {
		wsPath = subToken(path, tok)
	}
	out := []string{fmt.Sprintf("%s %s HTTP/1.1", method, wsPath)}
	for _, h := range reqLines[1:] {
		i := strings.Index(h, ":")
		if i < 0 {
			continue
		}
		k := strings.ToLower(strings.TrimSpace(h[:i]))
		if strings.HasPrefix(k, "x-trim-") || k == "keep-alive" || k == "proxy-connection" || k == "transfer-encoding" {
			continue
		}
		out = append(out, h)
	}
	u.Write([]byte(strings.Join(out, "\r\n") + "\r\n\r\n"))
	ubr := bufio.NewReader(u)
	code, respLines, rerr := readRespHead(ubr)
	if code != 101 && tok != "" && strings.HasPrefix(strings.Split(path, "?")[0], "/connect_client") {
		logf("WS 被拒（上游 %d），改用服务端会话重试：%s", code, path)
		u.Close()
		clearSession()
		if u2, e2 := dialUpstream(); e2 == nil {
			u = u2
			ubr = bufio.NewReader(u)
			tok2 := ensureSession()
			np := path
			if tok2 != "" {
				np = subToken(path, tok2)
			}
			hdrs := []string{fmt.Sprintf("%s %s HTTP/1.1", method, np)}
			for _, h := range reqLines[1:] {
				i := strings.Index(h, ":")
				if i < 0 {
					continue
				}
				k := strings.ToLower(strings.TrimSpace(h[:i]))
				if strings.HasPrefix(k, "x-trim-") || k == "keep-alive" || k == "proxy-connection" || k == "transfer-encoding" {
					continue
				}
				hdrs = append(hdrs, h)
			}
			u.Write([]byte(strings.Join(hdrs, "\r\n") + "\r\n\r\n"))
			code, respLines, rerr = readRespHead(ubr)
		} else {
			logf("WS 重试异常：%v", e2)
			respLines = nil
			code = 0
		}
		logf("WS 重试结果：上游 %d", code)
	}
	_ = rerr
	if len(respLines) > 0 {
		conn.Write([]byte(strings.Join(respLines, "\r\n") + "\r\n\r\n"))
	}
	if code != 101 {
		logf("WS 未升级（上游 %d）：%s", code, path)
		u.Close()
		conn.Close()
		return
	}
	t0 := time.Now()
	p := &wsPair{}
	done := make(chan struct{})
	go wsKeepalive(conn, u, done, p)
	go func() {
		wsTunnel(conn, u, done, p)
	}()
	wsTunnel(u, conn, done, p)
	logf("WS 结束: %s（持续 %.1f 秒）", path, time.Since(t0).Seconds())
}

// ---------------------------------------------------------------- 附加接口

func outOf(cmd *exec.Cmd) (string, int) {
	b, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return string(b), ee.ExitCode()
		}
		return string(b), -1
	}
	return string(b), 0
}

func checkTCPPort(port int) bool {
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 2*time.Second)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

func checkUDPPort(port int) bool {
	out, code := outOf(exec.Command("ss", "-lun"))
	if code != 0 {
		return false
	}
	return strings.Contains(out, fmt.Sprintf(":%d ", port)) || strings.Contains(out, fmt.Sprintf(":%d\n", port))
}

func dockerContainers() map[string]string {
	out, code := outOf(exec.Command("docker", "ps", "-a", "--filter", "name=androidemu", "--format", "{{.Names}}|{{.Status}}"))
	m := map[string]string{}
	if code != 0 {
		return m
	}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if i := strings.Index(line, "|"); i > 0 {
			m[line[:i]] = line[i+1:]
		}
	}
	return m
}

func statusPageHTML(errMsg string) []byte {
	containers := dockerContainers()
	boot := false
	if st, ok := containers["androidemu-android"]; ok && strings.Contains(st, "Up") {
		out, code := outOf(exec.Command("docker", "exec", "androidemu-android", "getprop", "sys.boot_completed"))
		boot = code == 0 && strings.TrimSpace(out) == "1"
	}
	var stage, title, desc string
	switch {
	case len(containers) == 0:
		stage, title, desc = "installing", "正在安装中", "应用正在后台拉取安卓镜像（约 2GB）并启动容器，请耐心等待 1-5 分钟后刷新页面。"
	case containers["androidemu-android"] == "":
		stage, title, desc = "no_container", "安卓容器未创建", "安卓容器尚未创建，可能安装未完成或被手动删除。请尝试在应用中心停用后重新启用。"
	case strings.Contains(containers["androidemu-android"], "Exited"):
		stage, title, desc = "container_exited", "安卓容器已停止", "安卓容器已退出。请在应用中心点击「停用」后再「启用」，或查看日志排查原因。"
	case !boot:
		stage, title, desc = "booting", "安卓系统正在启动", "容器已运行，但安卓系统尚未完成启动。首次启动可能需要 1-3 分钟，请刷新页面重试。"
	default:
		stage, title, desc = "upstream_down", "画面服务未响应", "安卓系统已启动，但穿云投屏画面服务暂时无响应。请刷新页面，或在应用中心停用后重新启用。"
	}
	rows := ""
	for name, st := range containers {
		rows += "<tr><td>" + name + "</td><td>" + st + "</td></tr>"
	}
	if rows == "" {
		rows = "<tr><td colspan='2'>暂无容器（首次安装正在拉取镜像）</td></tr>"
	}
	errHtml := ""
	if errMsg != "" {
		// 3.9.5：安装/启动阶段不把原始技术错误（如 dial tcp 127.0.0.1:8443:
		// connection refused）直接抛给用户 —— 那只是「容器还没起来」的正常中间
		// 状态，红色技术报错会让用户误以为安装失败、产生大量无效反馈。
		switch stage {
		case "installing", "no_container", "booting":
			errHtml = "<div class='notice'>提示：Android 系统正在准备中，页面会自动刷新。" +
				"首次安装需要拉取约 2GB 系统镜像，通常 1-5 分钟，无需任何操作。</div>"
		default:
			errHtml = "<div class='error'>" + errMsg + "</div>"
		}
	}
	html := strings.NewReplacer(
		"{{STAGE}}", stage, "{{TITLE}}", title, "{{DESC}}", desc,
		"{{ERR}}", errHtml, "{{ROWS}}", rows).Replace(statusTemplate)
	return []byte(html)
}

func checkContainerHealth() map[string]interface{} {
	h := map[string]interface{}{
		"status": "unknown", "boot_completed": false, "uptime_seconds": 0,
		"oom_killed": false, "surfaceflinger_running": false,
		"agent_running": false, "detail": "",
	}
	out, code := outOf(exec.Command("docker", "ps", "--filter", "name=androidemu-android", "--format", "{{.Status}}|{{.RunningFor}}"))
	if code != 0 || strings.TrimSpace(out) == "" {
		h["status"] = "not_running"
		h["detail"] = "安卓容器未运行"
		return h
	}
	line := strings.TrimSpace(out)
	if i := strings.Index(line, "|"); i > 0 {
		h["container_status"] = line[:i]
	} else {
		h["container_status"] = line
	}
	out, code = outOf(exec.Command("docker", "exec", "androidemu-android", "getprop", "sys.boot_completed"))
	bootCompleted := code == 0 && strings.TrimSpace(out) == "1"
	h["boot_completed"] = bootCompleted
	out, code = outOf(exec.Command("docker", "inspect", "-f", "{{.State.StartedAt}}", "androidemu-android"))
	uptime := int64(0)
	if code == 0 {
		if t, err := time.Parse(time.RFC3339, strings.TrimSpace(out)); err == nil {
			uptime = int64(time.Since(t).Seconds())
		}
	}
	h["uptime_seconds"] = uptime
	out, code = outOf(exec.Command("docker", "inspect", "-f", "{{.State.OOMKilled}}", "androidemu-android"))
	oom := code == 0 && strings.TrimSpace(out) == "true"
	h["oom_killed"] = oom
	out, code = outOf(exec.Command("docker", "exec", "androidemu-android", "ps", "-A"))
	sf := false
	agent := false
	if code == 0 {
		sf = strings.Contains(out, "surfaceflinger")
		low := strings.ToLower(out)
		agent = strings.Contains(low, "agent") || strings.Contains(low, "scrcpy")
	}
	h["surfaceflinger_running"] = sf
	h["agent_running"] = agent
	switch {
	case oom:
		h["status"] = "oom_killed"
		h["detail"] = "容器因内存不足被系统杀死（OOM），请增加可用内存或关闭其他应用"
	case !bootCompleted && uptime > 300:
		h["status"] = "boot_timeout"
		h["detail"] = "安卓系统启动超过5分钟仍未完成，可能是binder/GPU/内存问题"
	case bootCompleted && !sf:
		h["status"] = "surfaceflinger_dead"
		h["detail"] = "安卓已启动但surfaceflinger未运行，画面服务异常"
	case bootCompleted:
		h["status"] = "healthy"
		h["detail"] = "安卓系统运行正常"
	default:
		h["status"] = "booting"
		h["detail"] = "安卓系统正在启动中"
	}
	return h
}

func apiStatus() []byte {
	containers := dockerContainers()
	boot := false
	if _, ok := containers["androidemu-android"]; ok {
		out, code := outOf(exec.Command("docker", "exec", "androidemu-android", "getprop", "sys.boot_completed"))
		boot = code == 0 && strings.TrimSpace(out) == "1"
	}
	ports := map[string]interface{}{
		"8443_tcp": map[string]interface{}{"name": "Web界面/信令", "listening": checkTCPPort(8443)},
		"3478_tcp": map[string]interface{}{"name": "TURN中继(TCP)", "listening": checkTCPPort(3478)},
		"3478_udp": map[string]interface{}{"name": "TURN中继(UDP)", "listening": checkUDPPort(3478)},
		"5556_tcp": map[string]interface{}{"name": "ADB调试", "listening": checkTCPPort(5556)},
	}
	health := checkContainerHealth()
	b, _ := json.Marshal(map[string]interface{}{
		"containers": containers, "boot_completed": boot,
		"version": VERSION, "prefix": PREFIX, "ports": ports, "health": health,
	})
	return b
}

func apiHealthFix(action string) []byte {
	result := map[string]interface{}{"ok": false, "action": action, "message": ""}
	setMsg := func(ok bool, msg string) {
		result["ok"] = ok
		result["message"] = msg
	}
	switch action {
	case "restart_container":
		cmd := exec.Command("docker", "restart", "androidemu-android")
		err := cmd.Run()
		if err == nil {
			setMsg(true, "容器重启命令已发送，等待1-2分钟后刷新页面")
		} else {
			setMsg(false, err.Error())
		}
	case "fix_gpu":
		exec.Command("docker", "exec", "-u", "0", "androidemu-android", "chmod", "0666", "/dev/dri/renderD128").Run()
		exec.Command("docker", "exec", "-u", "0", "androidemu-android", "chmod", "0666", "/dev/dri/card0").Run()
		exec.Command("docker", "exec", "-u", "0", "androidemu-android", "setprop", "ctl.restart", "surfaceflinger").Run()
		setMsg(true, "GPU修复已执行（/dev/dri放权 + 重启surfaceflinger），等待30秒后刷新页面")
	case "restart_surfaceflinger":
		err := exec.Command("docker", "exec", "-u", "0", "androidemu-android", "setprop", "ctl.restart", "surfaceflinger").Run()
		if err == nil {
			setMsg(true, "surfaceflinger重启命令已发送")
		} else {
			setMsg(false, err.Error())
		}
	default:
		result["message"] = "未知操作，支持: restart_container, fix_gpu, restart_surfaceflinger"
	}
	b, _ := json.Marshal(result)
	return b
}

func streamMJPG(conn net.Conn) {
	boundary := []byte("--frame")
	conn.Write([]byte("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"))
	frames, errors := 0, 0
	for {
		cmd := exec.Command("/usr/bin/docker", "exec", "androidemu-android", "screencap", "-p")
		var stdout bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = nil
		timer := time.AfterFunc(8*time.Second, func() { cmd.Process.Kill() })
		err := cmd.Run()
		timer.Stop()
		img := stdout.Bytes()
		if err != nil || len(img) == 0 {
			errors++
			if errors <= 3 {
				logf("MJPEG 截图失败（第%d次）", errors)
			}
			time.Sleep(500 * time.Millisecond)
			continue
		}
		if _, err := conn.Write(boundary); err != nil {
			break
		}
		if _, err := conn.Write([]byte("\r\nContent-Type: image/png\r\n")); err != nil {
			break
		}
		if _, err := conn.Write([]byte(fmt.Sprintf("Content-Length: %d\r\n\r\n", len(img)))); err != nil {
			break
		}
		if _, err := conn.Write(img); err != nil {
			break
		}
		if _, err := conn.Write([]byte("\r\n")); err != nil {
			break
		}
		frames++
		errors = 0
		time.Sleep(150 * time.Millisecond)
	}
	logf("MJPEG 流结束，共 %d 帧，错误 %d 次", frames, errors)
	conn.Close()
}
