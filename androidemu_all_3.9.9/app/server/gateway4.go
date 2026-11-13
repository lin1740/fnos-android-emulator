package main

// 状态页模板 / main 入口 / 降权辅助 / editcompose

import (
	"bufio"
	"fmt"
	"os"
	"os/user"
	"strconv"
	"strings"
	"syscall"
)

// ---------------------------------------------------------------- 降权辅助

func userLookup(name string) (*user.User, error) {
	return user.Lookup(name)
}

func supplementalGroups(userName string) []int {
	out := []int{}
	f, err := os.Open("/etc/group")
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		parts := strings.Split(sc.Text(), ":")
		if len(parts) < 4 {
			continue
		}
		gid, err := strconv.Atoi(strings.TrimSpace(parts[2]))
		if err != nil {
			continue
		}
		for _, m := range strings.Split(parts[3], ",") {
			if strings.TrimSpace(m) == userName {
				out = append(out, gid)
				break
			}
		}
	}
	return out
}

// ---------------------------------------------------------------- 音频守护看护

func audioWatchdogOK() bool {
	return audioWatchdogPID() != 0
}

func audioWatchdogPID() int {
	pid := readPID(vfile("audio_watchdog.pid"))
	if pid != 0 && isMine(pid) && strings.Contains(pidCmdline(pid), "androidemu_daemon") {
		return pid
	}
	me := os.Getpid()
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return 0
	}
	for _, e := range ents {
		if !isDigitDir(e.Name()) {
			continue
		}
		p, _ := strconv.Atoi(e.Name())
		if p == me || !isMine(p) {
			continue
		}
		cmd := pidCmdline(p)
		if !strings.Contains(cmd, "androidemu_daemon") || !matchesSelfPrefix(cmd) {
			continue
		}
		return p
	}
	return 0
}

// ---------------------------------------------------------------- 降权

func dropPrivileges() {
	if os.Getuid() != 0 {
		return
	}
	target := ""
	for _, name := range []string{"docker-androidemu", "trim"} {
		if _, err := userLookup(name); err == nil {
			target = name
			break
		}
	}
	if target == "" {
		logf("降权跳过：未找到 docker-androidemu 或 trim 用户")
		return
	}
	u, _ := userLookup(target)
	uid, _ := strconv.Atoi(u.Uid)
	gid, _ := strconv.Atoi(u.Gid)
	extra := supplementalGroups(target)
	if !containsInt(extra, gid) {
		extra = append(extra, gid)
	}
	syscall.Setgroups(extra)
	syscall.Setgid(gid)
	syscall.Setuid(uid)
	os.Setenv("HOME", u.HomeDir)
	os.Setenv("USER", target)
	logf("已降权到用户 %s (uid=%d, gid=%d)", target, uid, gid)
}

// ---------------------------------------------------------------- 状态页模板

