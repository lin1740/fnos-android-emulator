// androidemu 3.9.1 gateway（Go 实现，行为对齐 gateway.py）
//
// 子命令：serve | start | stop | restart | status | supervise | probe | editcompose
//   serve      前台运行代理（内部）
//   start      确保守护+代理在跑（健康则不动，避免掐断在线会话）
//   stop       停止守护+代理并清理 socket
//   restart    stop + start
//   status     打印守护/代理/socket/版本/上游
//   supervise  守护循环（内部）：flock 互斥、VAR_DIR 变更自退、自愈重监听、
//              清理本应用上一版网关残留、看护音频守护
//   probe      通过 socket 探活一次
//   editcompose 结构化编辑 compose（供 tune_resources/net_mode/set_ports 调用）
//
// 启动器（cmd/main、gw_socket.sh）使用本二进制（Go 版为唯一网关实现；uninstall 流程
// 对上一版遗留的 gateway.py 仅做停止清理）。
package main

import (
	"bufio"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const VERSION = "3.9.9"

var (
	APP_DEST      = envOr("TRIM_APPDEST", "/var/apps/androidemu/target")
	VAR_DIR       = envOr("TRIM_PKGVAR", "/var/apps/androidemu/var")
	SOCK_PATH     = filepath.Join(APP_DEST, "app.sock")
	PREFIX        = "/app/androidemu"
	UPSTREAM_HOST = "127.0.0.1"
	UPSTREAM_PORT = 8443
	USE_TLS       = true
	INTERVAL      = envInt("GW_CHECK_INTERVAL", 20)
	WS_PING       = envInt("GW_WS_PING", 10)

	PID_FILE   = vfile("gateway.pid")
	CHILD_PID  = vfile("gateway_child.pid")
	VER_FILE   = vfile("gateway.ver")
	LOCK_FILE  = vfile("gateway.lock")
	LOG_FILE   = vfile("gateway.log")
	STATUS_FILE= vfile("gw_status")
	ADMIN_CONF = vfile("gw_admin.conf")

	ADMIN_USER = "admin"
	ADMIN_PASS = "admin123"
)

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func envInt(k string, d int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return d
}
func vfile(name string) string { return filepath.Join(VAR_DIR, name) }

var PB = []byte(PREFIX)

var logMu sync.Mutex

func logf(format string, a ...interface{}) {
	logMu.Lock()
	defer logMu.Unlock()
	f, err := os.OpenFile(LOG_FILE, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	fmt.Fprintf(f, "[%s] %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, a...))
	f.Close()
}

func gwStatusWrite(ok bool, msg string) {
	v := "0"
	if ok {
		v = "1"
	}
	content := fmt.Sprintf("OK=%s\nMSG=%s\nTS=%d\n", v, msg, time.Now().Unix())
	_ = os.WriteFile(STATUS_FILE, []byte(content), 0644)
}

// ---------------------------------------------------------------- 进程工具

func pidCmdline(pid int) string {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return ""
	}
	return strings.ReplaceAll(string(b), "\x00", " ")
}

func pidAlive(pid int) bool {
	return syscall.Kill(pid, 0) == nil
}

func pidUID(pid int) (int, bool) {
	st, err := os.Stat(fmt.Sprintf("/proc/%d", pid))
	if err != nil {
		return -1, false
	}
	if st, ok := st.Sys().(*syscall.Stat_t); ok {
		return int(st.Uid), true
	}
	return -1, false
}

func isMine(pid int) bool {
	uid, ok := pidUID(pid)
	return ok && uid == os.Getuid()
}

func readPID(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || !pidAlive(n) {
		return 0
	}
	return n
}

func killPID(pid int, wait float64) bool {
	if pid <= 0 {
		return true
	}
	if !isMine(pid) && os.Getuid() != 0 {
		logf("跳过非本用户进程 pid=%d（无权限结束）", pid)
		return false
	}
	syscall.Kill(pid, syscall.SIGTERM)
	deadline := time.Now().Add(time.Duration(wait * float64(time.Second)))
	for time.Now().Before(deadline) {
		if !pidAlive(pid) {
			return true
		}
		time.Sleep(100 * time.Millisecond)
	}
	syscall.Kill(pid, syscall.SIGKILL)
	return true
}

func selfPrefixes() []string {
	name := filepath.Base(strings.TrimRight(APP_DEST, "/"))
	if name == "target" {
		name = filepath.Base(filepath.Dir(strings.TrimRight(APP_DEST, "/")))
	}
	out := []string{APP_DEST, VAR_DIR,
		"/var/apps/" + name + "/target", "/var/apps/" + name + "/var"}
	for _, p := range []string{APP_DEST, VAR_DIR} {
		if rp, err := filepath.EvalSymlinks(p); err == nil && rp != "" {
			found := false
			for _, x := range out {
				if x == rp {
					found = true
					break
				}
			}
			if !found {
				out = append(out, rp)
			}
		}
	}
	return out
}

var SELF_PREFIXES = selfPrefixes()

// ourPids 列出本应用、本用户的常驻网关进程（含上一版 gateway.py / 2.x 遗留）。
func ourPids() []int {
	out := []int{}
	me := os.Getpid()
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return out
	}
	for _, e := range ents {
		if !isDigitDir(e.Name()) {
			continue
		}
		pid, _ := strconv.Atoi(e.Name())
		if pid == me {
			continue
		}
		cmd := pidCmdline(pid)
		if cmd == "" || !matchesSelfPrefix(cmd) {
			continue
		}
		toks := strings.Fields(cmd)
		role := false
		if strings.Contains(cmd, "gw_relay.py") {
			role = true
		} else if isGatewayCmd(toks) {
			// 3.9.1 修复：只按「网关可执行文件/脚本」识别本应用网关进程。
			// 旧判据「末位参数是 serve|supervise 就算网关」会把 boot_guard.sh supervise、
			// agent_autodeploy 等其它守护误判成残留并被 sweep 杀掉（ARM 实测命中）。
			role = true
		} else if strings.Contains(cmd, "gw_socket.sh") && containsStr(toks, "supervise") {
			role = true
		}
		if role && isMine(pid) {
			out = append(out, pid)
		}
	}
	return out
}

// isGatewayCmd：命令行里是否直接引用了网关可执行文件/脚本（gateway_amd64|arm64、
// gateway.py、gw_relay.py）。用于区分「本应用网关进程」与其它守护（boot_guard、
// agent_autodeploy 等末位也可能是 supervise，不能仅凭末位参数判断）。
func isGatewayCmd(toks []string) bool {
	for _, t := range toks {
		switch filepath.Base(t) {
		case "gateway_amd64", "gateway_arm64", "gateway.py", "gw_relay.py":
			return true
		}
	}
	return false
}

func isDigitDir(name string) bool {
	for _, c := range name {
		if c < '0' || c > '9' {
			return false
		}
	}
	return len(name) > 0
}

func containsStr(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func matchesSelfPrefix(cmd string) bool {
	for _, p := range SELF_PREFIXES {
		if p != "" && strings.Contains(cmd, p) {
			return true
		}
	}
	return false
}

// daemonPID：PID 文件 + cmdline 身份 + 角色校验（最后一个参数必须是 supervise）
func daemonPID() int {
	pid := readPID(PID_FILE)
	if pid == 0 || !isMine(pid) {
		return 0
	}
	cmd := pidCmdline(pid)
	if !matchesSelfPrefix(cmd) {
		return 0
	}
	if !strings.Contains(cmd, "gateway") {
		return 0
	}
	toks := strings.Fields(cmd)
	if len(toks) > 0 && toks[len(toks)-1] == "supervise" {
		return pid
	}
	return 0
}

func sweep(keep ...int) {
	killed := []string{}
	for _, pid := range ourPids() {
		skip := false
		for _, k := range keep {
			if pid == k {
				skip = true
				break
			}
		}
		if skip {
			continue
		}
		if killPID(pid, 1.5) {
			killed = append(killed, strconv.Itoa(pid))
		}
	}
	if len(killed) > 0 {
		logf("已清理本应用网关残留进程：%s", strings.Join(killed, " "))
	}
}

// ---------------------------------------------------------------- 上游参数与会话

func loadConf() {
	if b, err := os.ReadFile(filepath.Join(VAR_DIR, "ports.conf")); err == nil {
		if m := regexp.MustCompile(`(?m)^WEB_PORT=(\d+)`).FindSubmatch(b); m != nil {
			if n, err := strconv.Atoi(string(m[1])); err == nil {
				UPSTREAM_PORT = n
			}
		}
	}
	if b, err := os.ReadFile(filepath.Join(APP_DEST, "docker", "docker-compose.yaml")); err == nil {
		// 关键：只认 environment 列表里的真实配置行，不能全文搜 "USE_TLS=false" ——
		// 实测 compose 的注释里就有这句话（历史说明文字），会把 TLS 模式误判成明文，
		// 表现为 8443 开了 HTTPS 后网关仍用明文连上游 → 400。
		if regexp.MustCompile(`(?m)^\s*-\s*USE_TLS:\s*false\b`).Match(b) ||
			regexp.MustCompile(`(?m)^\s*-\s*USE_TLS=\s*false\b`).Match(b) ||
			regexp.MustCompile(`(?m)^\s*USE_TLS:\s*false\b`).Match(b) {
			USE_TLS = false
		}
	}
}

func adminCreds() (string, string) {
	user := envOr("GW_ADMIN_USER", "admin")
	pwd := envOr("GW_ADMIN_PASS", "admin123")
	if line, err := readFirstLine(ADMIN_CONF); err == nil && strings.Contains(line, ":") {
		parts := strings.SplitN(line, ":", 2)
		if parts[0] != "" {
			user = parts[0]
		}
		if len(parts) > 1 && parts[1] != "" {
			pwd = parts[1]
		}
	}
	return user, pwd
}

func readFirstLine(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	if sc.Scan() {
		return strings.TrimSpace(sc.Text()), nil
	}
	return "", io.EOF
}

var sessionMu sync.Mutex
var sessionJS []byte
var sessionTS time.Time
var sessionToken string

// ---------------------------------------------------------------- 上游协议自适应
//
// 背景（实测故障）：升级/重启场景下，compose 里写的 USE_TLS 与实际运行的 webrtc
// 容器协议可能不一致 —— 例如配置已改成 USE_TLS=false（明文），但 webrtc 容器
// 因未重建仍是 TLS 模式。此时网关按配置用明文去连 TLS 端口，握手失败，
// 用户看到的就是「每次更新后 Bad Gateway」。
//
// 处理原则：以实际探测为准，配置只作兜底。探测结果缓存 30 秒，
// 本地回环的一次 TCP+TLS 握手开销在毫秒级，不影响请求性能。

var (
	protoMu     sync.Mutex
	protoIsTLS  = -1 // -1 未探测；0 明文；1 TLS
	protoStamps time.Time
)

// 连不上上游时返回配置值（由调用方按连接错误处理）。
// probeUpstreamTLS 三态探测：1=明确 TLS，0=明确明文，-1=不确定。
// 3.9.7：原实现把「TLS 握手失败」直接等价于「上游是 HTTP」。但容器刚起、
// 端口已监听而 TLS 尚未初始化、或瞬时超时都会握手失败 —— 误判成明文后
// 结果还被缓存 30 秒，这期间网关全用明文打 TLS 端口，上游回
// 「Client sent an HTTP request to an HTTPS server.」（实测事故）。
// 现在必须「明文请求确实拿到合法 HTTP 响应」才判明文；其余一律不确定。
func probeUpstreamTLS() int {
	addr := fmt.Sprintf("%s:%d", UPSTREAM_HOST, UPSTREAM_PORT)
	raw, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		return -1
	}
	c := tls.Client(raw, &tls.Config{InsecureSkipVerify: true, ServerName: "localhost"})
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	if c.Handshake() == nil {
		c.Close()
		return 1
	}
	raw.Close()

	raw2, err2 := net.DialTimeout("tcp", addr, 3*time.Second)
	if err2 != nil {
		return -1
	}
	defer raw2.Close()
	_ = raw2.SetDeadline(time.Now().Add(3 * time.Second))
	_, _ = io.WriteString(raw2, "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
	buf := make([]byte, 256)
	n, _ := raw2.Read(buf)
	head := string(buf[:n])
	// TLS 端口收到明文时会回 400 + 这句固定文本，不能据此当成明文服务
	if strings.HasPrefix(head, "HTTP/") &&
		!strings.Contains(head, "Client sent an HTTP request to an HTTPS server") {
		return 0
	}
	return -1
}

func protoName(t bool) string {
	if t {
		return "HTTPS"
	}
	return "HTTP"
}

// upstreamTLS 返回应当使用的协议（30 秒内复用探测结果）。
func upstreamTLS() bool {
	protoMu.Lock()
	defer protoMu.Unlock()
	if protoIsTLS >= 0 && time.Since(protoStamps) < 30*time.Second {
		return protoIsTLS == 1
	}
	v := probeUpstreamTLS()
	if v < 0 {
		// 探测不明确（容器启动中/瞬时失败）：不写缓存，按配置兜底，下次请求继续探。
		// 绝不把「握手失败」当成明文，也绝不缓存一个猜测值。
		return USE_TLS
	}
	if (v == 1) != USE_TLS {
		logf("上游协议修正：配置=%s 实际=%s（升级后容器未重建时常见）→ 按实际连接",
			protoName(USE_TLS), protoName(v == 1))
	}
	protoIsTLS = v
	protoStamps = time.Now()
	return v == 1
}

func dialUpstream() (net.Conn, error) {
	addr := fmt.Sprintf("%s:%d", UPSTREAM_HOST, UPSTREAM_PORT)
	useTLS := upstreamTLS()
	raw, err := net.DialTimeout("tcp", addr, 20*time.Second)
	if err != nil {
		return nil, err
	}
	if !useTLS {
		return raw, nil
	}
	c := tls.Client(raw, &tls.Config{InsecureSkipVerify: true, ServerName: "localhost"})
	if herr := c.Handshake(); herr != nil {
		raw.Close()
		// 探测为 TLS 但握手失败：上游可能刚切换协议，作废缓存供下次重探
		protoMu.Lock()
		protoIsTLS = -1
		protoMu.Unlock()
		return nil, herr
	}
	return c, nil
}

// captureAdminPassword — 用户从面板修改密码成功后，把新口令记到 gw_admin.conf。
//
// 为什么需要：网关自动登录必须知道当前口令。以前只认内置默认口令，用户一改密码，
// 自动登录恒 401（表现「bad gateway」），只能靠 fix_webrtc_auth.sh 重置回默认——
// 那等于把用户改的密码又抹掉了，不符合「用户改的密码要继续可用」。
//
// 只处理 POST /api/admin/users/reset_password 且上游返回 200 的情况；用户名必须是
// 当前管理员，其它用户的密码变动不记录。解析失败一律静默跳过，绝不影响正常转发。
func captureAdminPassword(body []byte) {
	if len(body) == 0 || len(body) > 8192 {
		return
	}
	var m map[string]interface{}
	if err := json.Unmarshal(body, &m); err != nil {
		return
	}
	user, _ := m["username"].(string)
	pass, _ := m["password"].(string)
	if user == "" || pass == "" {
		return
	}
	curUser, _ := adminCreds()
	if user != curUser {
		return
	}
	tmp := ADMIN_CONF + ".tmp"
	if err := os.WriteFile(tmp, []byte(user+":"+pass+"\n"), 0600); err != nil {
		logf("记录新口令失败（写临时文件）：%v", err)
		return
	}
	if err := os.Rename(tmp, ADMIN_CONF); err != nil {
		logf("记录新口令失败（重命名）：%v", err)
		os.Remove(tmp)
		return
	}
	logf("已记住画面服务新口令（用户在面板修改密码），后续自动登录将使用新口令")
}

// captureAdminUsername — 管理员重命名后同步 gw_admin.conf 里的用户名。
// 0.4.4 的 /api/admin/users/rename 请求体使用 old_username / new_username。
// 只在 gw_admin.conf 已存在、且 old_username 与当前记录一致时更新用户名，
// 口令部分原样保留；任何解析失败都静默跳过，绝不影响正常转发。
// 这样「改名 + 改密」都不会因为漏同步而让自动登录退回内置默认口令。
func captureAdminUsername(body []byte) {
	if len(body) == 0 || len(body) > 8192 {
		return
	}
	var m map[string]interface{}
	if err := json.Unmarshal(body, &m); err != nil {
		return
	}
	old, _ := m["old_username"].(string)
	nw, _ := m["new_username"].(string)
	if old == "" || nw == "" || old == nw {
		return
	}
	if _, err := os.Stat(ADMIN_CONF); err != nil {
		logf("检测到管理员改名（%s → %s），但 gw_admin.conf 不存在，跳过同步；请手动写入 新用户名:当前口令", old, nw)
		return
	}
	curUser, curPass := adminCreds()
	if old != curUser {
		return
	}
	tmp := ADMIN_CONF + ".tmp"
	if err := os.WriteFile(tmp, []byte(nw+":"+curPass+"\n"), 0600); err != nil {
		logf("记录新用户名失败（写临时文件）：%v", err)
		return
	}
	if err := os.Rename(tmp, ADMIN_CONF); err != nil {
		logf("记录新用户名失败（重命名）：%v", err)
		os.Remove(tmp)
		return
	}
	logf("已同步画面服务管理员用户名（%s → %s），口令保持不变", old, nw)
}

func loginUpstream() []byte {
	// 3.9.2 修正：原来这里直接拼 ADMIN_USER/ADMIN_PASS 常量，导致 adminCreds() 白写了 ——
	// 用户在 var/gw_admin.conf 里写的新口令完全不生效，改完密码必然 401（页面 bad gateway）。
	// 现在统一走 adminCreds()：gw_admin.conf > 环境变量 > 内置默认。
	_loginUser, _loginPass := adminCreds()
	body, _ := json.Marshal(map[string]string{"username": _loginUser, "password": _loginPass})
	u, err := dialUpstream()
	if err != nil {
		logf("网关自动登录连接失败：%v", err)
		gwStatusWrite(false, "自动登录失败：无法连接上游 "+err.Error())
		return nil
	}
	defer u.Close()
	u.SetDeadline(time.Now().Add(15 * time.Second))
	req := fmt.Sprintf("POST /api/login HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		len(body), string(body))
	if _, err := u.Write([]byte(req)); err != nil {
		return nil
	}
	ubr := bufio.NewReader(u)
	code, hs, err := readRespHead(ubr)
	if err != nil || code != 200 {
		c := 0
		if err == nil {
			c = code
		}
		logf("网关自动登录失败：上游返回 %d", c)
		gwStatusWrite(false, fmt.Sprintf("自动登录失败：上游 /api/login 返回 %d（若已修改画面服务密码，请在应用数据目录写入 gw_admin.conf，格式 用户名:密码，然后重开页面）", c))
		return nil
	}
	cl := 0
	for _, h := range hs {
		if strings.HasPrefix(strings.ToLower(h), "content-length:") {
			if n, e := strconv.Atoi(strings.TrimSpace(strings.SplitN(h, ":", 2)[1])); e == nil {
				cl = n
			}
		}
	}
	bodyResp := readCLBytes(ubr, int64(cl))
	var d map[string]interface{}
	if err := json.Unmarshal(bodyResp, &d); err != nil {
		logf("自动登录响应解析失败：%v", err)
		gwStatusWrite(false, fmt.Sprintf("自动登录响应解析失败：%v", err))
		return nil
	}
	tok, _ := d["token"].(string)
	if tok == "" {
		gwStatusWrite(false, "自动登录未取到 token（上游登录接口响应异常）")
		return nil
	}
	// 注意：这里保持「原始字符串」，JSON 转义只在下面 Sprintf 时做一次。
	// 历史 bug：uname/role 先 jsonStr 再 jsonStr → 写入 localStorage 的值变成带引号的
	// "\"admin\""，SPA 校验 auth_role 失败 → 整页不渲染（黑屏）。
	uname := ifaceStr(d["username"])
	if uname == "" {
		uname = ADMIN_USER
	}
	role := ifaceStr(d["role"])
	if role == "" {
		role = "admin"
	}
	// assigned_devices 需要写成「JSON 字符串」形式：localStorage 里存的是 ["*"] 这段文本，
	// 因此先取 JSON 文本，再由 jsonStr 做一次字符串转义。
	devs := marshalDefault(d["assigned_devices"], []string{"*"})
	js := fmt.Sprintf(`(function(){try{if(location.pathname.indexOf("/app/androidemu")!==0)return;`+
		`if(sessionStorage.getItem("gw_logout")==="1")return;`+
		`var T=%s;`+
		`if(localStorage.getItem("auth_token")!==T||localStorage.getItem("auth_role")!=="admin"){`+
		`localStorage.setItem("auth_token",T);localStorage.setItem("auth_user",%s);`+
		`localStorage.setItem("auth_role",%s);localStorage.setItem("auth_devices",%s);}`+
		`if(!sessionStorage.getItem("gw_heal")){`+
		`fetch("/app/androidemu/api/me",{headers:{Authorization:"Bearer "+(localStorage.getItem("auth_token")||"")},cache:"no-store"})`+
		`.then(function(r){if(r&&r.status===401){sessionStorage.setItem("gw_heal","1");`+
		`try{["auth_token","auth_user","auth_role","auth_devices"].forEach(function(k){localStorage.removeItem(k)})}catch(e){}`+
		`location.reload();}}).catch(function(){});}`+
		`}catch(e){}})();`,
		jsonStr(tok, ""), jsonStr(uname, ADMIN_USER), jsonStr(role, "admin"), jsonStr(devs, "[\"*\"]"))
	sessionToken = tok
	gwStatusWrite(true, fmt.Sprintf("自动登录成功（用户 %s）", uname))
	logf("网关自动登录成功：用户=%s 角色=%s", uname, role)
	return []byte(js)
}

func ifaceStr(v interface{}) string {
	s, _ := v.(string)
	return s
}

// jsonStr 输出与 Python json.dumps 一致的 JSON 字符串字面量
func jsonStr(s, def string) string {
	if s == "" {
		s = def
	}
	b, _ := json.Marshal(s)
	return string(b)
}

func marshalDefault(v interface{}, def interface{}) string {
	if v == nil {
		b, _ := json.Marshal(def)
		return string(b)
	}
	b, err := json.Marshal(v)
	if err != nil {
		b, _ = json.Marshal(def)
	}
	return string(b)
}

func ensureSession() string {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	if len(sessionJS) == 0 || time.Since(sessionTS) > 1800*time.Second {
		if nw := loginUpstream(); nw != nil {
			sessionJS = nw
			sessionTS = time.Now()
		}
	}
	return sessionToken
}

func clearSession() {
	sessionMu.Lock()
	sessionJS = nil
	sessionToken = ""
	sessionTS = time.Time{}
	sessionMu.Unlock()
}

// ---------------------------------------------------------------- 请求改写

var assetRe = regexp.MustCompile(`(["'])((?:/app/androidemu)?/?assets/[A-Za-z0-9_\.\-/]+\.(?:js|css|woff2|woff|ttf|png|jpe?g|gif|svg|json|map))(\?)?`)
var routeRe = regexp.MustCompile(`href="/(dashboard|files|terminal|admin|settings|devices|deploy|login|audit|share|monitor|logs)([^"]*)"`)

func versionAssets(body []byte) []byte {
	return assetRe.ReplaceAllFunc(body, func(m []byte) []byte {
		sub := assetRe.FindSubmatch(m)
		if sub == nil {
			return m
		}
		if len(sub[3]) > 0 { // 已带 ? 参数
			return m
		}
		out := append([]byte{}, sub[1]...)
		out = append(out, sub[2]...)
		out = append(out, []byte("?v="+VERSION)...)
		return out
	})
}

func rewriteBody(body []byte, external bool) []byte {
	if bytesContains(body, []byte("<head")) && !bytesContains(body, []byte("gw_logout")) {
		js := append([]byte{}, RUNTIME_SHIM...)
		// 3.9.9：面板的 WebCodecs（硬解）实测花屏，统一钉死为软件解码（video/wasm）。
		js = append(js, DECODE_SOFT_JS...)
		// 3.9.3：面板 JS 用绝对路径 fetch("/api/...")，经门户访问时会绕过网关打到
		// 飞牛 www 根路径 → 设备列表为空。这里在页面最早期拦截并补前缀。
		js = append(js, API_PREFIX_JS...)
		sjs := sessionJSSafe()
		if len(sjs) > 0 {
			js = append(js, sjs...)
		} else {
			js = append(js, FALLBACK_HEAL_JS...)
		}
		js = append(js, GW_LOGOUT_JS...)
		js = append(js, NAV_FIX_JS...)
		if external {
			js = append(js, EXTERNAL_HELPER_JS...)
		}
		// 3.9.6：撤销 3.9.5 注入的自适应 CSS —— 它对上游 Vue 应用的全屏布局（height:100vh）
		// 强制改成 100% 后父级高度不传递，导致整页塌陷成白屏（官方实测反馈）。上游页面
		// 在小窗口里的裁切问题改用「最大化窗口」提示解决，不再改页面样式。
		inject := append(append([]byte("<base href=\""+PREFIX+"/\">"), []byte("<script>")...), js...)
		inject = append(inject, []byte("</script>")...)
		body = replaceFirstHead(body, inject)
	}
	for _, p := range STR_PATHS {
		body = prefixPathRe(body, []byte(p))
	}
	body = locHostRe.ReplaceAll(body, []byte("//${location.host}"+PREFIX))
	body = routeRe.ReplaceAll(body, []byte("href=\""+PREFIX+"/$1$2\""))
	body = versionAssets(body)
	return body
}

var headRe = regexp.MustCompile(`<head[^>]*>`)
var locHostRe = regexp.MustCompile(`//\$\{location\.host\}(/app/androidemu)?`)

func replaceFirstHead(body, inject []byte) []byte {
	loc := headRe.FindIndex(body)
	if loc == nil {
		return body
	}
	out := make([]byte, 0, len(body)+len(inject))
	out = append(out, body[:loc[1]]...)
	out = append(out, inject...)
	out = append(out, body[loc[1]:]...)
	return out
}

func sessionJSSafe() []byte {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	if len(sessionJS) == 0 {
		return nil
	}
	out := make([]byte, len(sessionJS))
	copy(out, sessionJS)
	return out
}

// prefixPathRe：把 "..." /path 前面加 PB，除非已写成 androidemu/path（对齐 Python 的负向后顾）
func prefixPathRe(body, path []byte) []byte {
	re := regexp.MustCompile(`(androidemu)?(["'])` + regexp.QuoteMeta(string(path)))
	return re.ReplaceAllFunc(body, func(m []byte) []byte {
		sub := re.FindSubmatch(m)
		if sub == nil {
			return m
		}
		if len(sub[1]) > 0 { // 已带前缀
			return m
		}
		out := append([]byte{}, sub[2]...)
		out = append(out, PB...)
		out = append(out, path...)
		return out
	})
}

func isExternalHost(host []byte) bool {
	h := strings.ToLower(strings.TrimSpace(string(host)))
	if h == "" {
		return false
	}
	if strings.HasPrefix(h, "[") {
		if i := strings.Index(h, "]"); i > 0 {
			h = h[1:i]
		}
	} else if i := strings.Index(h, ":"); i >= 0 {
		h = h[:i]
	}
	if h == "localhost" || h == "127.0.0.1" || h == "::1" || strings.HasSuffix(h, ".local") {
		return false
	}
	if strings.HasPrefix(h, "10.") || strings.HasPrefix(h, "192.168.") || strings.HasPrefix(h, "127.") {
		return false
	}
	if strings.HasPrefix(h, "172.") {
		parts := strings.Split(h, ".")
		if len(parts) > 1 {
			if n, err := strconv.Atoi(parts[1]); err == nil && n >= 16 && n <= 31 {
				return false
			}
		}
	}
	return true
}

func subToken(path, tok string) string {
	if strings.Contains(path, "token=") {
		return regexp.MustCompile(`token=[^&]*`).ReplaceAllString(path, "token="+tok)
	}
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	return path + sep + "token=" + tok
}
