package v6core

import (
	"context"
	"errors"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// Use real DNS wire responses, including Android's synthetic A response. An
// unavailable supplemental resolver must not discard a successful network DNS.
func TestSupplementalDNSFailurePreservesNetworkAnswer(t *testing.T) {
	for _, mode := range []string{"refused", "timeout", "servfail", "nxdomain"} {
		t.Run(mode, func(t *testing.T) {
			local, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			server := &dns.Server{PacketConn: local, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, q *dns.Msg) {
				a := new(dns.Msg)
				a.SetReply(q)
				if q.Question[0].Qtype == dns.TypeA {
					a.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: q.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30}, A: net.ParseIP("127.0.0.1")}}
				}
				w.WriteMsg(a)
			})}
			go server.ActivateAndServe()
			t.Cleanup(func() { server.Shutdown() })
			r := New(Config{DNS: []string{local.LocalAddr().String()}, IPv6DNS: []string{"192.0.2.53:53"}, FakeDNS: true}, nil)
			t.Cleanup(r.Close)
			var publicCalls atomic.Int32
			r.DialOverride = func(ctx context.Context, network, address string) (net.Conn, error) {
				if address != "192.0.2.53:53" {
					return (&net.Dialer{}).DialContext(ctx, network, address)
				}
				publicCalls.Add(1)
				if mode == "refused" {
					return nil, errors.New("public DNS unreachable")
				}
				if mode == "timeout" {
					<-ctx.Done()
					return nil, ctx.Err()
				}
				client, peer := net.Pipe()
				go func() {
					defer peer.Close()
					// net.Pipe is stream-oriented; miekg/dns uses TCP framing.
					c := &dns.Conn{Conn: peer}
					q, err := c.ReadMsg()
					if err != nil {
						return
					}
					a := new(dns.Msg)
					a.SetReply(q)
					a.Rcode = dns.RcodeServerFailure
					if mode == "nxdomain" {
						a.Rcode = dns.RcodeNameError
					}
					c.WriteMsg(a)
				}()
				return client, nil
			}
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			defer cancel()
			started := time.Now()
			q := new(dns.Msg)
			q.SetQuestion("v4.example.", dns.TypeA)
			wire, _ := q.Pack()
			a := new(dns.Msg)
			if err := a.Unpack(r.DNS(ctx, wire)); err != nil {
				t.Fatal(err)
			}
			if a.Rcode != dns.RcodeSuccess || len(a.Answer) != 1 {
				t.Fatalf("IPv4 DNS was black-holed: %v", a)
			}
			if time.Since(started) > 2*time.Second {
				t.Fatal("optional lookup delayed a working DNS answer")
			}
			fake := a.Answer[0].(*dns.A).A
			if !isFake(fake) || publicCalls.Load() == 0 {
				t.Fatal("synthetic DNS or supplemental lookup not exercised")
			}
			got, err := r.Resolve(ctx, fake.String())
			if err != nil || len(got.V6) != 0 || len(got.V4) != 1 {
				t.Fatal(got, err)
			}
			listener, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			_, port, _ := net.SplitHostPort(listener.Addr().String())
			conn, err := r.Dial(ctx, fake.String(), port)
			if err != nil {
				t.Fatal("IPv4 forwarding failed:", err)
			}
			conn.Close()
			if r.Flows("")[0].Network != "tcp4" {
				t.Fatal(r.Flows(""))
			}
		})
	}
}

func TestBothDNSResolversFailRemainAnError(t *testing.T) {
	r := New(Config{DNS: []string{"192.0.2.1"}, IPv6DNS: []string{"192.0.2.2"}, FakeDNS: true}, nil)
	defer r.Close()
	r.DialOverride = func(context.Context, string, string) (net.Conn, error) { return nil, errors.New("DNS unavailable") }
	if _, err := r.Resolve(context.Background(), "unknown.example"); err == nil {
		t.Fatal("DNS failures are not proof of no AAAA")
	}
}

func TestSupplementalDNSRacesBlockedTransportAndResolver(t *testing.T) {
	for _, mode := range []string{"tcp_blocked", "first_resolver_blocked", "first_resolver_nodata", "udp_nodata", "tcp_one_second"} {
		t.Run(mode, func(t *testing.T) {
			local, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			server := &dns.Server{PacketConn: local, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, q *dns.Msg) {
				a := new(dns.Msg)
				a.SetReply(q)
				if q.Question[0].Qtype == dns.TypeA {
					a.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: q.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30}, A: net.ParseIP("192.0.2.80")}}
				}
				w.WriteMsg(a)
			})}
			go server.ActivateAndServe()
			t.Cleanup(func() { server.Shutdown() })
			r := New(Config{DNS: []string{local.LocalAddr().String()}, IPv6DNS: []string{"192.0.2.1", "192.0.2.2"}}, nil)
			t.Cleanup(r.Close)
			r.DialOverride = func(ctx context.Context, network, address string) (net.Conn, error) {
				if address == local.LocalAddr().String() {
					return (&net.Dialer{}).DialContext(ctx, network, address)
				}
				blocked := (network == "tcp" && mode != "udp_nodata" && mode != "tcp_one_second") || (mode == "first_resolver_blocked" && address == "192.0.2.1:53")
				if blocked {
					<-ctx.Done()
					return nil, ctx.Err()
				}
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
					if (mode != "first_resolver_nodata" || address != "192.0.2.1:53") && ((mode != "udp_nodata" && mode != "tcp_one_second") || network != "udp") {
						if mode == "first_resolver_nodata" || mode == "udp_nodata" {
							time.Sleep(30 * time.Millisecond)
						}
						if mode == "tcp_one_second" {
							time.Sleep(1050 * time.Millisecond)
						}
						a.Answer = []dns.RR{&dns.AAAA{Hdr: dns.RR_Header{Name: q.Question[0].Name, Rrtype: dns.TypeAAAA, Class: dns.ClassINET, Ttl: 30}, AAAA: net.ParseIP("2001:db8::80")}}
					}
					c.WriteMsg(a)
				}()
				return client, nil
			}
			started := time.Now()
			got, err := r.Resolve(context.Background(), "video.example")
			if err != nil || len(got.V6) != 1 {
				t.Fatalf("missed reachable supplemental AAAA: %+v, %v", got, err)
			}
			if mode != "tcp_one_second" && time.Since(started) > 500*time.Millisecond {
				t.Fatal("blocked query delayed usable AAAA")
			}
		})
	}
}
