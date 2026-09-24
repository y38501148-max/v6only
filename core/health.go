package v6core

import (
	"context"
	"fmt"
	"github.com/miekg/dns"
	"io"
	"net"
	"time"
)

const healthHost = "v6only-health.invalid."
const healthAddress = "198.18.0.2"
const healthPort = 17891
const healthReply = "v6only-tun-ok\n"

// CheckDataPlane deliberately uses ordinary, unprotected sockets. Both probes
// must traverse the OS routes, TUN device, userspace stack and return path.
func CheckDataPlane(ctx context.Context) error {
	d := net.Dialer{Timeout: 2 * time.Second}
	c, e := d.DialContext(ctx, "tcp4", net.JoinHostPort(healthAddress, "17891"))
	if e != nil {
		return e
	}
	c.SetDeadline(time.Now().Add(2 * time.Second))
	b := make([]byte, len(healthReply))
	_, e = io.ReadFull(c, b)
	c.Close()
	if e != nil {
		return e
	}
	if string(b) != healthReply {
		return fmt.Errorf("invalid TUN TCP health reply")
	}
	q := new(dns.Msg)
	q.SetQuestion(healthHost, dns.TypeA)
	ans, _, e := (&dns.Client{Net: "udp4", Timeout: 2 * time.Second}).ExchangeContext(ctx, q, net.JoinHostPort(healthAddress, "53"))
	if e != nil {
		return e
	}
	if ans.Rcode != 0 || len(ans.Answer) != 1 {
		return fmt.Errorf("invalid TUN DNS health reply")
	}
	a, ok := ans.Answer[0].(*dns.A)
	if !ok || a.A.String() != healthAddress {
		return fmt.Errorf("unexpected TUN DNS health address")
	}
	return nil
}

// WatchDataPlane allows initial route setup, then reports two consecutive
// failures. The caller must close the TUN and restore the underlying network.
func (r *Router) WatchDataPlane() <-chan error {
	failed := make(chan error, 1)
	go func() {
		defer close(failed)
		timer := time.NewTicker(3 * time.Second)
		defer timer.Stop()
		deadline := time.Now().Add(30 * time.Second)
		healthy := false
		failures := 0
		for {
			select {
			case <-r.ctx.Done():
				return
			case <-timer.C:
				e := CheckDataPlane(r.ctx)
				if e == nil {
					healthy = true
					failures = 0
					continue
				}
				if r.ctx.Err() != nil {
					return
				}
				failures++
				if (healthy && failures >= 2) || time.Now().After(deadline) {
					failed <- fmt.Errorf("TUN data path failed: %w", e)
					return
				}
			}
		}
	}()
	return failed
}
