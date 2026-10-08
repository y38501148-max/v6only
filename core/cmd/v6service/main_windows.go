//go:build windows

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Microsoft/go-winio"
	core "github.com/y38501148-max/v6only/core"
	"golang.org/x/sys/windows/svc"
	"syscall"
)

const pipeName = `\\.\pipe\v6only-desktop`

type request struct {
	Action string `json:"action"`
	From   int64  `json:"from"`
	To     int64  `json:"to"`
	URL    string `json:"url"`
}

var operation sync.Mutex
var root string

func controller(action string) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(root, "desktop-controller.ps1"), "-Action", action)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	b, e := cmd.CombinedOutput()
	if e != nil {
		return nil, fmt.Errorf("%s: %w", b, e)
	}
	if !json.Valid(b) {
		return json.RawMessage(`{}`), nil
	}
	return json.RawMessage(b), nil
}
func handle(q request) (any, error) {
	switch q.Action {
	case "status":
		operation.Lock()
		defer operation.Unlock()
		return controller("status")
	case "enable", "disable":
		operation.Lock()
		defer operation.Unlock()
		b, e := controller(q.Action)
		return map[string]any{"status": b}, e
	case "stats":
		if q.To == 0 {
			q.To = time.Now().Unix() + 1
		}
		return core.ReadTraffic(filepath.Join(os.Getenv("ProgramData"), "v6only", "traffic.sqlite"), q.From, q.To)
	case "diagnose":
		operation.Lock()
		defer operation.Unlock()
		bstatus, e := controller("status")
		if e != nil {
			return nil, e
		}
		var st struct {
			Interface string   `json:"interface_name"`
			DNS       []string `json:"dns"`
		}
		json.Unmarshal(bstatus, &st)
		if st.Interface == "" {
			return nil, fmt.Errorf("No physical network adapter")
		}
		if len(st.DNS) == 0 {
			st.DNS = []string{"223.5.5.5", "223.6.6.6"}
		}
		raw := q.URL
		if !strings.Contains(raw, "://") {
			raw = "https://" + raw
		}
		u, e := url.Parse(raw)
		if e != nil || u.Hostname() == "" || (u.Scheme != "https" && u.Scheme != "http") || u.User != nil {
			return nil, fmt.Errorf("请输入有效的 HTTP/HTTPS 地址")
		}
		// Only a URL is accepted; it is passed as one argv value, never to a shell.
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, filepath.Join(root, "v6core.exe"), "--interface", st.Interface, "--dns", strings.Join(st.DNS, ","), "--ipv6-dns", "2400:3200::1,2400:3200:baba::1", "--chatgpt-ipv4", "--probe", raw)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		b, e := cmd.Output()
		if !json.Valid(b) {
			return nil, e
		}
		var r any
		e = json.Unmarshal(b, &r)
		return r, e
	default:
		return nil, fmt.Errorf("unknown action")
	}
}
func serve(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(90 * time.Second))
	s := bufio.NewScanner(io.LimitReader(c, 16384))
	if !s.Scan() {
		return
	}
	var q request
	if json.Unmarshal(s.Bytes(), &q) != nil {
		return
	}
	data, e := handle(q)
	r := map[string]any{"ok": e == nil, "data": data}
	if e != nil {
		r["error"] = e.Error()
	}
	json.NewEncoder(c).Encode(r)
}

type service struct{}

func (service) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	// Deny network logons. Local interactive users may invoke only the fixed RPC actions.
	l, e := winio.ListenPipe(pipeName, &winio.PipeConfig{SecurityDescriptor: "D:P(D;;GA;;;NU)(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)", InputBufferSize: 65536, OutputBufferSize: 65536})
	if e != nil {
		return false, 1
	}
	defer l.Close()
	go func() {
		for {
			c, e := l.Accept()
			if e != nil {
				return
			}
			go serve(c)
		}
	}()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	done := make(chan struct{})
	watchDone := make(chan struct{})
	defer func() {
		select {
		case <-done:
		default:
			close(done)
		}
	}()
	go func() {
		defer close(watchDone)
		for {
			select {
			case <-done:
				return
			default:
			}
			operation.Lock()
			controller("watch")
			operation.Unlock()
			select {
			case <-done:
				return
			case <-ticker.C:
			}
		}
	}()
	for r := range requests {
		switch r.Cmd {
		case svc.Interrogate:
			status <- r.CurrentStatus
		case svc.Stop, svc.Shutdown:
			status <- svc.Status{State: svc.StopPending}
			close(done)
			<-watchDone
			operation.Lock()
			controller("stop")
			operation.Unlock()
			return false, 0
		}
	}
	return false, 0
}
func main() {
	exe, e := os.Executable()
	if e != nil {
		panic(e)
	}
	root = filepath.Join(filepath.Dir(exe), "windows")
	if e = svc.Run("V6Only", service{}); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
