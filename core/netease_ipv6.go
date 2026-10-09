package v6core

import (
	"context"
	"errors"
	"net"
	"strings"
	"time"

	"github.com/miekg/dns"
)

// Keep the allowlist narrow: these audio hosts have a verified official Aliyun
// CDN alias. The URL, HTTP Host, TLS SNI and certificate verification stay with
// the original host. This feature neither rewrites songs nor decrypts HTTPS.
func neteaseCDNAlias(host string) string {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	switch host {
	case "m701.music.126.net", "m801.music.126.net":
		return host + ".w.alikunlun.com"
	}
	return ""
}

func (r *Router) neteaseAAAA(ctx context.Context, host string) (*dns.Msg, error) {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	alias := neteaseCDNAlias(host)
	if alias == "" || len(r.cfg.IPv6DNS) == 0 {
		return nil, errors.New("no NetEase IPv6 CDN resolver configured")
	}
	return r.cachedQuery(ctx, "netease/"+host, func() (*dns.Msg, error) {
		ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
		defer cancel()
		// Public carrier prefixes are CDN location hints, not the user's IP.
		// The default mapping can return IPv4-only or unreachable Telecom edges.
		// Resolve current Mobile/Unicom endpoints instead of pinning expiring IPs.
		hints := []string{"2409:8c00::", "2408:8000::"}
		type result struct {
			msg  *dns.Msg
			err  error
			hint string
		}
		count := len(r.cfg.IPv6DNS) * len(hints) * 2
		answers := make(chan result, count)
		for _, server := range r.cfg.IPv6DNS {
			for _, proto := range []string{"udp", "tcp"} {
				for _, hint := range hints {
					go func(server, proto, hint string) {
						msg, err := r.exchangeDNSSubnet(ctx, alias, dns.TypeAAAA, server, proto, net.ParseIP(hint))
						answers <- result{msg, err, hint}
					}(server, proto, hint)
				}
			}
		}
		q := new(dns.Msg)
		q.SetQuestion(dns.Fqdn(host), dns.TypeAAAA)
		out := new(dns.Msg)
		out.SetReply(q)
		out.RecursionAvailable = true
		seen := make(map[string]bool)
		hintAnswers := make(map[string]bool)
		var collect <-chan time.Time
		var timer *time.Timer
		defer func() {
			if timer != nil {
				timer.Stop()
			}
		}()
		for range count {
			select {
			case answer := <-answers:
				if answer.err != nil || answer.msg.Rcode != dns.RcodeSuccess {
					continue
				}
				for _, rr := range answer.msg.Answer {
					a, ok := rr.(*dns.AAAA)
					if !ok || a.AAAA.To4() != nil || !a.AAAA.IsGlobalUnicast() || a.AAAA.IsPrivate() {
						continue
					}
					hintAnswers[answer.hint] = true
					if seen[a.AAAA.String()] {
						continue
					}
					seen[a.AAAA.String()] = true
					out.Answer = append(out.Answer, &dns.AAAA{
						Hdr:  dns.RR_Header{Name: dns.Fqdn(host), Rrtype: dns.TypeAAAA, Class: dns.ClassINET, Ttl: min(a.Hdr.Ttl, 30)},
						AAAA: append(net.IP(nil), a.AAAA...),
					})
				}
				if len(hintAnswers) == len(hints) {
					return out, nil
				}
				// Give another carrier a short chance to contribute reachable
				// alternatives; the connector races all returned IPv6 addresses.
				if len(out.Answer) != 0 && timer == nil {
					timer = time.NewTimer(250 * time.Millisecond)
					collect = timer.C
				}
			case <-collect:
				return out, nil
			case <-ctx.Done():
				if len(out.Answer) != 0 {
					return out, nil
				}
				return nil, ctx.Err()
			}
		}
		if len(out.Answer) != 0 {
			return out, nil
		}
		return nil, errors.New("no public IPv6 address from NetEase CDN aliases")
	})
}
