package v6core

import (
	"context"
	"encoding/binary"
	"github.com/miekg/dns"
	"io"
	"log"
	"net"
	"strings"
	"time"
)

func (r *Router) DNS(ctx context.Context, wire []byte) []byte {
	q := new(dns.Msg)
	if q.Unpack(wire) != nil || len(q.Question) != 1 {
		return nil
	}
	a := new(dns.Msg)
	a.SetReply(q)
	a.RecursionAvailable = true
	question := q.Question[0]
	host := strings.TrimSuffix(strings.ToLower(question.Name), ".")
	if question.Name == healthHost && question.Qtype == dns.TypeA && question.Qclass == dns.ClassINET {
		a.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: healthHost, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 0}, A: net.ParseIP(healthAddress)}}
		b, _ := a.Pack()
		return b
	}
	if question.Qclass != dns.ClassINET {
		a.Rcode = dns.RcodeRefused
	} else if question.Qtype == dns.TypeA || question.Qtype == dns.TypeAAAA {
		// Preserve upstream NXDOMAIN/NODATA instead of turning absent names into
		// SERVFAIL or inventing an IPv4 answer for an IPv6-only origin.
		var upstream *dns.Msg
		var e error
		var found Result
		if r.LookupOverride != nil {
			found, e = r.lookup(ctx, host)
		} else {
			upstream, e = r.query(ctx, host, question.Qtype)
		}
		if e == nil && upstream != nil && upstream.Rcode == dns.RcodeNameError {
			a = upstream
			a.Id = q.Id
			b, _ := a.Pack()
			return b
		}
		if e == nil && upstream != nil {
			found, e = r.lookup(ctx, host)
			if e != nil && !r.cfg.FakeDNS {
				// Desktop DNS must remain usable when only the other record family
				// times out. Preserve the answer we actually obtained.
				upstream.Id = q.Id
				b, _ := upstream.Pack()
				return b
			}
		}
		if e != nil {
			log.Printf("DNS forwarding failed: %v", e)
			a.Rcode = dns.RcodeServerFailure
		} else {
			hdr := dns.RR_Header{Name: question.Name, Rrtype: question.Qtype, Class: dns.ClassINET, Ttl: uint32(found.TTL / time.Second)}
			if question.Qtype == dns.TypeA {
				if r.cfg.FakeDNS && len(found.V4)+len(found.V6) > 0 {
					ip, e := r.fakeIP(host)
					if e != nil {
						a.Rcode = dns.RcodeServerFailure
					} else {
						a.Answer = []dns.RR{&dns.A{Hdr: hdr, A: ip}}
					}
				} else {
					for _, ip := range found.V4 {
						a.Answer = append(a.Answer, &dns.A{Hdr: hdr, A: ip})
					}
				}
			} else {
				for _, ip := range found.V6 {
					a.Answer = append(a.Answer, &dns.AAAA{Hdr: hdr, AAAA: ip})
				}
			}
		}
	} else if question.Qtype == dns.TypeHTTPS || question.Qtype == dns.TypeSVCB { // Avoid ECH/IP hints bypassing the domain-to-flow mapping.
	} else {
		v, e := r.query(ctx, host, question.Qtype)
		if e != nil {
			a.Rcode = dns.RcodeServerFailure
		} else {
			a = v
			a.Id = q.Id
		}
	}
	b, _ := a.Pack()
	return b
}
func (r *Router) dnsTCP(c net.Conn) {
	defer r.untrack(c)
	for {
		c.SetReadDeadline(time.Now().Add(30 * time.Second))
		var n uint16
		if binary.Read(c, binary.BigEndian, &n) != nil || n < 12 {
			return
		}
		b := make([]byte, n)
		if _, e := io.ReadFull(c, b); e != nil {
			return
		}
		ans := r.DNS(r.ctx, b)
		if len(ans) == 0 {
			return
		}
		if binary.Write(c, binary.BigEndian, uint16(len(ans))) != nil {
			return
		}
		if _, e := c.Write(ans); e != nil {
			return
		}
	}
}
func (r *Router) ServeDNS(address string) (func(), error) {
	udp, e := net.ListenPacket("udp", address)
	if e != nil {
		return nil, e
	}
	tcp, e := net.Listen("tcp", address)
	if e != nil {
		udp.Close()
		return nil, e
	}
	go func() {
		for {
			buf := make([]byte, 65535)
			n, from, e := udp.ReadFrom(buf)
			if e != nil {
				return
			}
			go func(b []byte, a net.Addr) {
				reply := r.DNS(r.ctx, b)
				if len(reply) > 0 {
					udp.WriteTo(reply, a)
				}
			}(buf[:n], from)
		}
	}()
	go func() {
		for {
			c, e := tcp.Accept()
			if e != nil {
				return
			}
			if r.track(c) {
				go r.dnsTCP(c)
			}
		}
	}()
	return func() { udp.Close(); tcp.Close() }, nil
}
