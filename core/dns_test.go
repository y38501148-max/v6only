package v6core

import (
	"context"
	"github.com/miekg/dns"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestDesktopDNSPreservesRealAddressesAndNegativeResponses(t *testing.T) {
	listener, e := net.ListenPacket("udp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	server := &dns.Server{PacketConn: listener, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, q *dns.Msg) {
		a := new(dns.Msg)
		a.SetReply(q)
		question := q.Question[0]
		hdr := dns.RR_Header{Name: question.Name, Rrtype: question.Qtype, Class: dns.ClassINET, Ttl: 30}
		switch question.Name {
		case "absent.test.":
			a.Rcode = dns.RcodeNameError
		case "empty.test.":
		default:
			if question.Qtype == dns.TypeA {
				a.Answer = []dns.RR{&dns.A{Hdr: hdr, A: net.ParseIP("203.0.113.3")}}
			} else {
				if question.Name == "dns6fail.test." {
					a.Rcode = dns.RcodeServerFailure
				} else {
					a.Answer = []dns.RR{&dns.AAAA{Hdr: hdr, AAAA: net.ParseIP("2001:db8::3")}}
				}
			}
		}
		w.WriteMsg(a)
	})}
	go server.ActivateAndServe()
	t.Cleanup(func() { server.Shutdown() })
	r := New(Config{DNS: []string{listener.LocalAddr().String()}}, nil)
	t.Cleanup(r.Close)
	for _, item := range []struct {
		host         string
		rcode, count int
	}{{"dual.test", 0, 1}, {"absent.test", 3, 0}, {"empty.test", 0, 0}, {"dns6fail.test", 0, 1}} {
		q := new(dns.Msg)
		q.SetQuestion(item.host+".", dns.TypeA)
		wire, _ := q.Pack()
		ans := new(dns.Msg)
		if e := ans.Unpack(r.DNS(context.Background(), wire)); e != nil {
			t.Fatal(e)
		}
		if ans.Rcode != item.rcode || len(ans.Answer) != item.count {
			t.Fatalf("%s: %v", item.host, ans)
		}
		if len(ans.Answer) > 0 && ans.Answer[0].(*dns.A).A.String() != "203.0.113.3" {
			t.Fatal("desktop returned synthetic address")
		}
	}
	// Two names on the same CDN IP are not a safe basis for changing the origin.
	if host := r.domain("203.0.113.3"); host != "dual.test" {
		t.Fatal(host)
	}
	r.lookup(context.Background(), "other.test")
	if host := r.domain("203.0.113.3"); host != "" {
		t.Fatal("ambiguous reverse mapping", host)
	}
	r.mu.Lock()
	r.reverse["203.0.113.9"] = reverseEntry{"expired.test", time.Now().Add(-time.Second)}
	r.mu.Unlock()
	if r.domain("203.0.113.9") != "" {
		t.Fatal("expired reverse DNS used")
	}
}

func FuzzParseSNI(f *testing.F) {
	f.Add([]byte{22, 3, 3, 0, 0, 1, 0, 0, 0})
	f.Add([]byte{22, 3, 3, 0, 4, 1, 0, 0, 0})
	f.Fuzz(func(t *testing.T, b []byte) { ParseSNI(b) })
}

