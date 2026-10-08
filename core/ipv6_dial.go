package v6core

import (
	"context"
	"errors"
	"net"
	"strings"
	"time"

	"github.com/miekg/dns"
)

func campusDomain(host string) bool {
	return host == "buaa.edu.cn" || strings.HasSuffix(host, ".buaa.edu.cn") || strings.HasSuffix(host, ".local")
}

func (r *Router) supplementalAAAA(ctx context.Context, host string) (*dns.Msg, error) {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	return r.cachedQuery(ctx, "public/"+host, func() (*dns.Msg, error) {
		return r.queryPublicServers(ctx, host, dns.TypeAAAA, r.cfg.IPv6DNS)
	})
}

// A resolver can send us to an unreachable CDN edge even though another IPv6
// edge is healthy. Give the network answer a head start, then try supplemental
// AAAA addresses within the same connection budget. Never dial an A record.
func (r *Router) dialIPv6(ctx context.Context, host, port string, primary []net.IP) (net.Conn, error) {
	name := strings.ToLower(strings.TrimSuffix(host, "."))
	if net.ParseIP(name) != nil {
		name = r.domain(name)
	}
	if name == "" || campusDomain(name) || len(r.cfg.IPv6DNS) == 0 {
		return r.family(ctx, primary, port, "tcp6")
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(r.cfg.FamilyTimeoutMS)*time.Millisecond)
	defer cancel()
	type result struct {
		conn net.Conn
		err  error
	}
	answers := make(chan result)
	run := func(dial func() (net.Conn, error)) {
		go func() {
			c, e := dial()
			select {
			case answers <- result{c, e}:
			case <-ctx.Done():
				if c != nil {
					c.Close()
				}
			}
		}()
	}
	run(func() (net.Conn, error) { return r.family(ctx, primary, port, "tcp6") })
	timer := time.NewTimer(250 * time.Millisecond)
	defer timer.Stop()
	pending, launched := 1, false
	launchAlternate := func() {
		launched = true
		pending++
		run(func() (net.Conn, error) {
			queryCtx, stop := context.WithTimeout(ctx, 1500*time.Millisecond)
			defer stop()
			msg, e := r.supplementalAAAA(queryCtx, name)
			if e != nil {
				return nil, e
			}
			ips := []net.IP{}
			ttl := 30 * time.Second
			for _, rr := range msg.Answer {
				if v := time.Duration(rr.Header().Ttl) * time.Second; v < ttl {
					ttl = v
				}
				if a, ok := rr.(*dns.AAAA); ok {
					duplicate := false
					for _, ip := range primary {
						if ip.Equal(a.AAAA) {
							duplicate = true
							break
						}
					}
					if !duplicate {
						ips = append(ips, a.AAAA)
					}
				}
			}
			if len(ips) == 0 {
				return nil, errors.New("no additional IPv6 addresses")
			}
			c, e := r.family(ctx, ips, port, "tcp6")
			if e == nil {
				// Reuse the working edge for subsequent connections, only while
				// both the original and supplemental DNS answers remain valid.
				r.mu.Lock()
				if entry, ok := r.cache[name]; ok && time.Now().Before(entry.until) {
					merged := append([]net.IP{}, entry.result.V6...)
					for _, ip := range ips {
						seen := false
						for _, old := range merged {
							if old.Equal(ip) {
								seen = true
								break
							}
						}
						if !seen {
							merged = append(merged, ip)
						}
					}
					entry.result.V6 = merged
					if until := time.Now().Add(ttl); until.Before(entry.until) {
						entry.until = until
					}
					r.cache[name] = entry
				}
				r.mu.Unlock()
			}
			return c, e
		})
	}
	var last error
	for pending > 0 {
		select {
		case a := <-answers:
			pending--
			if a.err == nil {
				return a.conn, nil
			}
			last = a.err
			if !launched {
				timer.Stop()
				launchAlternate()
			}
		case <-timer.C:
			if !launched {
				launchAlternate()
			}
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return nil, last
}
