// Package v6core implements strict IPv6-before-IPv4 forwarding.
package v6core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/miekg/dns"
)

type Config struct {
	DNS             []string `json:"dns"`
	Interface       string   `json:"interface"`
	FamilyTimeoutMS int      `json:"family_timeout_ms"`
	FakeDNS         bool     `json:"fake_dns"`
}
type Flow struct {
	Host    string    `json:"host"`
	Remote  string    `json:"remote"`
	Network string    `json:"network"`
	Reason  string    `json:"reason"`
	Time    time.Time `json:"time"`
}
type Result struct {
	V6, V4 []net.IP
	TTL    time.Duration
}
type cached struct {
	result Result
	until  time.Time
}
type reverseEntry struct {
	host  string
	until time.Time
}
type Router struct {
	cfg            Config
	ctx            context.Context
	cancel         context.CancelFunc
	control        func(string, string, syscall.RawConn) error
	mu             sync.Mutex
	cache          map[string]cached
	fake           map[string]string
	reverse        map[string]reverseEntry
	fakeReverse    map[string]string
	next           uint32
	flows          []Flow
	connections    map[net.Conn]bool
	Log            func(Flow)
	LookupOverride func(context.Context, string) (Result, error)
	DialOverride   func(context.Context, string, string) (net.Conn, error)
}