// Campus DNS can return NODATA even when a public IPv6 resolver discovers
// a usable CDN AAAA. Keep campus portal split DNS and fail closed on errors.
func TestIPv6DNSDiscoversCDNAndPreservesCampus(t *testing.T) {
	start := func(public bool) string {
		l, e := net.ListenPacket("udp4", "127.0.0.1:0")
		if e != nil {
			t.Fatal(e)
		}
		server := &dns.Server{PacketConn: l, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, q *dns.Msg) {
			a := new(dns.Msg)
			a.SetReply(q)
			v := q.Question[0]
			hdr := dns.RR_Header{Name: v.Name, Rrtype: v.Qtype, Class: dns.ClassINET, Ttl: 30}
			if public && v.Name == "failure.test." {
				a.Rcode = dns.RcodeServerFailure
			} else if public && v.Qtype == dns.TypeAAAA {
				a.Answer = []dns.RR{&dns.AAAA{Hdr: hdr, AAAA: net.ParseIP("2001:db8::6")}}
			} else if !public && v.Qtype == dns.TypeA {
				a.Answer = []dns.RR{&dns.A{Hdr: hdr, A: net.ParseIP("203.0.113.4")}}
			}
			w.WriteMsg(a)
		})}
		go server.ActivateAndServe()
		t.Cleanup(func() { server.Shutdown() })
		return l.LocalAddr().String()
	}
	r := New(Config{DNS: []string{start(false)}, IPv6DNS: []string{start(true)}}, nil)
	t.Cleanup(r.Close)
	cdn, e := r.Resolve(context.Background(), "cdn.bilivideo.com")
	if e != nil || len(cdn.V6) != 1 || len(cdn.V4) != 1 {
		t.Fatal(cdn, e)
	}
	campus, e := r.Resolve(context.Background(), "gw.buaa.edu.cn")
	if e != nil || len(campus.V6) != 0 || len(campus.V4) != 1 {
		t.Fatal(campus, e)
	}
	if _, e = r.Resolve(context.Background(), "failure.test"); e == nil {
		t.Fatal("public AAAA failure incorrectly allowed IPv4")
	}
	q := new(dns.Msg)
	q.SetQuestion("cdn.bilivideo.com.", dns.TypeAAAA)
	wire, _ := q.Pack()
	answer := new(dns.Msg)
	answer.Unpack(r.DNS(context.Background(), wire))
	if len(answer.Answer) != 1 || answer.Answer[0].(*dns.AAAA).AAAA.String() != "2001:db8::6" {
		t.Fatal(answer)
	}
}

func TestUDPTimeoutTriesTCPDNS(t *testing.T) {
	udp, e := net.ListenPacket("udp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	tcp, e := net.Listen("tcp4", udp.LocalAddr().String())
	if e != nil {
		udp.Close()
		t.Fatal(e)
	}
	udpServer := &dns.Server{PacketConn: udp, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, q *dns.Msg) {})}
	tcpServer := &dns.Server{Listener: tcp, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, q *dns.Msg) {
		a := new(dns.Msg)
		a.SetReply(q)
		a.Answer = []dns.RR{&dns.AAAA{Hdr: dns.RR_Header{Name: q.Question[0].Name, Rrtype: dns.TypeAAAA, Class: dns.ClassINET, Ttl: 30}, AAAA: net.ParseIP("2001:db8::9")}}
		w.WriteMsg(a)
	})}
	go udpServer.ActivateAndServe()
	go tcpServer.ActivateAndServe()
	t.Cleanup(func() { udpServer.Shutdown(); tcpServer.Shutdown() })
	r := New(Config{DNS: []string{udp.LocalAddr().String()}}, nil)
	t.Cleanup(r.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	a, e := r.query(ctx, "cdn.test", dns.TypeAAAA)
	if e != nil || len(a.Answer) != 1 {
		t.Fatal(a, e)
	}
}

func TestConcurrentDNSQueriesShareOneRequestAndCopyReplies(t *testing.T) {
	l, e := net.ListenPacket("udp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	var calls atomic.Int32
	server := &dns.Server{PacketConn: l, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, q *dns.Msg) {
		calls.Add(1)
		time.Sleep(30 * time.Millisecond)
		a := new(dns.Msg)
		a.SetReply(q)
		a.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: q.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30}, A: net.ParseIP("203.0.113.9")}}
		w.WriteMsg(a)
	})}
	go server.ActivateAndServe()
	t.Cleanup(func() { server.Shutdown() })
	r := New(Config{DNS: []string{l.LocalAddr().String()}}, nil)
	t.Cleanup(r.Close)
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			a, e := r.query(context.Background(), "cdn.test", dns.TypeA)
			if e != nil {
				t.Error(e)
				return
			}
			a.Id = uint16(i)
			a.Answer[0].(*dns.A).A[0] = byte(i)
		}(i)
	}
	wg.Wait()
	a, e := r.query(context.Background(), "cdn.test", dns.TypeA)
	if e != nil || a.Answer[0].(*dns.A).A.String() != "203.0.113.9" || calls.Load() != 1 {
		t.Fatal(a, e, calls.Load())
	}
}
