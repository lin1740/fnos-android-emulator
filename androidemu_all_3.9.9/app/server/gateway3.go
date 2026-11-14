package main

// 请求主流程 / 守护生命周期 / 状态页 / editcompose

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

func readRespHead(br *bufio.Reader) (int, []string, error) {
	lines, err := readHeadLines(br, 200)
	if err != nil && len(lines) == 0 {
		return 0, nil, err
	}
	if len(lines) == 0 {
		return 0, nil, io.EOF
	}
	parts := strings.Fields(lines[0])
	if len(parts) < 2 {
		return 0, lines, nil
	}
	code, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, lines, nil
	}
	return code, lines, nil
}

// 3.9.9：与穿云投屏 0.4.4 保持同一套判据 —— 按扩展名认定静态资源，不针对某个文件名写死。
// 前端会引用 public 根资源（如 <img src="/logo.svg">、manifest.webmanifest 等），
// 上游后续新增任何根资源都应同样按静态文件处理。
var staticExts = []string{".js", ".mjs", ".css", ".map", ".json", ".woff", ".woff2", ".ttf", ".otf", ".eot",
	".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico", ".webp", ".avif",
	".wasm", ".mp4", ".webm", ".mp3", ".ogg", ".cur", ".webmanifest"}

func hasStaticExt(bare string) bool {
	for _, e := range staticExts {
		if strings.HasSuffix(bare, e) {
			return true
		}
	}
	return false
}

// isRootStatic 判断是否为「根目录下的单个静态文件」（/logo.svg、/manifest.webmanifest 这类）。
// 只认一级路径，避免把 /share/xxx.yyy 这类前端路由误当静态文件而跳过 SPA 回退。
func isRootStatic(bare string) bool {
	if !hasStaticExt(bare) {
		return false
	}
	return strings.Count(strings.TrimSuffix(bare, "/"), "/") == 1
}

var knownPrefixes = []string{"/api/", "/assets/", "/ws/", "/connect_client", "/snapshot", "/upload", "/download", "/favicon", "/audit", "/logs", "/monitor", "/terminal", "/files", "/devices"}

func knownPath(bare string) bool {
	for _, p := range knownPrefixes {
		if strings.HasPrefix(bare, p) {
			return true
		}
	}
	return false
}

func lowerKey(h string) string {
	i := strings.Index(h, ":")
	if i < 0 {
		return ""
	}
	return strings.ToLower(strings.TrimSpace(h[:i]))
}

// rewriteLocation：3xx 跳转的 Location 若是站内绝对路径，补上 /app/androidemu 前缀。
// 不补的话浏览器会跳到 /api/devices/ 这类裸路径，被飞牛 www 接走 → 列表/缩略图全空。
func rewriteLocation(lines []string, rc int) []string {
	if rc < 300 || rc >= 400 {
		return stripHop(lines)
	}
	out := []string{}
	for _, h := range stripHop(lines) {
		if strings.HasPrefix(strings.ToLower(h), "location:") {
			v := strings.TrimSpace(h[len("location:"):])
			if strings.HasPrefix(v, "/") && !strings.HasPrefix(v, "//") &&
				v != PREFIX && !strings.HasPrefix(v, PREFIX+"/") {
				h = "Location: " + PREFIX + v
			}
		}
		out = append(out, h)
	}
	return out
}

