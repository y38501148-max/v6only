package v6core

import (
	"context"
	"crypto/tls"
	"errors"
	"github.com/miekg/dns"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func fixture(t *testing.T, hosts Result) (*Router, *[]string) {
	t.Helper()
	r := New(Config{FamilyTimeoutMS: 200, FakeDNS: true}, nil)
	r.LookupOverride = func(context.Context, string) (Result, error) { return hosts, nil }
	calls := []string{}
	var mu sync.Mutex
	r.DialOverride = func(ctx context.Context, n, a string) (net.Conn, error) {
		mu.Lock()
		calls = append(calls, n)
		mu.Unlock()
		if n == "tcp6" {
			time.Sleep(40 * time.Millisecond)
		}
		a1, b := net.Pipe()
		b.Close()
		return a1, nil
	}
	t.Cleanup(r.Close)
	return r, &calls
}

func TestUnansweredUDPIsNotReplayedAtAnotherDestination(t *testing.T) {
	l, e := net.ListenPacket("udp6", "[::1]:0")
	if e != nil {
		t.Fatal(e)
	}
	defer l.Close()
	_, port, _ := net.SplitHostPort(l.LocalAddr().String())
	r := New(Config{FamilyTimeoutMS: 100}, nil)
	defer r.Close()
	r.LookupOverride = func(context.Context, string) (Result, error) { return dual(), nil }
	var ipv4 atomic.Int32
	r.DialOverride = func(ctx context.Context, n, a string) (net.Conn, error) {
		if n == "udp4" {
			ipv4.Add(1)
		}
		return (&net.Dialer{}).DialContext(ctx, n, a)
	}
	c, reply, e := r.OpenUDP(context.Background(), "oneway.test", port, []byte("single delivery"))
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	if len(reply) != 0 || ipv4.Load() != 0 {
		t.Fatal("unanswered datagram replayed", reply, ipv4.Load())
	}
	l.SetReadDeadline(time.Now().Add(time.Second))
	b := make([]byte, 100)
	n, _, e := l.ReadFrom(b)
	if e != nil || string(b[:n]) != "single delivery" {
		t.Fatal("IPv6 delivery failed", e)
	}
}
func dual() Result {
	return Result{V6: []net.IP{net.ParseIP("::1")}, V4: []net.IP{net.ParseIP("127.0.0.1")}, TTL: time.Minute}
}
func TestIPv6WinsEvenWhenIPv4WouldBeFaster(t *testing.T) {
	r, calls := fixture(t, dual())
	c, e := r.Dial(context.Background(), "dual.test", "443")
	if e != nil {
		t.Fatal(e)
	}
	c.Close()
	if strings.Join(*calls, ",") != "tcp6" {
		t.Fatal(*calls)
	}
}
func TestIPv4Only(t *testing.T) {
	v := dual()
	v.V6 = nil
	r, calls := fixture(t, v)
	c, e := r.Dial(context.Background(), "v4.test", "80")
	if e != nil {
		t.Fatal(e)
	}
	c.Close()
	if strings.Join(*calls, ",") != "tcp4" {
		t.Fatal(*calls)
	}
}
func TestFallbackAfterAllIPv6Failures(t *testing.T) {
	r, _ := fixture(t, dual())
	calls := []string{}
	r.DialOverride = func(ctx context.Context, n, a string) (net.Conn, error) {
		calls = append(calls, n)
		if n == "tcp6" {
			return nil, errors.New("unreachable")
		}
		a1, b := net.Pipe()
		b.Close()
		return a1, nil
	}
	c, e := r.Dial(context.Background(), "broken6.test", "443")
	if e != nil {
		t.Fatal(e)
	}
	c.Close()
	if strings.Join(calls, ",") != "tcp6,tcp4" {
		t.Fatal(calls)
	}
}
func TestDNSFailureNeverPretendsIPv4Only(t *testing.T) {
	r, calls := fixture(t, dual())
	r.LookupOverride = func(context.Context, string) (Result, error) { return Result{}, errors.New("AAAA timed out") }
	if _, e := r.Dial(context.Background(), "unknown.test", "443"); e == nil {
		t.Fatal("expected failure")
	}
	if len(*calls) != 0 {
		t.Fatal(*calls)
	}
}
func TestCanceledContextCannotFallBack(t *testing.T) {
	r, calls := fixture(t, dual())
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r.Dial(ctx, "dual.test", "443")
	for _, n := range *calls {
		if n == "tcp4" {
			t.Fatal("fallback after cancellation")
		}
	}
}
func TestDNSFakeIPv4StillDialsIPv6(t *testing.T) {
	r, calls := fixture(t, dual())
	q := new(dns.Msg)
	q.SetQuestion("dual.test.", dns.TypeA)
	wire, _ := q.Pack()
	ans := new(dns.Msg)
	if e := ans.Unpack(r.DNS(context.Background(), wire)); e != nil {
		t.Fatal(e)
	}
	ip := ans.Answer[0].(*dns.A).A
	if !isFake(ip) {
		t.Fatal(ip)
	}
	c, e := r.Dial(context.Background(), ip.String(), "443")
	if e != nil {
		t.Fatal(e)
	}
	c.Close()
	if strings.Join(*calls, ",") != "tcp6" {
		t.Fatal(*calls)
	}
}
func TestUnknownFakeIPFails(t *testing.T) {
	r := New(Config{}, nil)
	defer r.Close()
	if _, e := r.Dial(context.Background(), "198.19.1.2", "443"); e == nil {
		t.Fatal("unknown mapping allowed")
	}
}
func TestAAAAAndECHPolicy(t *testing.T) {
	r, _ := fixture(t, dual())
	for _, typ := range []uint16{dns.TypeAAAA, dns.TypeHTTPS} {
		q := new(dns.Msg)
		q.SetQuestion("dual.test.", typ)
		b, _ := q.Pack()
		a := new(dns.Msg)
		a.Unpack(r.DNS(context.Background(), b))
		if typ == dns.TypeAAAA && len(a.Answer) != 1 {
			t.Fatal(a)
		}
		if typ == dns.TypeHTTPS && len(a.Answer) != 0 {
			t.Fatal(a)
		}
	}
}
func TestTLSNameSniff(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	go func() { defer a.Close(); tls.Client(a, &tls.Config{ServerName: "www.bilibili.com"}).Handshake() }()
	header := make([]byte, 5)
	io.ReadFull(b, header)
	size := int(header[3])<<8 | int(header[4])
	body := make([]byte, size)
	io.ReadFull(b, body)
	packet := append(header, body...)
	if s := ParseSNI(packet); s != "www.bilibili.com" {
		t.Fatal(s)
	}
	for i := 0; i < len(packet); i++ {
		ParseSNI(packet[:i])
	}
}
func TestUDPIPv6ActualResponse(t *testing.T) {
	l, e := net.ListenPacket("udp6", "[::1]:0")
	if e != nil {
		t.Skip(e)
	}
	defer l.Close()
	go func() { b := make([]byte, 99); n, a, _ := l.ReadFrom(b); l.WriteTo(b[:n], a) }()
	_, port, _ := net.SplitHostPort(l.LocalAddr().String())
	r := New(Config{FamilyTimeoutMS: 300}, nil)
	defer r.Close()
	r.LookupOverride = func(context.Context, string) (Result, error) { return dual(), nil }
	c, b, e := r.OpenUDP(context.Background(), "dual.test", port, []byte("v6-marker"))
	if e != nil {
		t.Fatal(e)
	}
	c.Close()
	if string(b) != "v6-marker" || r.Flows("")[0].Network != "udp6" {
		t.Fatal(string(b), r.Flows(""))
	}
}
func TestUDPIPv4ActualFallback(t *testing.T) {
	l, e := net.ListenPacket("udp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer l.Close()
	go func() { b := make([]byte, 99); n, a, _ := l.ReadFrom(b); l.WriteTo(b[:n], a) }()
	_, port, _ := net.SplitHostPort(l.LocalAddr().String())
	r := New(Config{FamilyTimeoutMS: 300}, nil)
	defer r.Close()
	r.LookupOverride = func(context.Context, string) (Result, error) { return dual(), nil }
	c, _, e := r.OpenUDP(context.Background(), "dual.test", port, []byte("v4-marker"))
	if e != nil {
		t.Fatal(e)
	}
	c.Close()
	if r.Flows("")[0].Network != "udp4" {
		t.Fatal(r.Flows(""))
	}
}