func New(cfg Config, control func(string, string, syscall.RawConn) error) *Router {
	if cfg.FamilyTimeoutMS <= 0 {
		cfg.FamilyTimeoutMS = 5000
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Router{cfg: cfg, ctx: ctx, cancel: cancel, control: control, cache: map[string]cached{}, fake: map[string]string{}, reverse: map[string]reverseEntry{}, fakeReverse: map[string]string{}, next: 1, connections: map[net.Conn]bool{}}
}
func (r *Router) Close() {
	r.cancel()
	r.mu.Lock()
	connections := make([]net.Conn, 0, len(r.connections))
	for c := range r.connections {
		connections = append(connections, c)
	}
	r.mu.Unlock()
	for _, c := range connections {
		c.Close()
	}
}
func (r *Router) track(c net.Conn) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.ctx.Err() != nil {
		c.Close()
		return false
	}
	r.connections[c] = true
	return true
}
func (r *Router) untrack(c net.Conn) { r.mu.Lock(); delete(r.connections, c); r.mu.Unlock(); c.Close() }
func (r *Router) record(host string, c net.Conn, network, reason string) {
	f := Flow{host, c.RemoteAddr().String(), network, reason, time.Now()}
	r.mu.Lock()
	r.flows = append(r.flows, f)
	if len(r.flows) > 128 {
		r.flows = r.flows[len(r.flows)-128:]
	}
	r.mu.Unlock()
	if r.Log != nil {
		r.Log(f)
	}
}
func (r *Router) Flows(host string) []Flow {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := []Flow{}
	for _, f := range r.flows {
		if host == "" || f.Host == host {
			out = append(out, f)
		}
	}
	return out
}
func (r *Router) JSONFlows(host string) string { b, _ := json.Marshal(r.Flows(host)); return string(b) }
func (r *Router) rawDial(ctx context.Context, network, address string) (net.Conn, error) {
	if r.DialOverride != nil {
		return r.DialOverride(ctx, network, address)
	}
	d := net.Dialer{Control: r.control}
	return d.DialContext(ctx, network, address)
}
func (r *Router) query(ctx context.Context, host string, qtype uint16) (*dns.Msg, error) {
	if len(r.cfg.DNS) == 0 {
		return nil, errors.New("no physical DNS servers configured")
	}
	var last error
	for _, server := range r.cfg.DNS {
		if _, _, e := net.SplitHostPort(server); e != nil {
			server = net.JoinHostPort(server, "53")
		}
		q := new(dns.Msg)
		q.SetQuestion(dns.Fqdn(host), qtype)
		q.SetEdns0(1232, false)
		for _, proto := range []string{"udp", "tcp"} {
			sub, cancel := context.WithTimeout(ctx, 2*time.Second)
			c, e := r.rawDial(sub, proto, server)
			if e == nil {
				e = c.SetDeadline(time.Now().Add(2 * time.Second))
				if e == nil {
					var ans *dns.Msg
					ans, _, e = (&dns.Client{Net: proto}).ExchangeWithConnContext(sub, q, &dns.Conn{Conn: c})
					c.Close()
					cancel()
					if e == nil {
						if ans.Truncated && proto == "udp" {
							continue
						}
						if ans.Rcode == dns.RcodeSuccess || ans.Rcode == dns.RcodeNameError {
							return ans, nil
						}
						e = fmt.Errorf("DNS rcode %d", ans.Rcode)
					}
				} else {
					c.Close()
				}
			}
			cancel()
			last = e
			break
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	return nil, fmt.Errorf("DNS lookup %s: %w", host, last)
}
func (r *Router) lookup(ctx context.Context, host string) (Result, error) {
	if r.LookupOverride != nil {
		return r.LookupOverride(ctx, host)
	}
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	r.mu.Lock()
	entry, ok := r.cache[host]
	r.mu.Unlock()
	if ok && time.Now().Before(entry.until) {
		return entry.result, nil
	}
	type answer struct {
		msg *dns.Msg
		err error
		v6  bool
	}
	ch := make(chan answer, 2)
	for _, t := range []uint16{dns.TypeAAAA, dns.TypeA} {
		go func(t uint16) { m, e := r.query(ctx, host, t); ch <- answer{m, e, t == dns.TypeAAAA} }(t)
	}
	result := Result{TTL: 60 * time.Second}
	var aerr, error6 error
	for i := 0; i < 2; i++ {
		a := <-ch
		if a.err != nil {
			if a.v6 {
				error6 = a.err
			} else {
				aerr = a.err
			}
			continue
		}
		for _, rr := range a.msg.Answer {
			ttl := time.Duration(rr.Header().Ttl) * time.Second
			if ttl < result.TTL {
				result.TTL = ttl
			}
			switch x := rr.(type) {
			case *dns.A:
				result.V4 = append(result.V4, x.A)
			case *dns.AAAA:
				result.V6 = append(result.V6, x.AAAA)
			}
		}
	}
	// A failed AAAA query is not proof that the destination is IPv4-only.
	if error6 != nil {
		return Result{}, error6
	}
	if len(result.V6) == 0 && aerr != nil {
		return Result{}, aerr
	}
	if result.TTL < time.Second {
		result.TTL = time.Second
	}
	r.mu.Lock()
	if len(r.cache) > 4096 {
		r.cache = map[string]cached{}
	}
	if len(r.reverse) > 8192 {
		r.reverse = map[string]reverseEntry{}
	}
	r.cache[host] = cached{result, time.Now().Add(result.TTL)}
	for _, ip := range append(append([]net.IP{}, result.V6...), result.V4...) {
		entry, ok := r.reverse[ip.String()]
		// Shared CDN IPs are ambiguous. Never redirect a literal address to a
		// different origin based on whichever DNS reply happened to arrive last.
		name := host
		if ok && time.Now().Before(entry.until) && entry.host != host {
			name = ""
		}
		r.reverse[ip.String()] = reverseEntry{name, time.Now().Add(result.TTL)}
	}
	r.mu.Unlock()
	return result, nil
}
func (r *Router) domain(ip string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if host := r.fakeReverse[ip]; host != "" {
		return host
	}
	if entry, ok := r.reverse[ip]; ok && time.Now().Before(entry.until) {
		return entry.host
	}
	return ""
}
func (r *Router) fakeIP(host string) (net.IP, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if ip, ok := r.fake[host]; ok {
		return net.ParseIP(ip), nil
	}
	if r.next >= 65534 {
		return nil, errors.New("fake address pool full; restart on network change")
	}
	n := r.next
	r.next++
	ip := net.IPv4(198, 19, byte(n>>8), byte(n))
	r.fake[host] = ip.String()
	r.fakeReverse[ip.String()] = host
	return ip, nil
}
func isFake(ip net.IP) bool {
	a, ok := netip.AddrFromSlice(ip)
	return ok && netip.MustParsePrefix("198.19.0.0/16").Contains(a.Unmap())
}
func (r *Router) addresses(ctx context.Context, host string) (Result, error) {
	if ip := net.ParseIP(host); ip != nil {
		if domain := r.domain(ip.String()); domain != "" {
			return r.lookup(ctx, domain)
		}
		if isFake(ip) {
			return Result{}, errors.New("unknown fake address")
		}
		if ip.To4() != nil {
			return Result{V4: []net.IP{ip}}, nil
		}
		return Result{V6: []net.IP{ip}}, nil
	}
	return r.lookup(ctx, host)
}
func (r *Router) family(ctx context.Context, ips []net.IP, port, network string) (net.Conn, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if len(ips) == 0 {
		return nil, errors.New("no addresses")
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(r.cfg.FamilyTimeoutMS)*time.Millisecond)
	defer cancel()
	type result struct {
		c net.Conn
		e error
	}
	ch := make(chan result)
	var wg sync.WaitGroup
	for _, ip := range ips {
		wg.Add(1)
		go func(ip net.IP) {
			defer wg.Done()
			c, e := r.rawDial(ctx, network, net.JoinHostPort(ip.String(), port))
			select {
			case ch <- result{c, e}:
			case <-ctx.Done():
				if c != nil {
					c.Close()
				}
			}
		}(ip)
	}
	var last error
	for range ips {
		select {
		case v := <-ch:
			if v.e == nil {
				return v.c, nil
			}
			last = v.e
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return nil, last
}
func (r *Router) Dial(ctx context.Context, host, port string) (net.Conn, error) {
	addresses, e := r.addresses(ctx, host)
	if e != nil {
		return nil, e
	}
	reason := "ipv6_available"
	c, e := r.family(ctx, addresses.V6, port, "tcp6")
	if e == nil {
		r.record(host, c, "tcp6", reason)
		return c, nil
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if len(addresses.V6) == 0 {
		reason = "no_aaaa"
		if net.ParseIP(host) != nil {
			reason = "literal_or_unidentified_ipv4"
		}
	} else {
		reason = "all_ipv6_attempts_failed"
	}
	c, e = r.family(ctx, addresses.V4, port, "tcp4")
	if e == nil {
		r.record(host, c, "tcp4", reason)
	}
	return c, e
}
