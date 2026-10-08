package v6core

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var chatGPTDomains = []string{"chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"}

func isChatGPT(host string) bool {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	for _, domain := range chatGPTDomains {
		if host == domain || strings.HasSuffix(host, "."+domain) {
			return true
		}
	}
	return false
}

// The local proxy keeps its existing IPv4 upstream. This socket deliberately
// uses loopback, without binding to en0 or counting it as physical traffic.
func (r *Router) dialChatGPT(ctx context.Context, host, port string) (net.Conn, error) {
	address, p, e := net.SplitHostPort(r.cfg.ChatGPTProxy)
	ip := net.ParseIP(address)
	if e != nil || ip == nil || ip.To4() == nil || !ip.IsLoopback() || p == "" {
		return nil, fmt.Errorf("ChatGPT proxy must be an IPv4 loopback endpoint")
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	c, e := (&net.Dialer{}).DialContext(ctx, "tcp4", r.cfg.ChatGPTProxy)
	if e != nil {
		return nil, fmt.Errorf("ChatGPT IPv4 proxy unavailable: %w", e)
	}
	deadline, _ := ctx.Deadline()
	c.SetDeadline(deadline)
	target := net.JoinHostPort(host, port)
	req := &http.Request{Method: http.MethodConnect, URL: &url.URL{Opaque: target}, Host: target, Header: make(http.Header)}
	if e = req.Write(c); e != nil {
		c.Close()
		return nil, e
	}
	reader := bufio.NewReader(c)
	response, e := http.ReadResponse(reader, req)
	if e != nil {
		c.Close()
		return nil, e
	}
	if response.StatusCode != 200 {
		c.Close()
		return nil, fmt.Errorf("ChatGPT proxy CONNECT returned %d", response.StatusCode)
	}
	c.SetDeadline(time.Time{})
	// Retain any bytes arriving with the CONNECT response; count only this
	// diagnostic flow. The proxy's physical connection is counted by the TUN.
	conn := &countingConn{Conn: &bufferedConn{c, reader}}
	r.record(host, conn, "tcp4_proxy", "chatgpt_ipv4_proxy")
	return conn, nil
}

func (r *Router) ProxyPAC() string {
	var checks []string
	for _, d := range chatGPTDomains {
		checks = append(checks, fmt.Sprintf("host === %q || dnsDomainIs(host, %q)", d, "."+d))
	}
	proxy := "DIRECT"
	if r.cfg.ChatGPTProxy != "" {
		proxy = "PROXY " + r.cfg.ChatGPTProxy
	}
	return fmt.Sprintf("function FindProxyForURL(url, host) { host=host.toLowerCase(); if (%s) return %q; return 'DIRECT'; }\n", strings.Join(checks, " || "), proxy)
}
