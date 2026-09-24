package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/xjasonlyu/tun2socks/v2/dialer"
	core "github.com/y38501148-max/v6only/core"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
func run() error {
	iface := flag.String("interface", "", "physical outbound interface (required for TUN)")
	dns := flag.String("dns", "202.112.128.50,202.112.128.51", "physical DNS IPs, comma-separated")
	dev := flag.String("device", "", "TUN name; empty for proxy/probe only")
	dnsListen := flag.String("dns-listen", "", "loopback DNS endpoint")
	status := flag.String("status", "127.0.0.1:17890", "loopback diagnostics")
	proxy := flag.String("proxy", "", "optional loopback HTTP proxy")
	ready := flag.String("ready", "", "ready JSON file")
	probe := flag.String("probe", "", "probe an HTTP(S) URL and print actual connections")
	fakeDNS := flag.Bool("fake-dns", false, "synthetic addresses for an isolated VPN DNS scope (never system-wide desktop DNS)")
	flag.Parse()
	cfg := core.Config{DNS: strings.Split(*dns, ","), Interface: *iface, FakeDNS: *fakeDNS}
	r := core.New(cfg, nil)
	defer r.Close()
	if *iface != "" {
		i, e := net.InterfaceByName(*iface)
		if e != nil {
			return e
		}
		opts := &dialer.Options{InterfaceName: i.Name, InterfaceIndex: i.Index}
		r.DialOverride = func(ctx context.Context, n, a string) (net.Conn, error) {
			return dialer.DefaultDialer.DialContextWithOptions(ctx, n, a, opts)
		}
	}
	if *probe != "" {
		client := &http.Client{Timeout: 25 * time.Second, Transport: &http.Transport{Proxy: nil, DialContext: func(ctx context.Context, n, a string) (net.Conn, error) {
			h, p, e := net.SplitHostPort(a)
			if e != nil {
				return nil, e
			}
			return r.Dial(ctx, h, p)
		}}}
		res, e := client.Get(*probe)
		code := 0
		if e == nil {
			code = res.StatusCode
			res.Body.Close()
		}
		json.NewEncoder(os.Stdout).Encode(map[string]any{"http_status": code, "flows": r.Flows(""), "error": fmt.Sprint(e)})
		return e
	}
	if *dev != "" && *iface == "" {
		return fmt.Errorf("TUN requires a physical --interface to prevent routing loops")
	}
	r.Log = func(f core.Flow) { json.NewEncoder(os.Stdout).Encode(f) }
	var tunnel *core.Tunnel
	var e error
	if *dev != "" {
		tunnel, e = r.StartDevice(*dev, -1)
		if e != nil {
			return e
		}
		defer tunnel.Close()
	}
	if *dnsListen != "" {
		if e = loopback(*dnsListen); e != nil {
			return e
		}
		closeDNS, e := r.ServeDNS(*dnsListen)
		if e != nil {
			return e
		}
		defer closeDNS()
	}
	serve := func(address string, handler http.Handler) error {
		if e := loopback(address); e != nil {
			return e
		}
		l, e := net.Listen("tcp", address)
		if e != nil {
			return e
		}
		s := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second}
		go s.Serve(l)
		go func() { <-rDone; s.Close() }()
		return nil
	}
	defer close(rDone)
	if *proxy != "" {
		if e = serve(*proxy, r.HTTPProxy()); e != nil {
			return e
		}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"ready":true,"policy":"ipv6-before-ipv4"}`)
	})
	mux.HandleFunc("/flows", func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, r.JSONFlows(req.URL.Query().Get("host")))
	})
	if *status != "" {
		if e = serve(*status, mux); e != nil {
			return e
		}
	}
	if *ready != "" {
		name := ""
		if tunnel != nil {
			name = tunnel.Device.Name()
		}
		b, _ := json.Marshal(map[string]any{"pid": os.Getpid(), "device": name, "policy": "ipv6-before-ipv4"})
		if e = os.WriteFile(*ready, b, 0600); e != nil {
			return e
		}
		defer os.Remove(*ready)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	var failed <-chan error
	if tunnel != nil {
		failed = r.WatchDataPlane()
	}
	select {
	case <-sig:
	case e := <-failed:
		return e
	}
	return nil
}

var rDone = make(chan struct{})

func loopback(address string) error {
	host, _, e := net.SplitHostPort(address)
	if e != nil {
		return e
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("listener must bind numeric loopback address")
	}
	return nil
}
