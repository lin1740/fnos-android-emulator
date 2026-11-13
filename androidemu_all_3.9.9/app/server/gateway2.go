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
	out, code := outOf(exec.Command(bin("ss"), "-lun"))
	if code != 0 {
		return false
	}
	return strings.Contains(out, fmt.Sprintf(":%d ", port)) || strings.Contains(out, fmt.Sprintf(":%d\n", port))
}

func dockerContainers() map[string]string {
	out, code := outOf(exec.Command(bin("docker"), "ps", "-a", "--filter", "name=androidemu", "--format", "{{.Names}}|{{.Status}}"))
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

// dockerOK 判断「网关这一侧到底能不能用 docker」。
// 与 dockerContainers() 的区别：容器数为 0 有两种完全不同的原因 ——
//
//	① 真的还没建容器（首次安装拉镜像中）→ 该提示「正在安装中」；
//	② 网关进程拿不到 docker 命令/守护（PATH 缺 /usr/bin、docker 未起）→ 提示「正在安装中」
//	   会误导用户白等，必须单独区分。（3.9.9 实测：容器在跑却一直显示安装中即此因）
func dockerOK() bool {
	dockerChkMu.Lock()
	defer dockerChkMu.Unlock()
	if time.Since(dockerChkAt) < 5*time.Second {
		return dockerChkVal
	}
	out, code := outOf(exec.Command(bin("docker"), "version", "--format", "{{.Server.Version}}"))
	dockerChkVal = code == 0 && strings.TrimSpace(out) != ""
	dockerChkAt = time.Now()
	return dockerChkVal
}

var (
	dockerChkMu  sync.Mutex
	dockerChkAt  time.Time
	dockerChkVal bool
)

func statusPageHTML(errMsg string) []byte {
	containers := dockerContainers()
	boot := false
	if st, ok := containers["androidemu-android"]; ok && strings.Contains(st, "Up") {
		out, code := outOf(exec.Command(bin("docker"), "exec", "androidemu-android", "getprop", "sys.boot_completed"))
		boot = code == 0 && strings.TrimSpace(out) == "1"
	}
	var stage, title, desc string
	switch {
	case len(containers) == 0 && !dockerOK():
		stage, title, desc = "docker_unavailable", "暂时读不到容器状态", "网关暂时无法访问 Docker 服务。请点下方「刷新」重试；若一直这样，请在应用中心「停用」后再「启用」。"
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
		if dockerOK() {
			rows = "<tr><td colspan='2'>暂无容器（首次安装正在拉取镜像）</td></tr>"
		} else {
			rows = "<tr><td colspan='2'>未能读取容器列表（Docker 服务暂不可用）</td></tr>"
		}
	}
	errHtml := ""
	if errMsg != "" {
		// 3.9.5：安装/启动阶段不把原始技术错误（如 dial tcp 127.0.0.1:8443:
		// connection refused）直接抛给用户 —— 那只是「容器还没起来」的正常中间
		// 状态，红色技术报错会让用户误以为安装失败、产生大量无效反馈。
		switch stage {
		case "installing", "no_container", "booting", "docker_unavailable":
			errHtml = "<div class='notice'>提示：Android 系统正在准备中，页面会自动刷新。" +
				"首次安装需要拉取约 2GB 系统镜像，通常 1-5 分钟，无需任何操作。</div>"
		case "upstream_down":
			// 3.9.9：容器在跑、安卓也起来了，只是投屏端口没应答。原来这里把裸错误
			// （实测用户看到的就是一行「EOF」）用红框甩出来，既看不懂也不知道做什么。
			// 改为可操作提示，技术细节缩到小字里备查。
			errHtml = "<div class='notice'>投屏服务暂时没有应答。常见原因：刚刚重启、服务还在初始化；" +
				"或投屏容器卡住。可先等 10 秒（页面会自动刷新），仍不恢复就点下方「重启投屏服务」。</div>" +
				"<p style='font-size:12px;color:#999;margin:6px 0'>技术信息：" + htmlEscape(errMsg) + "</p>"
		default:
			errHtml = "<div class='error'>" + htmlEscape(errMsg) + "</div>"
		}
	}
	// 上游地址直接摆出来：端口被自定义过、或与 compose 映射不一致时，
	// 用户/维护者一眼就能看出网关连的是哪个端口，不用猜。
	upstream := fmt.Sprintf("%s:%d（配置 %s）", UPSTREAM_HOST, UPSTREAM_PORT, protoName(USE_TLS))
	// 异常阶段自动刷新，省掉「刷新页面」这一步；正常进面板后不再刷（不能打断会话）。
	auto := "0"
	switch stage {
	case "installing", "no_container", "booting", "docker_unavailable", "upstream_down":
		auto = "1"
	}
	html := strings.NewReplacer(
		"{{STAGE}}", stage, "{{TITLE}}", title, "{{DESC}}", desc,
		"{{ERR}}", errHtml, "{{ROWS}}", rows,
		"{{UPSTREAM}}", upstream, "{{AUTO}}", auto).Replace(statusTemplate)
	return []byte(html)
}

// htmlEscape 只处理状态页会用到的几个字符，避免技术信息里的尖括号破坏结构。
func htmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

// upstreamWebOK：投屏端口是否真的有服务在应答。
// 「容器 Up + surfaceflinger 在跑」不等于 8443 能应答 —— 实测出现过健康状态显示
// 「运行正常」、页面同时报「画面服务未响应 + EOF」，用户完全无从下手。
// 判定口径：TLS 握手成功，或明文请求拿到合法 HTTP 响应（复用协议探测的结果）。
var (
	webOKMu  sync.Mutex
	webOKAt  time.Time
	webOKVal bool
)

func upstreamWebOK() bool {
	webOKMu.Lock()
	defer webOKMu.Unlock()
	if time.Since(webOKAt) < 5*time.Second {
		return webOKVal
	}
	v := probeUpstreamTLS()
	webOKVal = v == 1 || v == 0
	webOKAt = time.Now()
	return webOKVal
}

func checkContainerHealth() map[string]interface{} {
	h := map[string]interface{}{
		"status": "unknown", "boot_completed": false, "uptime_seconds": 0,
		"oom_killed": false, "surfaceflinger_running": false,
		"agent_running": false, "detail": "",
	}
	out, code := outOf(exec.Command(bin("docker"), "ps", "--filter", "name=androidemu-android", "--format", "{{.Status}}|{{.RunningFor}}"))
	if code != 0 || strings.TrimSpace(out) == "" {
		// 3.9.9：区分「容器确实没起来」与「网关这一侧读不到 docker」。
		// 后者若报「安卓容器未运行」，用户会以为容器挂了，实际容器跑得好好的。
		if !dockerOK() {
			h["status"] = "unknown"
			h["detail"] = "网关暂时无法访问 Docker 服务，容器状态未知"
			return h
		}
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
	out, code = outOf(exec.Command(bin("docker"), "exec", "androidemu-android", "getprop", "sys.boot_completed"))
	bootCompleted := code == 0 && strings.TrimSpace(out) == "1"
	h["boot_completed"] = bootCompleted
	out, code = outOf(exec.Command(bin("docker"), "inspect", "-f", "{{.State.StartedAt}}", "androidemu-android"))
	uptime := int64(0)
	if code == 0 {
		if t, err := time.Parse(time.RFC3339, strings.TrimSpace(out)); err == nil {
			uptime = int64(time.Since(t).Seconds())
		}
	}
	h["uptime_seconds"] = uptime
	out, code = outOf(exec.Command(bin("docker"), "inspect", "-f", "{{.State.OOMKilled}}", "androidemu-android"))
	oom := code == 0 && strings.TrimSpace(out) == "true"
	h["oom_killed"] = oom
	out, code = outOf(exec.Command(bin("docker"), "exec", "androidemu-android", "ps", "-A"))
	sf := false
	agent := false
	if code == 0 {
		sf = strings.Contains(out, "surfaceflinger")
		low := strings.ToLower(out)
		agent = strings.Contains(low, "agent") || strings.Contains(low, "scrcpy")
	}
	h["surfaceflinger_running"] = sf
	h["agent_running"] = agent
	// 3.9.9：投屏端口真实探活。只在安卓已启动时做，避免启动阶段白等两次 3 秒超时。
	webOK := false
	if bootCompleted {
		webOK = upstreamWebOK()
	}
	h["web_ok"] = webOK
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
	case bootCompleted && !webOK:
		h["status"] = "webrtc_down"
		h["detail"] = fmt.Sprintf("安卓已启动，但投屏端口 %d 没有应答（投屏容器可能在重启或已卡住）", UPSTREAM_PORT)
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
		out, code := outOf(exec.Command(bin("docker"), "exec", "androidemu-android", "getprop", "sys.boot_completed"))
		boot = code == 0 && strings.TrimSpace(out) == "1"
	}
	ports := map[string]interface{}{
		"8443_tcp": map[string]interface{}{"name": "Web界面/信令", "listening": checkTCPPort(UPSTREAM_PORT)},
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
		cmd := exec.Command(bin("docker"), "restart", "androidemu-android")
		err := cmd.Run()
		if err == nil {
			setMsg(true, "容器重启命令已发送，等待1-2分钟后刷新页面")
		} else {
			setMsg(false, err.Error())
		}
	case "fix_gpu":
		exec.Command(bin("docker"), "exec", "-u", "0", "androidemu-android", "chmod", "0666", "/dev/dri/renderD128").Run()
		exec.Command(bin("docker"), "exec", "-u", "0", "androidemu-android", "chmod", "0666", "/dev/dri/card0").Run()
		exec.Command(bin("docker"), "exec", "-u", "0", "androidemu-android", "setprop", "ctl.restart", "surfaceflinger").Run()
		setMsg(true, "GPU修复已执行（/dev/dri放权 + 重启surfaceflinger），等待30秒后刷新页面")
	case "restart_surfaceflinger":
		err := exec.Command(bin("docker"), "exec", "-u", "0", "androidemu-android", "setprop", "ctl.restart", "surfaceflinger").Run()
		if err == nil {
			setMsg(true, "surfaceflinger重启命令已发送")
		} else {
			setMsg(false, err.Error())
		}
	case "restart_webrtc":
		// 3.9.9：投屏容器（androidemu-webrtc）才是「画面服务」本体。
		// 原来三个动作里没有任何一个会重启它 —— 端口无应答时用户只能干等。
		err := exec.Command(bin("docker"), "restart", "androidemu-webrtc").Run()
		if err == nil {
			setMsg(true, "投屏服务正在重启，约 15 秒后请刷新页面")
		} else {
			setMsg(false, err.Error())
		}
	default:
		result["message"] = "未知操作，支持: restart_container, restart_webrtc, fix_gpu, restart_surfaceflinger"
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

// syncUpstreamPortFromDocker 以投屏容器的实际端口映射为准修正上游端口。
//
// 背景（实测 2026-11-13，群友机器）：画面服务映射为「宿主 8440 → 容器 8443」，而
// ports.conf 里仍写着 8443；宿主 8443 上是飞牛自己的 Web 桌面 —— 网关按配置连 8443
// 就连到飞牛桌面去了：TLS 握手成功，但 HTTP 层被拒/断开，最终表现为「画面服务未响应
// + EOF」。用户点容器上的 8443 链接会直接跳到飞牛桌面，正好印证端口被别的服务占着。
//
// 处理：只要容器在跑，就以 docker 的实际映射为准；读不到映射（容器没起）才用配置值。
func syncUpstreamPortFromDocker() {
	out, code := outOf(exec.Command(bin("docker"), "port", "androidemu-webrtc", "8443"))
	if code != 0 || strings.TrimSpace(out) == "" {
		return
	}
	best := 0
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		i := strings.LastIndex(line, ":")
		if i < 0 {
			continue
		}
		p, err := strconv.Atoi(line[i+1:])
		if err != nil || p <= 0 || p > 65535 {
			continue
		}
		// 优先取 IPv4 那条（0.0.0.0:PORT），否则取先读到的
		if best == 0 || strings.HasPrefix(line, "0.0.0.0:") {
			best = p
		}
	}
	if best > 0 && best != UPSTREAM_PORT {
		logf("上游端口修正：ports.conf=%d，容器实际映射=%d → 按实际端口连接（避免连到宿主上其它 HTTPS 服务）", UPSTREAM_PORT, best)
		UPSTREAM_PORT = best
	}
}
