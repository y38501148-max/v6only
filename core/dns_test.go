package v6core

import (
	"context"
	"github.com/miekg/dns"
	"net"
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