func handleRequest(conn net.Conn) {
	uErr := interface{}(nil)
	defer conn.Close()
	// 3.9.9：单个请求内部一旦 panic（畸形报文、对端半关闭、WS 收尾竞态），
	// goroutine 里的 panic 会直接终止整个网关进程 —— 表现就是所有连接同时断、
	// 随后飞牛网关一直 Bad Gateway，而投屏画面（已建立的 WebRTC）照旧在跑。
	// 这里把异常隔离在单个连接内，宁可丢一个连接也不让整进程退出。
	defer func() {
		if r := recover(); r != nil {
			logf("请求处理异常（已隔离，网关继续服务）：%v", r)
		}
	}()
	br := bufio.NewReaderSize(conn, 64*1024)
	reqLines, err := readHeadLines(br, 200)
	uErr = err
	if uErr != nil || len(reqLines) == 0 {
		return
	}
	parts := strings.Fields(reqLines[0])
	if len(parts) < 2 {
		sendErr(conn, 400, "Bad Request")
		return
	}
	method, target := parts[0], parts[1]
	rh := headerMap(reqLines)
	ext := isExternalHost([]byte(rh["host"]))
	if strings.Contains(strings.ToLower(rh["expect"]), "100-continue") {
		conn.Write([]byte("HTTP/1.1 100 Continue\r\n\r\n"))
	}
	_cl := 0
	if v := rh["content-length"]; v != "" {
		_cl, _ = strconv.Atoi(v)
	}
	streaming := _cl > 8*1024*1024
	var body []byte
	if !streaming {
		if strings.Contains(strings.ToLower(rh["transfer-encoding"]), "chunked") {
			body = readChunked(br)
		} else {
			body = readCLBytes(br, int64(_cl))
		}
	}
	path := target
	if strings.HasPrefix(path, PREFIX) {
		path = path[len(PREFIX):]
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	bare := strings.Split(path, "?")[0]

	if method == "OPTIONS" {
		conn.Write([]byte("HTTP/1.1 204 No Content\r\n" +
			"Access-Control-Allow-Origin: *\r\n" +
			"Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS, PATCH\r\n" +
			"Access-Control-Allow-Headers: Authorization, Content-Type, X-Requested-With\r\n" +
			"Access-Control-Max-Age: 86400\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
		return
	}
	// 3.9.9 C1：非管理员不得调用管理接口。
	// 身份只认飞牛统一网关转发的 X-Trim-Isadmin / X-Trim-Userid，与上游账号口令解耦；
	// 本网关只监听 unix socket（见 bindListen），8443 直连不经过这里，由上游登录态把关。
	// 头缺失或不是 true 一律拒绝（默认拒绝），避免未登录/伪造身份拿到管理权限。
	if isAdminAPI(bare) && !strings.EqualFold(strings.TrimSpace(rh["x-trim-isadmin"]), "true") {
		_uid := strings.TrimSpace(rh["x-trim-userid"])
		logf("拒绝非管理员管理接口：%s %s（uid=%s）", method, bare, _uid)
		_b := []byte(`{"code":403,"msg":"Forbidden: administrator required"}`)
		conn.Write([]byte(fmt.Sprintf("HTTP/1.1 403 Forbidden\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", len(_b))))
		conn.Write(_b)
		return
	}
	// 3.9.4：以下三个是网关侧的旁路接口，不经过上游鉴权（上游只校验 Cookie/Bearer）。
	//   /api/health_fix 会重启容器、改 GPU 权限、重启 surfaceflinger；
	//   /stream.mjpg 会持续输出安卓屏幕画面（每 150ms 截一次图）。
	//   原先任何人都能直接请求 IP:8443 上的这三个路径，等于「免鉴权访问 + 未授权写操作 +
	//   屏幕画面泄露」，与提交自检第 2 条「监听端口需自有鉴权，不可免鉴权访问」冲突。
	//   现在统一要求带 Cookie 或 Authorization（浏览器登录态 / 门户会话），裸访问一律 401。
	if bare == "/api/status" || strings.HasPrefix(bare, "/api/health_fix") || bare == "/stream.mjpg" {
		if rh["cookie"] == "" && rh["authorization"] == "" {
			logf("拒绝未鉴权的旁路接口访问：%s（无 Cookie/Authorization）", bare)
			conn.Write([]byte("HTTP/1.1 401 Unauthorized\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 12\r\nConnection: close\r\n\r\nUnauthorized"))
			return
		}
	}
	if bare == "/api/status" {
		b := apiStatus()
		conn.Write([]byte(fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", len(b))))
		conn.Write(b)
		return
	}
	if strings.HasPrefix(bare, "/api/health_fix") {
		action := "restart_container"
		if i := strings.Index(target, "?"); i >= 0 {
			for _, p := range strings.Split(target[i+1:], "&") {
				if strings.HasPrefix(p, "action=") {
					action = p[7:]
				}
			}
		}
		b := apiHealthFix(action)
		conn.Write([]byte(fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", len(b))))
		conn.Write(b)
		return
	}
	if bare == "/stream.mjpg" {
		logf("MJPEG 流请求来自 %s", rh["x-forwarded-for"])
		streamMJPG(conn)
		return
	}
	if method == "GET" && !strings.Contains(target, "gwv=") && strings.Contains(strings.ToLower(rh["accept"]), "text/html") {
		sep := "?"
		if strings.Contains(target, "?") {
			sep = "&"
		}
		loc := target + sep + "gwv=" + VERSION
		logf("强制换页 302 -> %s", loc)
		conn.Write([]byte("HTTP/1.1 302 Found\r\nLocation: " + loc +
			"\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
		return
	}
	if strings.Contains(strings.ToLower(rh["upgrade"]), "websocket") {
		// 3.9.9 C1：把 WebSocket 连接与网关身份上下文关联（审计用，不阻断投屏连接）。
		logf("WebSocket 连接绑定网关身份：uid=%s admin=%s path=%s",
			strings.TrimSpace(rh["x-trim-userid"]), strings.TrimSpace(rh["x-trim-isadmin"]), path)
		handleWS(conn, method, path, reqLines)
		return
	}
	// 3.9.9：根目录静态文件不参与 SPA 回退。
	// 现象（官方反馈 2026-11-09）：面板侧边栏顶部本该显示 logo，实际显示成被裁断的
	// 字母「Clou / Phon」。原因是前端写死 <img src="/logo.svg">，经门户访问时被补成
	// /app/androidemu/logo.svg，而 /logo.svg 不在 knownPrefixes 里 → 走到这里被回退成
	// 首页 HTML → 浏览器把 HTML 当图片 → 裂图后回落到 alt 文本「Cloud Phone Logo」。
	// 与穿云投屏 0.4.4 的修法一致：以静态扩展名结尾的资源一律按静态资源代理上游。
	if method == "GET" && !knownPath(bare) && !isRootStatic(bare) {
		logf("SPA fallback: %s -> /", bare)
		path = "/"
		bare = "/"
	}

	tok := ensureSession()
	override := tok != "" && !containsStr([]string{"/api/login", "/api/register", "/api/auth-status", "/api/logout"}, bare)

	upstreamHeaders := func(withBody bool) (net.Conn, []byte, error) {
		uu, err := dialUpstream()
		if err != nil {
			return nil, nil, err
		}
		uu.SetDeadline(time.Now().Add(180 * time.Second))
		out := []string{fmt.Sprintf("%s %s HTTP/1.1", method, path)}
		hasAuth := false
		for _, h := range stripHop(reqLines[1:]) {
			k := lowerKey(h)
			if k == "accept-encoding" || k == "expect" {
				continue
			}
			if k == "content-length" && !(withBody || streaming) {
				continue
			}
			if k == "authorization" {
				hasAuth = true
				if override {
					continue
				}
			}
			out = append(out, h)
		}
		if override {
			out = append(out, "Authorization: Bearer "+tok)
			verb := "补注入"
			if hasAuth {
				verb = "覆盖客户端授权头为"
			}
			logf("%s服务端会话：%s %s", verb, method, bare)
		}
		if !withBody {
			out = append(out, fmt.Sprintf("Content-Length: %d", len(body)))
		}
		out = append(out, "Accept-Encoding: identity", "Connection: close")
		return uu, []byte(strings.Join(out, "\r\n") + "\r\n\r\n"), nil
	}

	var u net.Conn
	defer func() {
		if u != nil {
			u.Close()
		}
	}()
	sendProxyErr := func(e error) {
		logf("代理异常: %v", e)
		if method == "GET" && !strings.HasPrefix(bare, "/api/") && !strings.HasPrefix(bare, "/assets/") {
			_html := statusPageHTML(e.Error())
			conn.Write([]byte(fmt.Sprintf("HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", len(_html))))
			conn.Write(_html)
		} else {
			sendUpstreamJSON(conn, "proxy_error")
		}
	}
	if streaming {
		uu, hdrs, err := upstreamHeaders(true)
		if err != nil {
			sendProxyErr(err)
			return
		}
		u = uu
		if _, err := u.Write(hdrs); err != nil {
			sendProxyErr(err)
			return
		}
		n, _ := io.CopyN(u, br, int64(_cl))
		logf("流式转发请求体 %d/%d 字节：%s", _cl-int(n), _cl, bare)
	} else {
		uu, hdrs, err := upstreamHeaders(false)
		if err != nil {
			sendProxyErr(err)
			return
		}
		u = uu
		if _, err := u.Write(append(hdrs, body...)); err != nil {
			sendProxyErr(err)
			return
		}
	}
	ubr := bufio.NewReaderSize(u, 64*1024)
	rc, respLines, rerr := readRespHead(ubr)
	// 3.9.2：用户从面板改密码成功后，把新口令记下来，供网关自动登录使用。
	// 只在「上游返回 200 + 非流式（请求体已在内存）+ reset_password 接口」时执行；
	// 任何解析失败都静默跳过，不影响转发结果。
	if rc == 200 && !streaming && method == "POST" && bare == "/api/admin/users/reset_password" {
		captureAdminPassword(body)
	}
	// 3.9.9 C1：管理员改名后同步 gw_admin.conf 的用户名，口令保持不变，
	// 避免「改名 + 升级」时凭据漏同步导致自动登录退回内置默认口令。
	if rc == 200 && !streaming && method == "POST" && bare == "/api/admin/users/rename" {
		captureAdminUsername(body)
	}
	if rc == 401 && override && !streaming {
		logf("上游 401 拒绝服务端会话，重新登录后重试：%s", bare)
		clearSession()
		if tok2 := ensureSession(); tok2 != "" {
			tok = tok2
			u.Close()
			uu, hdrs, err := upstreamHeaders(false)
			if err == nil {
				u = uu
				u.Write(append(hdrs, body...))
				ubr = bufio.NewReaderSize(u, 64*1024)
				rc, respLines, rerr = readRespHead(ubr)
			}
		}
	}
	_ = rerr
	if len(respLines) == 0 {
		logf("上游无响应: %s %s", method, path)
		// 3.9.6：上游一行响应都没有 = 容器内的画面服务还没就绪（启动中 / 正在重启）。
		// 这是暂时的中间状态，但原来直接抛 502「Bad Gateway: empty upstream response」，
		// 用户在门户里看到的就是一个错误弹窗（官方实测复现）。页面请求改为返回等待页，
		// 让用户看到「正在启动，页面会自动刷新」；API 与静态资源仍返回 502 由前端自行处理。
		if method == "GET" && !strings.HasPrefix(bare, "/api/") && !strings.HasPrefix(bare, "/assets/") {
			_hp := statusPageHTML("画面服务正在启动，请稍候…（页面会自动刷新，无需操作）")
			conn.Write([]byte(fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", len(_hp))))
			conn.Write(_hp)
		} else {
			sendUpstreamJSON(conn, "upstream_empty_response")
		}
		return
	}
	resph := headerMap(respLines)
	if rc == 200 && (strings.HasPrefix(bare, "/assets/") || hasStaticExt(bare) || strings.HasPrefix(bare, "/api/")) &&
		strings.Contains(strings.ToLower(resph["content-type"]), "text/html") {
		var code2 int
		var ctype string
		var b2 []byte
		if strings.HasPrefix(bare, "/api/") {
			b2 = []byte(`{"error":"upstream_fallback_html","path":"` + bare + `"}`)
			code2, ctype = 502, "application/json; charset=utf-8"
		} else {
			b2 = nil
			code2, ctype = 404, "application/octet-stream"
		}
		logf("上游把 %s 回退成了 HTML，已纠正为 %d", bare, code2)
		conn.Write([]byte(fmt.Sprintf("HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", code2, ctype, len(b2))))
		conn.Write(b2)
		return
	}
	if rc >= 400 {
		logf("上游 %d: %s %s", rc, method, path)
	}
	ctype := strings.ToLower(resph["content-type"])
	chunked := strings.Contains(strings.ToLower(resph["transfer-encoding"]), "chunked")
	rewrite := strings.Contains(ctype, "text/html") || strings.Contains(ctype, "text/css")
	if rewrite {
		var rbody []byte
		if chunked {
			rbody = readChunked(ubr)
		} else {
			cl := 0
			if v := resph["content-length"]; v != "" {
				cl, _ = strconv.Atoi(v)
			}
			rbody = readCLBytes(ubr, int64(cl))
		}
		rbody = rewriteBody(rbody, ext)
		isHTML := strings.Contains(ctype, "text/html")
		newh := []string{respLines[0]}
		for _, h := range rewriteLocation(respLines[1:], rc) {
			k := lowerKey(h)
			// 3.9.3：改写正文后必须同时丢掉 transfer-encoding —— 上游若用 chunked 返回，
			// 这里已经把正文解块并重算 Content-Length；若还留着 "Transfer-Encoding: chunked"，
			// 同一个响应头里就同时出现 TE:chunked 与 Content-Length，按 RFC 客户端以 TE 为准，
			// 会把「非分块正文」当分块解析 → 页面白屏/脚本被截断（与 opencode 上踩过的
			// 「分块响应必须自己给 Content-Length」是同一类问题）。
			if k == "content-length" || k == "content-encoding" || k == "transfer-encoding" {
				continue
			}
			if isHTML && (k == "cache-control" || k == "expires" || k == "pragma" || k == "etag" || k == "last-modified") {
				continue
			}
			newh = append(newh, h)
		}
		newh = append(newh, fmt.Sprintf("Content-Length: %d", len(rbody)))
		newh = append(newh, corsLines...)
		if isHTML {
			newh = append(newh, "Cache-Control: no-store, no-cache, must-revalidate", "Pragma: no-cache")
		}
		newh = append(newh, "Connection: close")
		conn.Write([]byte(strings.Join(newh, "\r\n") + "\r\n\r\n"))
		conn.Write(rbody)
		return
	}
	newh := append([]string{respLines[0]}, rewriteLocation(respLines[1:], rc)...)
	newh = append(newh, corsLines...)
	newh = append(newh, "Connection: close")
	conn.Write([]byte(strings.Join(newh, "\r\n") + "\r\n\r\n"))
	if chunked {
		for {
			line, err := ubr.ReadString('\n')
			if err != nil || line == "" {
				break
			}
			conn.Write([]byte(line))
			s := strings.TrimSpace(line)
			if s == "" {
				continue
			}
			n, err := strconv.ParseInt(strings.Split(s, ";")[0], 16, 64)
			if err != nil {
				break
			}
			if n == 0 {
				conn.Write([]byte("\r\n"))
				break
			}
			io.CopyN(conn, ubr, n)
			ubr.Read(make([]byte, 2))
		}
	} else {
		left := 0
		if v := resph["content-length"]; v != "" {
			left, _ = strconv.Atoi(v)
		}
		if left > 0 {
			io.CopyN(conn, ubr, int64(left))
		} else {
			io.Copy(conn, ubr)
		}
	}
}

// ---------------------------------------------------------------- serve / 守护

// isAdminAPI — 需要飞牛管理员身份才能调用的上游接口（0.4.4 实际路由）。
// 只覆盖管理与高风险写操作：用户/授权/审计/租约、PVE、激活、分享管理。
// 普通浏览、设备列表、连接投屏、/api/me、/api/version、/api/login 等一律不受影响，
// 避免拦到前端初始化与投屏主流程。
func isAdminAPI(bare string) bool {
	switch {
	case bare == "/api/admin", strings.HasPrefix(bare, "/api/admin/"):
		return true
	case strings.HasPrefix(bare, "/api/pve/"):
		return true
	case bare == "/api/activate":
		return true
	case bare == "/api/share/create", bare == "/api/share/revoke",
		bare == "/api/share/extend", bare == "/api/share/update":
		return true
	}
	return false
}

func bindListen() (net.Listener, error) {
	os.Remove(SOCK_PATH)
	srv, err := net.Listen("unix", SOCK_PATH)
	if err != nil {
		return nil, err
	}
	os.Chmod(SOCK_PATH, 0o666)
	return srv, nil
}

var srvMu sync.Mutex
var srvListener net.Listener
var srvAlive bool

// srvSockIno 记录本进程监听 fd 对应的 app.sock inode。
// 只靠 probeOnce() 判断健康是不够的：若另一个守护把 app.sock 删掉重绑，
// 本进程的 probeOnce() 会连到「别人的 socket」并拿到 200，于是误判自己健康、
// 永不重建入口，飞牛网关就一直在跟一个无名 inode 说话 —— 表现即 Bad Gateway。
var srvSockIno uint64

func statIno(st os.FileInfo) uint64 {
	if st == nil {
		return 0
	}
	if s, ok := st.Sys().(*syscall.Stat_t); ok {
		return s.Ino
	}
	return 0
}

func serverAlive() bool {
	srvMu.Lock()
	defer srvMu.Unlock()
	return srvAlive
}

func startServerThread() bool {
	loadConf()
	srvMu.Lock()
	defer srvMu.Unlock()
	l, err := bindListen()
	if err != nil {
		logf("代理监听失败：%v", err)
		return false
	}
	srvListener = l
	srvAlive = true
	// 记下本次绑定后 app.sock 的 inode，用于后续判断「这个入口还是不是我的」。
	srvSockIno = 0
	if st, err := os.Stat(SOCK_PATH); err == nil {
		srvSockIno = statIno(st)
	}
	os.WriteFile(CHILD_PID, []byte(strconv.Itoa(os.Getpid())), 0644)
	os.WriteFile(VER_FILE, []byte(VERSION), 0644)
	logf("代理已监听 %s -> %s:%d tls=%s prefix=%s 版本=%s（守护进程内 goroutine）",
		SOCK_PATH, UPSTREAM_HOST, UPSTREAM_PORT, tlsStr(USE_TLS), PREFIX, VERSION)
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				srvMu.Lock()
				srvAlive = false
				srvMu.Unlock()
				return
			}
			go handleRequest(conn)
		}
	}()
	return true
}

func translationCrashWatcher() {
	flagFile := VAR_DIR + "/translation_crash.flag"
	failedFlag := VAR_DIR + "/translation_houdini_failed.flag"
	composePath := APP_DEST + "/docker/docker-compose.yaml"
	// 当前是否挂在 houdini（compose 里有 houdini 挂载即为 houdini 翻译层）
	onHoudini := func() bool {
		b, err := os.ReadFile(composePath)
		return err == nil && strings.Contains(string(b), "translation/houdini")
	}
	var lastAction time.Time
	for {
		time.Sleep(30 * time.Second)
		// 关键：native 崩溃（SIGILL/SIGSEGV）记录在 crash 缓冲区，只读 main 缓冲区会漏检，
		// 导致「翻译层崩溃自动切换」的看护永远不触发（实测飞牛 App 在模拟器内闪退漏检）。
		out, _ := outOf(exec.Command(bin("docker"), "exec", "androidemu-android", "logcat", "-d", "-b", "crash,main", "-t", "200"))
		crashed := strings.Contains(out, "Undefined instruction") || strings.Contains(out, "SIGILL") ||
			(strings.Contains(out, "ndk_translation") && strings.Contains(out, "Undefined"))
		if !crashed {
			continue
		}
		// 策略（3.9.1，用户要求）：
		//   1) 默认谷歌翻译层（ndk），崩溃时才切 Intel houdini；
		//   2) houdini 也救不了 → 回退 ndk 并写 failed 标记，永久停止自动切换（不横跳）；
		//   3) 用户可手动 rm failed 标记重新启用自动切换。
		if _, err := os.Stat(failedFlag); err == nil {
			continue
		}
		if time.Since(lastAction) < 600*time.Second {
			continue
		}
		lastAction = time.Now()
		if envOr("ANDROIDEMU_TRANSLATION", "auto") != "auto" {
			continue
		}
		if onHoudini() {
			os.WriteFile(failedFlag, []byte("houdini 仍崩溃，回退谷歌翻译层 at "+time.Now().Format("2006-01-02 15:04:05")+"\n"), 0644)
			os.Remove(flagFile)
			logf("翻译层：切换到 houdini 后仍崩溃 → 已回退谷歌翻译层（ndk），并停止自动切换（rm " + failedFlag + " 可重新启用）")
		} else {
			os.MkdirAll(filepath.Dir(flagFile), 0755)
			os.WriteFile(flagFile, []byte("translation_crash detected at "+time.Now().Format("2006-01-02 15:04:05")+"\n"), 0644)
			logf("翻译层：检测到 ARM 翻译崩溃 → 自动切换到 Intel houdini（谷歌翻译层不支持该应用的指令集）")
		}
		// 注意：挂载变更必须 force-recreate，restart 不会重新应用卷挂载
		exec.Command(bin("bash"), "-c",
			"cd "+APP_DEST+"/docker && bash ../scripts/tune_compose.sh docker-compose.yaml && docker compose -p androidemu up -d --force-recreate redroid").Run()
	}
}

func tlsStr(b bool) string {
	if b {
		return "TLS"
	}
	return "明文"
}

func serve() {
	loadConf()
	l, err := bindListen()
	if err != nil {
		logf("代理监听失败：%v", err)
		os.Exit(1)
	}
	os.WriteFile(CHILD_PID, []byte(strconv.Itoa(os.Getpid())), 0644)
	os.WriteFile(VER_FILE, []byte(VERSION), 0644)
	logf("代理已监听 %s -> %s:%d tls=%s prefix=%s 版本=%s",
		SOCK_PATH, UPSTREAM_HOST, UPSTREAM_PORT, tlsStr(USE_TLS), PREFIX, VERSION)
	go translationCrashWatcher()
	for {
		conn, err := l.Accept()
		if err != nil {
			continue
		}
		go handleRequest(conn)
	}
}

// ---------------------------------------------------------------- 降权与守护

func containsInt(list []int, v int) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func supervise() {
	dropPrivileges()
	// 单实例锁。3.9.9 修复（实测 2026-11-14）：gateway.lock 由包用户创建后权限 0644，
	// 以另一个用户（安装回调的系统身份、或登录用户）再起守护时 os.OpenFile 直接 EACCES，
	// 而旧代码是「打不开锁就静默继续」——于是同机并存两个守护，双方不断
	// os.Remove(SOCK_PATH) + 重绑，抢同一个入口，表现就是页面间歇 502 Bad Gateway，
	// 而投屏画面完全正常（媒体走 WebRTC，不经过这个 socket），极易误判成飞牛的问题。
	// 现在：锁打不开时用「同路径网关进程扫描」兜底判重，绝不静默放行。
	lock, lerr := os.OpenFile(LOCK_FILE, os.O_CREATE|os.O_RDWR, 0666)
	if lerr == nil {
		if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			logf("已有网关守护在运行（锁被占用），本进程退出以避免互掐")
			os.Exit(0)
		}
	} else {
		logf("单实例锁不可用（%v）→ 改用同路径进程扫描判重", lerr)
		time.Sleep(300 * time.Millisecond)
		if others := ourPids(); len(others) > 0 {
			logf("已有同路径网关守护 %v 在运行，本进程退出（避免两个守护抢 app.sock）", others)
			os.Exit(0)
		}
	}
	os.WriteFile(PID_FILE, []byte(strconv.Itoa(os.Getpid())), 0644)
	var varIno uint64
	if st, err := os.Stat(VAR_DIR); err == nil {
		if s, ok := st.Sys().(*syscall.Stat_t); ok {
			varIno = s.Ino
		}
	}
	// 3.9.9：把实际 PATH 与 docker 解析结果写进日志。历史故障（容器在跑、
	// 状态页却一直显示「正在安装中」）就是 PATH 缺 /usr/bin 导致网关拿不到 docker，
	// 有这一行就能一眼看出是环境问题还是容器问题。
	logf("守护启动 pid=%d 版本=%s 检查间隔 %ds（PATH=%s，docker=%s）", os.Getpid(), VERSION, INTERVAL, os.Getenv("PATH"), bin("docker"))
	if !startServerThread() {
		logf("守护启动后代理未能监听，将在循环内重试")
	}
	go translationCrashWatcher()
	lastAudio := time.Time{}
	for {
		time.Sleep(time.Duration(INTERVAL) * time.Second)
		var curIno uint64
		if st, err := os.Stat(VAR_DIR); err == nil {
			if s, ok := st.Sys().(*syscall.Stat_t); ok {
				curIno = s.Ino
			}
		}
		if varIno != 0 && curIno != varIno {
			logf("数据目录已不存在或已被替换（应用已卸载/重装），本守护退出")
			os.Exit(0)
		}
		sweep(os.Getpid())
		// 入口归属校验（3.9.9）：app.sock 若被别的守护删掉重绑、或被外部删除，本进程的
		// probeOnce() 会因为连到「别人的 socket」而返回 200，从而误判健康、永不重建入口，
		// 飞牛侧就持续 Bad Gateway。比对 inode 才能识别这种「入口已不属于我」的状态。
		srvMu.Lock()
		_sockIno := srvSockIno
		srvMu.Unlock()
		if _sockIno != 0 {
			_st2, _e2 := os.Stat(SOCK_PATH)
			if _e2 != nil || statIno(_st2) != _sockIno {
				if others := ourPids(); len(others) > 0 {
					logf("app.sock 已被另一个网关守护接管（同路径守护 %v）→ 本进程退出，避免互抢入口", others)
					os.Exit(0)
				}
				logf("app.sock 已被删除或替换（入口丢失）→ 重新绑定")
				srvMu.Lock()
				if srvListener != nil {
					srvListener.Close()
				}
				srvAlive = false
				srvMu.Unlock()
				startServerThread()
			}
		}
		// 健康信号必须是「实际可连接」：只判断 socket 文件存在会被「上一实例被杀后留下的
		// 死 socket 文件」骗过 —— 表现就是飞牛网关 Bad Gateway（实测事故）。
		healthy := serverAlive() && fileExists(SOCK_PATH) && verOK() && probeOnce()
		if !healthy {
			srvMu.Lock()
			if srvListener != nil {
				srvListener.Close()
			}
			srvAlive = false
			srvMu.Unlock()
			startServerThread()
			time.Sleep(1 * time.Second)
			if probeOnce() {
				logf("校验通过：%s 可服务（%s/）", SOCK_PATH, PREFIX)
			} else {
				logf("警告：%s 尚不可服务，下一轮重试（详见 %s）", SOCK_PATH, LOG_FILE)
			}
		}
		daemonSh := filepath.Join(APP_DEST, "scripts", "androidemu_daemon.sh")
		if fileExists(daemonSh) && !audioWatchdogOK() {
			if time.Since(lastAudio) > 60*time.Second {
				lastAudio = time.Now()
				cmd := exec.Command(bin("bash"), daemonSh, "start")
				cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
				cmd.Dir = "/"
				if err := cmd.Start(); err == nil {
					go cmd.Wait()
					logf("统一守护进程未在运行，已尝试拉起（音频+分辨率）")
				} else {
					logf("统一守护进程拉起失败：%v", err)
				}
			}
		}
	}
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func verOK() bool {
	b, err := os.ReadFile(VER_FILE)
	return err == nil && strings.TrimSpace(string(b)) == VERSION
}

func probeOnce() bool {
	c, err := net.DialTimeout("unix", SOCK_PATH, 8*time.Second)
	if err != nil {
		return false
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(8 * time.Second))
	fmt.Fprintf(c, "GET %s/?gwv=%s HTTP/1.1\r\nHost: localhost\r\nAccept: text/html\r\nConnection: close\r\n\r\n", PREFIX, VERSION)
	buf := make([]byte, 64)
	n, err := c.Read(buf)
	if err != nil || n == 0 {
		return false
	}
	if !bytes.HasPrefix(buf[:n], []byte("HTTP/")) {
		return false
	}
	parts := strings.Fields(string(buf[:n]))
	if len(parts) < 2 {
		return false
	}
	code, err := strconv.Atoi(parts[1])
	if err != nil {
		return false
	}
	return code >= 200 && code < 400
}

// ---------------------------------------------------------------- start/stop/status

func selfPath() string {
	p, err := os.Executable()
	if err != nil {
		return ""
	}
	if rp, err := filepath.EvalSymlinks(p); err == nil {
		return rp
	}
	return p
}

// daemonStillCurrent：守护进程的可执行文件是否就是本程序（同路径）。
func daemonStillCurrent(pid int) bool {
	cmd := pidCmdline(pid)
	toks := strings.Fields(cmd)
	if len(toks) == 0 {
		return true
	}
	exe := toks[0]
	if strings.HasPrefix(exe, "python3") || strings.HasPrefix(exe, "python") {
		return false // 上一版 Python 网关，必须替换
	}
	me := selfPath()
	if me == "" {
		return true
	}
	return exe == me
}

func start() int {
	loadConf()
	d := daemonPID()
	// 只有「守护在 + 版本对 + 真的能连上 + 跑的是本目录的可执行文件」才算运行中。
	// 最后一条用于升级：旧版本目录里的守护即使还能服务，也必须让位给新目录的实例，
	// 否则 fnOS 升级后会继续用旧二进制（实测出现过新旧守护互杀 + 死 socket）。
	if d != 0 && daemonStillCurrent(d) && verOK() && fileExists(SOCK_PATH) && probeOnce() {
		var extra []int
		for _, p := range ourPids() {
			if p != d {
				extra = append(extra, p)
			}
		}
		if len(extra) == 0 {
			fmt.Printf("gateway: 运行中（守护 %d，代理随守护同进程，版本 %s），无需重启\n", d, VERSION)
			return 0
		}
		logf("发现残留网关进程：%v（清理后保持当前入口不中断）", extra)
		sweep(d)
		fmt.Printf("gateway: 运行中（守护 %d，版本 %s），已清理上一版残留进程\n", d, VERSION)
		return 0
	}
	if d != 0 {
		killPID(d, 1.5)
	}
	sweep()
	for _, p := range []string{PID_FILE, CHILD_PID, VER_FILE} {
		os.Remove(p)
	}
	sp := selfPath()
	if sp == "" {
		fmt.Println("gateway: 无法定位自身可执行文件，守护启动失败")
		return 1
	}
	logfOpen, _ := os.OpenFile(LOG_FILE, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	cmd := exec.Command(sp, "supervise")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Dir = "/"
	cmd.Stdout = logfOpen
	cmd.Stderr = logfOpen
	if err := cmd.Start(); err != nil {
		fmt.Printf("gateway: 守护启动失败：%v（可改用 scripts/gw_socket.sh start 兜底）\n", err)
		return 1
	}
	go cmd.Wait()
	for i := 0; i < 16; i++ {
		time.Sleep(500 * time.Millisecond)
		if probeOnce() && daemonPID() != 0 {
			break
		}
	}
	if fileExists(SOCK_PATH) && daemonPID() != 0 && probeOnce() {
		tls := "明文"
		if USE_TLS {
			tls = "TLS"
		}
		fmt.Printf("gateway: 网关入口就绪：%s → 127.0.0.1:%d（上游 %s，前缀 %s，版本 %s）\n",
			SOCK_PATH, UPSTREAM_PORT, tls, PREFIX, VERSION)
		return 0
	}
	// 3.9.9：区分「入口没建出来」和「入口有了、上游还没应答」。
	// probeOnce() 要求 2xx~3xx，上游（画面服务）尚在启动时会拿到 502，于是这里
	// 曾打出「入口尚未就绪」并返回 1 —— 实测（2026-11-14 群友机器）命令跑完 5 秒后
	// app.sock 已是 200，纯属误报，反而让人以为没修好。只要守护在、socket 能连上，
	// 入口就是可用的；上游就绪与否由状态页体现，不该算启动失败。
	if fileExists(SOCK_PATH) && daemonPID() != 0 {
		if c, err := net.DialTimeout("unix", SOCK_PATH, 3*time.Second); err == nil {
			c.Close()
			fmt.Printf("gateway: 网关入口已就绪：%s（上游 127.0.0.1:%d 暂未应答，待画面服务启动后自动恢复）\n",
				SOCK_PATH, UPSTREAM_PORT)
			return 0
		}
	}
	fmt.Printf("gateway: 已启动守护但入口尚未就绪（详见 %s）\n", LOG_FILE)
	return 1
}

func stop() int {
	killed := []string{}
	for i := 0; i < 2; i++ {
		d := daemonPID()
		if d == 0 {
			break
		}
		killPID(d, 1.5)
		killed = append(killed, strconv.Itoa(d))
		time.Sleep(300 * time.Millisecond)
	}
	sweep()
	for _, p := range []string{PID_FILE, CHILD_PID, VER_FILE, SOCK_PATH} {
		os.Remove(p)
	}
	logf("守护与代理已停止（%s）", strings.Join(killed, " "))
	fmt.Println("gateway: 已停止")
	return 0
}

func status() int {
	d := daemonPID()
	dstr := "not running"
	if d != 0 {
		dstr = fmt.Sprintf("running (pid %d)", d)
	}
	fmt.Printf("守护: %s\n", dstr)
	if d != 0 {
		fmt.Printf("代理: running（与守护同进程 pid %d）\n", d)
	} else {
		fmt.Println("代理: not running")
	}
	sock := "未就绪"
	if fileExists(SOCK_PATH) {
		sock = "就绪"
	}
	fmt.Printf("socket: %s (%s)\n", sock, SOCK_PATH)
	v := "-"
	if b, err := os.ReadFile(VER_FILE); err == nil {
		v = strings.TrimSpace(string(b))
	}
	tls := "明文 HTTP"
	if USE_TLS {
		tls = "TLS（自签证书不校验）"
	}
	fmt.Printf("版本: %s（本程序 %s）\n", v, VERSION)
	fmt.Printf("上游: 127.0.0.1:%d（%s），路径前缀 %s\n", UPSTREAM_PORT, tls, PREFIX)
	var others []string
	for _, p := range ourPids() {
		if p != d {
			others = append(others, strconv.Itoa(p))
		}
	}
	if len(others) > 0 {
		fmt.Printf("本应用网关进程: 守护 %d（代理同进程）；上一版残留 %s（可执行 restart 清理）\n", d, strings.Join(others, " "))
	} else {
		fmt.Printf("本应用网关进程: 守护 %s（代理同进程）\n", dstr)
	}
	return 0
}