const statusTemplate = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>androidemu - 状态</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#f5f7fa;margin:0;padding:40px 20px;color:#333}
.card{max-width:600px;margin:0 auto;background:#fff;border-radius:12px;box-shadow:0 2px 12px rgba(0,0,0,0.08);padding:32px}
h1{font-size:22px;margin:0 0 8px;color:#1a1a1a}
.stage{display:inline-block;padding:4px 12px;border-radius:20px;font-size:13px;font-weight:500;margin-bottom:16px}
.stage-installing{background:#fff3cd;color:#856404}
.stage-booting{background:#d1ecf1;color:#0c5460}
.stage-error{background:#f8d7da;color:#721c24}
.stage-ok{background:#d4edda;color:#155724}
p{line-height:1.6;color:#555;margin:8px 0}
table{width:100%;border-collapse:collapse;margin:16px 0;font-size:14px}
th,td{text-align:left;padding:8px 12px;border-bottom:1px solid #eee}
th{background:#f8f9fa;font-weight:600}
.tips{background:#f8f9fa;border-radius:8px;padding:16px;margin-top:20px}
.tips h3{font-size:15px;margin:0 0 8px;color:#333}
.tips ul{margin:0;padding-left:20px;color:#666;font-size:13px;line-height:1.8}
code{background:#e9ecef;padding:2px 6px;border-radius:4px;font-size:13px}
.btn{display:inline-block;margin-top:16px;padding:10px 24px;background:#4a90d9;color:#fff;text-decoration:none;border-radius:6px;font-size:14px}
.btn:hover{background:#357abd}
.error{background:#f8d7da;color:#721c24;padding:12px;border-radius:6px;margin:12px 0;font-size:13px}
/* 3.9.5：安装/启动阶段的中性提示（蓝色），避免把「正在准备」渲染成故障红 */
.notice{background:#e7f1ff;color:#0b4f8a;padding:12px;border-radius:6px;margin:12px 0;font-size:13px}
</style>
</head>
<body>
<div class="card">
<h1>androidemu 安卓模拟器</h1>
<div class="stage stage-{{STAGE}}">{{TITLE}}</div>
<p>{{DESC}}</p>
{{ERR}}
<h3 style="font-size:15px;margin:20px 0 8px">容器状态</h3>
<table>
<tr><th>容器名</th><th>状态</th></tr>
{{ROWS}}
</table>
<p style="font-size:12px;color:#999;margin:6px 0">网关上游：{{UPSTREAM}}</p>
<h3 style="font-size:15px;margin:20px 0 8px">健康状态</h3>
<div id="health-status" class="tips" style="margin-top:0">
<p style="margin:0">正在检测...</p>
</div>
<div id="health-actions" style="margin-top:12px;display:none">
<button onclick="fixAction('restart_webrtc')" style="padding:8px 16px;margin-right:8px;border:1px solid #d9534f;background:#fff;color:#d9534f;border-radius:6px;cursor:pointer">重启投屏服务</button>
<button onclick="fixAction('fix_gpu')" style="padding:8px 16px;margin-right:8px;border:1px solid #4a90d9;background:#fff;color:#4a90d9;border-radius:6px;cursor:pointer">修复GPU/画面</button>
<button onclick="fixAction('restart_container')" style="padding:8px 16px;margin-right:8px;border:1px solid #f0ad4e;background:#fff;color:#f0ad4e;border-radius:6px;cursor:pointer">重启安卓容器</button>
<button onclick="fixAction('restart_surfaceflinger')" style="padding:8px 16px;border:1px solid #999;background:#fff;color:#666;border-radius:6px;cursor:pointer">重启安卓画面合成</button>
</div>
<script>
function fixAction(a){
  if(!confirm("确定执行"+a+"？"))return;
  fetch("/app/androidemu/api/health_fix?action="+a).then(r=>r.json()).then(d=>{
    alert(d.message);
    if(d.ok)setTimeout(()=>location.reload(),3000);
  });
}
fetch("/app/androidemu/api/status").then(r=>r.json()).then(d=>{
  var h=d.health||{};
  var el=document.getElementById("health-status");
  var actions=document.getElementById("health-actions");
  var statusMap={
    "healthy":["运行正常","#d4edda","#155724"],
    "booting":["启动中","#d1ecf1","#0c5460"],
    "boot_timeout":["启动超时","#fff3cd","#856404"],
    "oom_killed":["内存不足被杀死","#f8d7da","#721c24"],
    "surfaceflinger_dead":["画面服务异常","#f8d7da","#721c24"],
    /* 3.9.9：容器在跑、安卓也启动了，但投屏端口没应答 —— 原来这里会显示「运行正常」，
       与页面顶部的「画面服务未响应」自相矛盾，用户不知道该干什么 */
    "webrtc_down":["投屏服务无响应","#f8d7da","#721c24"],
    /* 3.9.5：安装后容器还没起来是正常过程，改中性色；真正异常（OOM/画面服务）仍是红 */
    "not_running":["容器未运行（等待启动）","#e7f1ff","#0b4f8a"],
    "unknown":["未知","#eee","#666"]
  };
  var s=statusMap[h.status]||statusMap["unknown"];
  var uptime=h.uptime_seconds?Math.floor(h.uptime_seconds/60)+"分钟":"";
  el.innerHTML="<p style=\"margin:0\"><b>状态：</b><span style=\"color:"+s[2]+"\">"+s[0]+"</span></p>"
    +"<p style=\"margin:4px 0\"><b>详情：</b>"+(h.detail||"")+"</p>"
    +"<p style=\"margin:4px 0\"><b>运行时长：</b>"+(uptime||"未知")+" | <b>boot完成：</b>"+(h.boot_completed?"是":"否")
    +" | <b>OOM：</b>"+(h.oom_killed?"是":"否")+" | <b>画面服务：</b>"+(h.surfaceflinger_running?"运行中":"未运行")
    +" | <b>投屏端口：</b>"+(h.web_ok?"可访问":"无响应")+"</p>";
  if(h.status!=="healthy"&&h.status!=="booting"&&h.status!=="not_running"){
    actions.style.display="block";
  }
  // 页面本身处于「画面服务未响应」时，探活可能有瞬时差异，这里再兜一次：
  // 只要代理连不上上游，就把修复按钮摆出来，别让用户对着红框干瞪眼。
  var _ps=document.getElementById("page-stage");
  if(_ps&&_ps.getAttribute("data-stage")==="upstream_down"){actions.style.display="block";}
});
// 3.9.9：异常阶段自动刷新（10 秒一次，最多 30 次 ≈ 5 分钟），正常进面板后不再刷。
(function(){
  if("{{AUTO}}"!=="1")return;
  try{
    var k="ae_auto_refresh",n=parseInt(sessionStorage.getItem(k)||"0",10)||0;
    if(n>=30){sessionStorage.removeItem(k);return;}
    sessionStorage.setItem(k,String(n+1));
  }catch(e){}
  setTimeout(function(){location.reload();},10000);
})();
</script>
<div id="page-stage" data-stage="{{STAGE}}" style="display:none"></div>
<div class="tips">
<h3>常见问题排查</h3>
<ul>
<li><b>首次安装慢</b>：需拉取约 2GB 镜像，取决于网速，通常 1-5 分钟。</li>
<li><b>容器在跑但开不了机</b>：<code>docker logs androidemu-android</code> 为空是正常的（为省性能关闭了串口控制台）；开机守护会把诊断写进 <code>/var/apps/androidemu/var/boot_diag.status</code>（含真实 logcat 证据）。若判定为 GPU 直通失败，守护会自动回退软件渲染并重建容器。</li>
<li><b>调整端口</b>：升级不会再改端口；如需调整，执行 <code>bash /var/apps/androidemu/target/scripts/set_ports.sh --show</code> 查看当前端口，<code>--web 9443 --turn 3478 --adb 5556</code> 修改（容器内监听端口固定，改的是对外映射用的端口，改完请在路由器/穿透工具同步）。</li>
<li><b>内核 binder 支持</b>：本应用依赖应用中心的应用「binder_linux」（未安装/未启用时，应用中心会阻止安装并在详情页提示）；装好并启用后安卓容器才能启动。</li>
<li><b>内存不足</b>：建议 2GB 以上可用内存，低于 1GB 容器会被系统杀死。</li>
<li><b>查看日志</b>：SSH 登录 NAS 执行 <code>cat /var/apps/androidemu/var/install.log</code></li>
<li><b>仍无法解决</b>：在应用中心「停用」→ 等待 10 秒 →「启用」，或在飞牛论坛反馈。</li>
</ul>
</div>
<a href="javascript:location.reload()" class="btn">刷新页面</a>
<a href="javascript:window.open(location.href,'_blank')" class="btn">在新窗口打开</a>
<div class="tips">提示：画面按全屏应用设计，建议点窗口右上角 □ 最大化使用；小窗口下部分内容可能无法滚动。点「刷新页面」进入画面后如遇到此情况，请用「在新窗口打开」或最大化窗口。</div>
</div>
</body>
</html>`

// ---------------------------------------------------------------- editcompose

// 结构化编辑本应用 compose（缩进块级，足够覆盖 services 下的标量/列表/environment）
// 用法：editcompose <file> <op> args...
//
//	set-scalar <service> <key> <value>
//	set-env    <service> <KEY> <VALUE>    （VALUE 为 "-" 时删除该项）
//	set-image  <service> <value>
//	add-item   <service> <key> <value>    （如 devices 列表，幂等）
//	del-item   <service> <key> <value>
func editCompose(args []string) (rc int) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Println("editcompose 参数错误:", r)
			rc = 1
		}
	}()
	if len(args) < 3 {
		fmt.Println("用法：editcompose <file> <op> [args...]")
		return 1
	}
	file, op := args[0], args[1]
	data, err := os.ReadFile(file)
	if err != nil {
		fmt.Println("读取失败:", err)
		return 1
	}
	lines := strings.Split(string(data), "\n")

	// 定位服务块 [start, end)
	svcLine := "  " + args[2] + ":"
	start, end := -1, -1
	for i, l := range lines {
		if l == svcLine {
			start = i
			continue
		}
		if start >= 0 && i > start && l != "" && !strings.HasPrefix(l, "    ") {
			end = i
			break
		}
	}
	if start < 0 {
		fmt.Println("未找到服务:", args[2])
		return 1
	}
	if end < 0 {
		end = len(lines)
	}

	// 在服务块内定位 key（缩进 4），并返回其列表项范围 [itemStart, itemEnd)
	// 列表项 = 紧随 key 行之后、缩进 6 的 "- xxx" 连续行（遇到其它行即止）
	findKey := func(seg []string, key string) (keyIdx, itemStart, itemEnd int) {
		keyIdx = -1
		for i, l := range seg {
			if strings.HasPrefix(l, "    "+key+":") {
				keyIdx = i
				break
			}
		}
		if keyIdx < 0 {
			return -1, -1, -1
		}
		j := keyIdx + 1
		for j < len(seg) && strings.HasPrefix(seg[j], "      - ") {
			j++
		}
		return keyIdx, keyIdx + 1, j
	}

	writeSeg := func(seg []string) {
		newLines := append(append(append([]string{}, lines[:start]...), seg...), lines[end:]...)
		lines = newLines
	}

	switch op {
	case "set-scalar", "set-image":
		key, val := args[3], args[4]
		if op == "set-image" {
			key = "image"
		}
		seg := append([]string{}, lines[start:end]...)
		ki, _, _ := findKey(seg, key)
		if ki >= 0 {
			seg[ki] = "    " + key + ": " + val
		} else {
			seg = append(seg[:1], append([]string{"    " + key + ": " + val}, seg[1:]...)...)
		}
		writeSeg(seg)

	case "set-env":
		// 兼容 set-env svc KEY VALUE 与 set-env svc KEY=VALUE
		key, val := args[3], "-"
		if len(args) > 4 {
			val = args[4]
		}
		if i := strings.Index(key, "="); i >= 0 {
			val = key[i+1:]
			key = key[:i]
		}
		if key == "" {
			fmt.Println("set-env：键为空")
			return 1
		}
		seg := append([]string{}, lines[start:end]...)
		ki, is, ie := findKey(seg, "environment")
		if ki < 0 {
			if val == "-" {
				return 0
			}
			seg = append(seg[:1], append([]string{"    environment:", "      - " + key + "=" + val}, seg[1:]...)...)
			writeSeg(seg)
			return 0
		}
		// 只在 environment 自己的列表项里找
		var keep []string
		found := false
		for _, it := range seg[is:ie] {
			name := strings.TrimPrefix(it, "      - ")
			if strings.HasPrefix(name, key+"=") || name == key {
				found = true
				if val != "-" {
					keep = append(keep, "      - "+key+"="+val)
				}
				continue
			}
			keep = append(keep, it)
		}
		if !found && val != "-" {
			keep = append(keep, "      - "+key+"="+val)
		}
		head := append([]string{}, seg[:ki]...)
		tail := append([]string{}, seg[ie:]...)
		// environment 行 + 新列表；空列表写成 environment: []
		head = append(head, "    environment:")
		if len(keep) == 0 {
			head[len(head)-1] = "    environment: []"
		}
		seg = append(append(head, keep...), tail...)
		writeSeg(seg)

	case "add-item", "del-item":
		key, val := args[3], args[4]
		seg := append([]string{}, lines[start:end]...)
		ki, is, ie := findKey(seg, key)
		if op == "add-item" {
			if ki < 0 {
				seg = append(seg[:1], append([]string{"    " + key + ":", "      - " + val}, seg[1:]...)...)
				writeSeg(seg)
				return 0
			}
			for _, it := range seg[is:ie] {
				if strings.TrimPrefix(it, "      - ") == val {
					return 0 // 幂等
				}
			}
			seg = append(seg[:ie], append([]string{"      - " + val}, seg[ie:]...)...)
			writeSeg(seg)
			return 0
		}
		if ki < 0 {
			return 0
		}
		var keep []string
		for _, it := range seg[is:ie] {
			if strings.TrimPrefix(it, "      - ") != val {
				keep = append(keep, it)
			}
		}
		head := append([]string{}, seg[:ki]...)
		tail := append([]string{}, seg[ie:]...)
		if len(keep) == 0 {
			head = append(head, "    "+key+": []")
		} else {
			head = append(head, seg[ki])
			head = append(head, keep...)
		}
		seg = append(head, tail...)
		writeSeg(seg)

	default:
		fmt.Println("未知 op:", op)
		return 1
	}
	// 安全阀：服务块内不允许出现重复的键（历史事故：environment 被重复定义导致
	// docker compose 直接解析失败、应用报「docker 不可用」）。发现重复即回滚。
	seg := lines[start:len(lines)]
	if end2 := findServiceEnd(lines, start); end2 > start {
		seg = lines[start:end2]
	}
	seen := map[string]bool{}
	for _, l := range seg {
		if len(l) > 4 && strings.HasPrefix(l, "    ") && !strings.HasPrefix(l, "      ") {
			k := strings.TrimSpace(l)
			if i := strings.Index(k, ":"); i > 0 {
				k = k[:i]
				if seen[k] {
					fmt.Println("editcompose 拒绝写入：服务内出现重复键", k)
					return 1
				}
				seen[k] = true
			}
		}
	}
	os.WriteFile(file, []byte(strings.Join(lines, "\n")), 0644)
	return 0
}

// findServiceEnd 返回从 start 起的服务块结束行（遇到非 4 空格缩进的行）
func findServiceEnd(lines []string, start int) int {
	for i := start + 1; i < len(lines); i++ {
		l := lines[i]
		if l != "" && !strings.HasPrefix(l, "    ") {
			return i
		}
	}
	return len(lines)
}

// ---------------------------------------------------------------- main

func main() {
	action := "serve"
	if len(os.Args) > 1 {
		action = os.Args[1]
	}
	ADMIN_USER, ADMIN_PASS = adminCreds()
	switch action {
	case "serve":
		serve()
	case "supervise":
		supervise()
	case "start":
		os.Exit(start())
	case "stop":
		os.Exit(stop())
	case "restart":
		stop()
		os.Exit(start())
	case "status":
		loadConf()
		os.Exit(status())
	case "probe":
		if probeOnce() {
			fmt.Printf("gateway: 探活通过（%s 可服务 %s/）\n", SOCK_PATH, PREFIX)
			os.Exit(0)
		}
		fmt.Printf("gateway: 探活失败（详见 %s）\n", LOG_FILE)
		os.Exit(1)
	case "editcompose":
		if len(os.Args) < 3 {
			fmt.Println("用法：gateway editcompose <file> <op> [args...]")
			os.Exit(1)
		}
		os.Exit(editCompose(os.Args[2:]))
	default:
		fmt.Printf("用法：%s {serve|start|stop|restart|status|supervise|probe|editcompose}\n", os.Args[0])
		os.Exit(1)
	}
}
