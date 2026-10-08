//go:build !windows

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/xjasonlyu/tun2socks/v2/dialer"
	core "github.com/y38501148-max/v6only/core"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

const lib = "/usr/local/lib/v6only"
const database = "/var/db/v6only/traffic.sqlite"

type Request struct {
	Action string `json:"action"`
	From   int64  `json:"from"`
	To     int64  `json:"to"`
	URL    string `json:"url"`
}

var operation sync.Mutex
var client = &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}}

func command(args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 70*time.Second)
	defer cancel()
	b, e := exec.CommandContext(ctx, args[0], args[1:]...).CombinedOutput()
	return string(b), e
}
func localJSON(path string) any {
	res, e := client.Get("http://127.0.0.1:17890" + path)
	if e != nil {
		return nil
	}
	defer res.Body.Close()
	var v any
	json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&v)
	return v
}
func tail(path string, n int) string {
	f, e := os.Open(path)
	if e != nil {
		return ""
	}
	defer f.Close()
	info, e := f.Stat()
	if e != nil {
		return ""
	}
	if info.Size() > 32768 {
		f.Seek(-32768, io.SeekEnd)
	}
	b, _ := io.ReadAll(io.LimitReader(f, 32768))
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
func status() any {
	h := localJSON("/health")
	_, suspended := os.Stat("/var/run/v6only.suspend")
	_, marked := os.Stat("/var/run/v6only.active")
	watch, _ := command("/bin/launchctl", "print", "system/edu.buaa.v6only-watch")
	valid := false
	if h != nil && marked == nil {
		_, e := command("/bin/bash", lib+"/v6ctl.sh", "status")
		valid = e == nil
	}
	proxy, _ := command("/usr/sbin/networksetup", "-getwebproxy", "Wi-Fi")
	secure, _ := command("/usr/sbin/networksetup", "-getsecurewebproxy", "Wi-Fi")
	ipv6, _ := command("/sbin/ifconfig", "en0", "inet6")
	logs := "控制器：\n" + tail("/var/log/v6only.log", 16) + "\n\n转发核心：\n" + tail("/var/db/v6only/core.log", 24)
	pac, _ := command("/usr/sbin/networksetup", "-getautoproxyurl", "Wi-Fi")
	socks, _ := command("/usr/sbin/networksetup", "-getsocksfirewallproxy", "Wi-Fi")
	return map[string]any{"installed": true, "enabled": valid, "suspended": suspended == nil, "health": h, "watcher_running": strings.Contains(watch, "state = running"), "ipv6_interface": ipv6, "proxy": proxy + secure + socks, "pac": pac, "flows": localJSON("/flows"), "logs": logs, "policy": "ipv6-only-unless-no-aaaa", "version": "2.1.3"}
}
func diagnose(raw string) any {
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, e := url.Parse(raw)
	if e != nil || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil {
		return map[string]any{"error": "请输入有效的 HTTP/HTTPS 地址"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	r := core.New(core.Config{ChatGPTProxy: "127.0.0.1:7890", DNS: []string{"202.112.128.50", "202.112.128.51"}, IPv6DNS: []string{"2400:3200::1", "2400:3200:baba::1", "223.5.5.5", "223.6.6.6"}, Interface: "en0"}, nil)
	defer r.Close()
	i, e := net.InterfaceByName("en0")
	if e != nil {
		return map[string]any{"error": e.Error()}
	}
	opts := &dialer.Options{InterfaceName: i.Name, InterfaceIndex: i.Index}
	r.DialOverride = func(ctx context.Context, n, a string) (net.Conn, error) {
		return dialer.DefaultDialer.DialContextWithOptions(ctx, n, a, opts)
	}
	started := time.Now()
	resolved, e := r.Resolve(ctx, u.Hostname())
	v6 := []string{}
	v4 := []string{}
	for _, ip := range resolved.V6 {
		v6 = append(v6, ip.String())
	}
	for _, ip := range resolved.V4 {
		v4 = append(v4, ip.String())
	}
	result := map[string]any{"url": raw, "aaaa": v6, "a": v4, "flows": []core.Flow{}, "http_status": 0, "policy": "ipv6-only-unless-no-aaaa"}
	if e == nil {
		c := &http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{Proxy: nil, DialContext: func(ctx context.Context, n, a string) (net.Conn, error) {
			h, p, e := net.SplitHostPort(a)
			if e != nil {
				return nil, e
			}
			return r.Dial(ctx, h, p)
		}}}
		req, _ := http.NewRequestWithContext(ctx, "HEAD", raw, nil)
		var res *http.Response
		res, e = c.Do(req)
		if e == nil {
			result["http_status"] = res.StatusCode
			res.Body.Close()
		}
	}
	result["duration_ms"] = time.Since(started).Milliseconds()
	result["flows"] = r.Flows("")
	if e != nil {
		result["error"] = e.Error()
	} else {
		result["error"] = ""
	}
	return result
}
func handle(q Request) (any, error) {
	switch q.Action {
	case "status":
		return status(), nil
	case "enable", "disable":
		operation.Lock()
		defer operation.Unlock()
		arg := "on"
		if q.Action == "disable" {
			arg = "off"
		}
		out, e := command("/bin/bash", lib+"/v6ctl.sh", arg)
		if log, e2 := os.OpenFile("/var/log/v6only.log", os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644); e2 == nil {
			fmt.Fprintf(log, "%s desktop %s: %s\n", time.Now().Format(time.RFC3339), q.Action, out)
			log.Close()
		}
		if e != nil {
			return nil, fmt.Errorf("%s: %w", out, e)
		}
		return map[string]any{"message": out, "status": status()}, nil
	case "stats":
		if q.To == 0 {
			q.To = time.Now().Unix() + 1
		}
		return core.ReadTraffic(database, q.From, q.To)
	case "diagnose":
		return diagnose(q.URL), nil
	default:
		return nil, fmt.Errorf("unknown action")
	}
}
func main() {
	uid := flag.Int("uid", -1, "authorized desktop user")
	sock := flag.String("socket", "/var/run/v6only-desktop.sock", "local socket")
	probe := flag.String("diagnose", "", "standalone diagnostic")
	flag.Parse()
	if *probe != "" {
		json.NewEncoder(os.Stdout).Encode(diagnose(*probe))
		return
	}
	if os.Geteuid() != 0 || *uid < 0 {
		fmt.Fprintln(os.Stderr, "service requires root and desktop UID")
		os.Exit(1)
	}
	os.Remove(*sock)
	l, e := net.Listen("unix", *sock)
	if e != nil {
		panic(e)
	}
	defer l.Close()
	defer os.Remove(*sock)
	os.Chmod(*sock, 0600)
	os.Chown(*sock, *uid, -1)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, os.Interrupt)
	go func() { <-sig; l.Close() }()
	for {
		c, e := l.Accept()
		if e != nil {
			return
		}
		go func(c net.Conn) {
			defer c.Close()
			c.SetDeadline(time.Now().Add(90 * time.Second))
			s := bufio.NewScanner(io.LimitReader(c, 16384))
			if !s.Scan() {
				return
			}
			var req Request
			if json.Unmarshal(s.Bytes(), &req) != nil {
				return
			}
			data, e := handle(req)
			response := map[string]any{"ok": e == nil, "data": data}
			if e != nil {
				response["error"] = e.Error()
			}
			json.NewEncoder(c).Encode(response)
		}(c)
	}
}
