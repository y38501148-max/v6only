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

func TestAlternateIPv6Edge(t *testing.T) {
	for _, mode := range []string{"slow_primary", "failed_primary", "both_fail", "nodata", "fast_primary", "campus", "literal"} {
		t.Run(mode, func(t *testing.T) {
			r := New(Config{IPv6DNS: []string{"192.0.2.53"}, FamilyTimeoutMS: 1500}, nil)
			defer r.Close()
			host := "cdn.example"
			if mode == "campus" {
				host = "cdn.buaa.edu.cn"
			}
			if mode == "literal" {
				host = "2001:db8::1"
			}
			r.LookupOverride = func(context.Context, string) (Result, error) {
				return Result{V6: []net.IP{net.ParseIP("2001:db8::1")}, V4: []net.IP{net.ParseIP("192.0.2.80")}}, nil
			}
			var queries, v4, alternate atomic.Int32
			r.DialOverride = func(ctx context.Context, network, address string) (net.Conn, error) {
				if address == "192.0.2.53:53" {
					queries.Add(1)
					client, peer := net.Pipe()
					go func() {
						defer peer.Close()
						c := &dns.Conn{Conn: peer}
						q, e := c.ReadMsg()
						if e != nil {
							return
						}
						a := new(dns.Msg)
						a.SetReply(q)
						if mode != "nodata" {
							a.Answer = []dns.RR{&dns.AAAA{Hdr: dns.RR_Header{Name: q.Question[0].Name, Rrtype: dns.TypeAAAA, Class: dns.ClassINET, Ttl: 30}, AAAA: net.ParseIP("2001:db8::2")}}
						}
						c.WriteMsg(a)
					}()
					return client, nil
				}
				if network == "tcp4" {
					v4.Add(1)
					return nil, errors.New("must never dial IPv4")
				}
				if strings.HasPrefix(address, "[2001:db8::1]") && mode != "fast_primary" {
					if mode == "slow_primary" {
						<-ctx.Done()
						return nil, ctx.Err()
					}
					return nil, errors.New("primary edge unreachable")
				}
				alternate.Add(1)
				if mode == "both_fail" {
					return nil, errors.New("alternate edge unreachable")
				}
				client, peer := net.Pipe()
				t.Cleanup(func() { peer.Close() })
				return client, nil
			}
			start := time.Now()
			c, e := r.Dial(context.Background(), host, "443")
			wantSuccess := mode == "slow_primary" || mode == "failed_primary" || mode == "fast_primary"
			if (e == nil) != wantSuccess {
				t.Fatalf("unexpected outcome: %v", e)
			}
			if c != nil {
				c.Close()
			}
			if time.Since(start) > time.Second {
				t.Fatal("waited for primary timeout instead of racing an alternate IPv6 edge")
			}
			if v4.Load() != 0 {
				t.Fatal("IPv4 fallback attempted")
			}
			if mode == "campus" || mode == "literal" || mode == "fast_primary" {
				if queries.Load() != 0 {
					t.Fatal("unnecessary public DNS lookup")
				}
			} else if queries.Load() == 0 {
				t.Fatal("alternate DNS path not exercised")
			}
			if wantSuccess && (alternate.Load() == 0 || r.Flows("")[0].Network != "tcp6") {
				t.Fatal("missing IPv6 flow")
			}
		})
	}
}

func TestAlternateIPv6Cancellation(t *testing.T) {
	r := New(Config{IPv6DNS: []string{"192.0.2.53"}}, nil)
	defer r.Close()
	r.LookupOverride = func(context.Context, string) (Result, error) {
		return Result{V6: []net.IP{net.ParseIP("2001:db8::1")}}, nil
	}
	var active atomic.Int32
	r.DialOverride = func(ctx context.Context, network, address string) (net.Conn, error) {
		active.Add(1)
		defer active.Add(-1)
		<-ctx.Done()
		return nil, ctx.Err()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	if _, e := r.Dial(ctx, "cancel.example", "443"); e == nil {
		t.Fatal("canceled dial succeeded")
	}
	until := time.Now().Add(time.Second)
	for active.Load() != 0 && time.Now().Before(until) {
		time.Sleep(time.Millisecond)
	}
	if active.Load() != 0 {
		t.Fatal("losing DNS/dial goroutines remained active")
	}
}
