package v6core

import (
	"bufio"
	"context"
	"github.com/miekg/dns"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
)

func TestChatGPTDomainBoundary(t *testing.T) {
	for _, h := range []string{"chatgpt.com", "chat.openai.com", "API.OpenAI.com.", "cdn.oaistatic.com"} {
		if !isChatGPT(h) {
			t.Fatal(h)
		}
	}
	for _, h := range []string{"evilopenai.com", "openai.com.evil.test", "www.bilibili.com"} {
		if isChatGPT(h) {
			t.Fatal(h)
		}
	}
}

func TestChatGPTDirectIPv4Exception(t *testing.T) {
	r := New(Config{ChatGPTIPv4: true}, nil)
	defer r.Close()
	r.LookupOverride = func(context.Context, string) (Result, error) {
		return Result{V4: []net.IP{net.ParseIP("192.0.2.3")}, V6: []net.IP{net.ParseIP("2001:db8::3")}}, nil
	}
	r.DialOverride = func(_ context.Context, network, address string) (net.Conn, error) {
		if network != "tcp4" || address != "192.0.2.3:443" {
			t.Errorf("unexpected transport: %s %s", network, address)
		}
		c, peer := net.Pipe()
		peer.Close()
		return c, nil
	}
	c, e := r.Dial(context.Background(), "api.openai.com", "443")
	if e != nil {
		t.Fatal(e)
	}
	c.Close()
	if r.Flows("")[0].Reason != "chatgpt_ipv4" {
		t.Fatal(r.Flows(""))
	}
	a, e := r.query(context.Background(), "api.openai.com", dns.TypeAAAA)
	if e != nil || len(a.Answer) != 0 {
		t.Fatal(a, e)
	}
	if _, _, e = r.OpenUDP(context.Background(), "chatgpt.com", "443", []byte("quic")); e == nil {
		t.Fatal("ChatGPT QUIC must not dial IPv6")
	}
}
func TestChatGPTProxyPreservesBufferedTunnelAndSkipsIPv6(t *testing.T) {
	l, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer l.Close()
	target := make(chan string, 1)
	go func() {
		c, e := l.Accept()
		if e != nil {
			return
		}
		defer c.Close()
		q, e := http.ReadRequest(bufio.NewReader(c))
		if e != nil {
			return
		}
		target <- q.Host
		io.WriteString(c, "HTTP/1.1 200 Connection Established\r\n\r\nhello")
		io.Copy(io.Discard, c)
	}()
	r := New(Config{ChatGPTProxy: l.Addr().String()}, nil)
	defer r.Close()
	r.LookupOverride = func(context.Context, string) (Result, error) {
		t.Error("ChatGPT must not resolve or dial IPv6")
		return Result{}, nil
	}
	c, e := r.Dial(context.Background(), "chat.openai.com", "443")
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	b := make([]byte, 5)
	if _, e = io.ReadFull(c, b); e != nil || string(b) != "hello" {
		t.Fatal(string(b), e)
	}
	if <-target != "chat.openai.com:443" {
		t.Fatal("bad CONNECT target")
	}
	f := r.Flows("")[0]
	if f.Network != "tcp4_proxy" || f.DownloadBytes != 5 {
		t.Fatal(f)
	}
	a, e := r.query(context.Background(), "api.openai.com", dns.TypeAAAA)
	if e != nil || len(a.Answer) != 0 {
		t.Fatal(a, e)
	}
	if _, _, e = r.OpenUDP(context.Background(), "chatgpt.com", "443", []byte("quic")); e == nil {
		t.Fatal("ChatGPT UDP bypass allowed")
	}
	if !strings.Contains(r.ProxyPAC(), "PROXY "+l.Addr().String()) || !strings.Contains(r.ProxyPAC(), "return 'DIRECT'") {
		t.Fatal(r.ProxyPAC())
	}
}
