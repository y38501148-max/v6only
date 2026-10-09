package v6core

import (
	"context"
	"errors"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/miekg/dns"
)

func TestNeteaseIPv6Scope(t *testing.T) {
	for _, host := range []string{"m701.music.126.net", "M801.MUSIC.126.NET."} {
		if neteaseCDNAlias(host) == "" {
			t.Fatalf("missing known CDN: %s", host)
		}
	}
	for _, host := range []string{"music.163.com", "p1.music.126.net", "m701.music.126.net.evil.test", "evilm701.music.126.net", "m999.music.126.net", "buaa.edu.cn", "192.0.2.1"} {
		if neteaseCDNAlias(host) != "" {
			t.Fatalf("unexpected CDN alias for %s", host)
		}
	}
}

func neteaseFixture(t *testing.T, enabled bool, mode string) (*Router, *atomic.Int32, *atomic.Int32) {
	t.Helper()
	r := New(Config{DNS: []string{"192.0.2.1"}, IPv6DNS: []string{"192.0.2.2"}, NeteaseIPv6: enabled, FamilyTimeoutMS: 200}, nil)
	t.Cleanup(r.Close)
	aliases, v4 := new(atomic.Int32), new(atomic.Int32)
	r.DialOverride = func(ctx context.Context, network, address string) (net.Conn, error) {
		if !strings.HasSuffix(address, ":53") {
			if network == "tcp4" {
				v4.Add(1)
			}
			if mode == "connect_failed" {
				return nil, errors.New("unreachable CDN edge")
			}
			client, peer := net.Pipe()
			peer.Close()
			return client, nil
		}
		client, peer := net.Pipe()
		go func() {
			defer peer.Close()
			c := &dns.Conn{Conn: peer}
			q, err := c.ReadMsg()
			if err != nil {
				return
			}
			a := new(dns.Msg)
			a.SetReply(q)
			if strings.HasSuffix(q.Question[0].Name, ".w.alikunlun.com.") {
				aliases.Add(1)
				op := q.IsEdns0()
				if op == nil || len(op.Option) != 1 {
					t.Error("missing scoped CDN location hint")
					return
				}
				sub, ok := op.Option[0].(*dns.EDNS0_SUBNET)
				if !ok || sub.Family != 2 || sub.SourceNetmask != 24 || sub.SourceScope != 0 || (!sub.Address.Equal(net.ParseIP("2409:8c00::")) && !sub.Address.Equal(net.ParseIP("2408:8000::"))) {
					t.Errorf("unexpected ECS: %v", op.Option)
					return
				}
				if mode == "timeout" {
					<-ctx.Done()
					return
				}
				if mode == "nodata" || (mode != "both" && sub.Address.Equal(net.ParseIP("2408:8000::"))) {
					c.WriteMsg(a)
					return
				}
				// A fast empty answer must not mask another hint's working edge.
				time.Sleep(15 * time.Millisecond)
				ip := "2001:db8::80"
				if mode == "both" && sub.Address.Equal(net.ParseIP("2408:8000::")) {
					ip = "2001:db8::81"
				}
				if mode == "private" {
					ip = "fd00::80"
				}
				a.Answer = []dns.RR{&dns.AAAA{Hdr: dns.RR_Header{Name: q.Question[0].Name, Rrtype: dns.TypeAAAA, Class: dns.ClassINET, Ttl: 60}, AAAA: net.ParseIP(ip)}}
			} else if q.Question[0].Qtype == dns.TypeA {
				a.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: q.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30}, A: net.ParseIP("192.0.2.80")}}
			}
			c.WriteMsg(a)
		}()
		return client, nil
	}
	return r, aliases, v4
}

func TestNeteaseIPv6DNSAndForwarding(t *testing.T) {
	r, aliases, v4 := neteaseFixture(t, true, "success")
	q := new(dns.Msg)
	q.SetQuestion("m701.music.126.net.", dns.TypeAAAA)
	wire, _ := q.Pack()
	a := new(dns.Msg)
	if err := a.Unpack(r.DNS(context.Background(), wire)); err != nil {
		t.Fatal(err)
	}
	if a.Id != q.Id || a.Rcode != dns.RcodeSuccess || len(a.Answer) != 1 || a.Answer[0].Header().Name != q.Question[0].Name || a.Answer[0].Header().Ttl > 30 {
		t.Fatalf("incorrect client DNS response: %v", a)
	}
	if aliases.Load() == 0 {
		t.Fatal("official CDN alias was not queried")
	}
	conn, err := r.Dial(context.Background(), "m701.music.126.net", "443")
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	if v4.Load() != 0 || r.Flows("")[0].Network != "tcp6" || r.Flows("")[0].Host != "m701.music.126.net" {
		t.Fatal("audio did not retain its original host over IPv6")
	}
}

func TestNeteaseIPv6OptionalAndFallback(t *testing.T) {
	for _, mode := range []string{"disabled", "nodata", "private", "timeout"} {
		t.Run(mode, func(t *testing.T) {
			r, aliases, _ := neteaseFixture(t, mode != "disabled", mode)
			start := time.Now()
			result, err := r.Resolve(context.Background(), "m701.music.126.net")
			if err != nil || len(result.V6) != 0 || len(result.V4) != 1 {
				t.Fatalf("normal DNS was lost: %+v %v", result, err)
			}
			if time.Since(start) > 2*time.Second {
				t.Fatal("optional CDN lookup exceeded its budget")
			}
			if mode == "disabled" && aliases.Load() != 0 {
				t.Fatal("disabled feature queried CDN aliases")
			}
		})
	}
}

func TestNeteaseIPv6ConnectionFailureNeverDialsIPv4(t *testing.T) {
	r, _, v4 := neteaseFixture(t, true, "connect_failed")
	if _, err := r.Dial(context.Background(), "m701.music.126.net", "443"); err == nil || !strings.Contains(err.Error(), "IPv4 fallback forbidden") {
		t.Fatalf("expected strict IPv6 error, got %v", err)
	}
	if v4.Load() != 0 {
		t.Fatal("fell back to IPv4 after finding a CDN AAAA")
	}
}

func TestNeteaseIPv6CollectsBothCarriers(t *testing.T) {
	r, _, _ := neteaseFixture(t, true, "both")
	got, err := r.Resolve(context.Background(), "m701.music.126.net")
	if err != nil || len(got.V6) != 2 {
		t.Fatalf("missing carrier alternatives: %+v %v", got, err)
	}
}
