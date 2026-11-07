package v6core

import (
	"context"
	"errors"
	"net"
	"os"
	"time"
)

const (
	DefaultRacePorts = 6
	racePortBase     = 20000
	racePortEnd      = 32000
	racePortStep     = 8
	raceStagger      = 25 * time.Millisecond
)

// RaceConfig controls the primary public IPv6 TCP attempt. A nil config uses
// DefaultRacePorts. Ports 0 and 1 disable source-port racing.
type RaceConfig struct {
	Ports int `json:"ports"`
}

func (r *Router) canRace(ip net.IP) bool {
	return r.racePorts > 1 && r.DialOverride == nil &&
		ip.To4() == nil && ip.IsGlobalUnicast() && !ip.IsPrivate()
}

// raceDial adds at most five attempts to the primary address. Other DNS
// answers retain their existing single attempt and share the family deadline.
func (r *Router) raceDial(ctx context.Context, address string) (net.Conn, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	window := (r.raceWindow.Add(1) - 1) % ((racePortEnd - racePortBase) / racePortStep)
	base := racePortBase + int(window)*racePortStep
	type result struct {
		conn net.Conn
		err  error
	}
	results := make(chan result)
	launch := func(port int) {
		go func() {
			c, err := r.socketDial(ctx, "tcp6", address, port)
			var bindErr *os.SyscallError
			if errors.As(err, &bindErr) && bindErr.Syscall == "bind" {
				// The explicit port can already be in use or reserved by the OS.
				c, err = r.rawDial(ctx, "tcp6", address)
			}
			select {
			case results <- result{c, err}:
			case <-ctx.Done():
				if c != nil {
					c.Close()
				}
			}
		}()
	}

	launch(base)
	timer := time.NewTimer(raceStagger)
	defer timer.Stop()
	launched, failed := 1, 0
	var last error
	for failed < r.racePorts {
		select {
		case res := <-results:
			if res.err == nil {
				return res.conn, nil
			}
			last = res.err
			failed++
		case <-timer.C:
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			launch(base + launched)
			launched++
			if launched < r.racePorts {
				timer.Reset(raceStagger)
			}
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return nil, last
}
