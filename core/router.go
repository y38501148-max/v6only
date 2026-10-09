// Package v6core implements IPv6-only forwarding for every domain with AAAA records.
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
	"sync/atomic"
	"syscall"
	"time"

	"github.com/miekg/dns"
)

type Config struct {
	DNS             []string `json:"dns"`
	IPv6DNS         []string `json:"ipv6_dns,omitempty"`
	NeteaseIPv6     bool     `json:"netease_ipv6,omitempty"`
	ChatGPTProxy    string   `json:"chatgpt_proxy,omitempty"`
	ChatGPTIPv4     bool     `json:"chatgpt_ipv4,omitempty"`
	StatsDB         string   `json:"stats_db,omitempty"`
	Interface       string   `json:"interface"`
	FamilyTimeoutMS int      `json:"family_timeout_ms"`
	FakeDNS         bool     `json:"fake_dns"`
	Generation      int64    `json:"generation"`
}
type Flow struct {
	Host          string    `json:"host"`
	Remote        string    `json:"remote"`
	Network       string    `json:"network"`
	Reason        string    `json:"reason"`
	Time          time.Time `json:"time"`
	UploadBytes   int64     `json:"upload_bytes"`
	DownloadBytes int64     `json:"download_bytes"`
	counter       interface{ FlowBytes() (int64, int64) }
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
type dnsCached struct {
	msg   *dns.Msg
	err   error
	until time.Time
}
type dnsPending struct {
	done chan struct{}
	msg  *dns.Msg
	err  error
}
type Router struct {
	queryMu        sync.Mutex
	queryCache     map[string]dnsCached
	queryPending   map[string]*dnsPending
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
	healthy        atomic.Bool
	Log            func(Flow)
	LookupOverride func(context.Context, string) (Result, error)
	DialOverride   func(context.Context, string, string) (net.Conn, error)
	Traffic        *TrafficStore
}

func New(cfg Config, control func(string, string, syscall.RawConn) error) *Router {
	if cfg.FamilyTimeoutMS <= 0 {
		cfg.FamilyTimeoutMS = 5000
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Router{cfg: cfg, ctx: ctx, cancel: cancel, control: control, cache: map[string]cached{}, fake: map[string]string{}, reverse: map[string]reverseEntry{}, fakeReverse: map[string]string{}, next: 1, connections: map[net.Conn]bool{}, queryCache: map[string]dnsCached{}, queryPending: map[string]*dnsPending{}}
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
	f := Flow{Host: host, Remote: c.RemoteAddr().String(), Network: network, Reason: reason, Time: time.Now()}
	f.counter, _ = c.(interface{ FlowBytes() (int64, int64) })
	r.mu.Lock()
	r.flows = append(r.flows, f)
	if len(r.flows) > 512 {
		r.flows = r.flows[len(r.flows)-512:]
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
			if f.counter != nil {
				f.UploadBytes, f.DownloadBytes = f.counter.FlowBytes()
			}
			out = append(out, f)
		}
	}
	return out
}
func (r *Router) JSONFlows(host string) string { b, _ := json.Marshal(r.Flows(host)); return string(b) }
func (r *Router) rawDial(ctx context.Context, network, address string) (net.Conn, error) {
	var c net.Conn
	var e error
	if r.DialOverride != nil {
		c, e = r.DialOverride(ctx, network, address)
	} else {
		c, e = (&net.Dialer{Control: r.control}).DialContext(ctx, network, address)
	}
	if e == nil && r.Traffic != nil {
		c = r.Traffic.Wrap(c)
	}
	return c, e
}
func (r *Router) query(ctx context.Context, host string, qtype uint16) (*dns.Msg, error) {
	key := fmt.Sprintf("%s/%d", strings.ToLower(strings.TrimSuffix(host, ".")), qtype)
	return r.cachedQuery(ctx, key, func() (*dns.Msg, error) { return r.queryOnce(ctx, host, qtype) })
}
func (r *Router) cachedQuery(ctx context.Context, key string, lookup func() (*dns.Msg, error)) (*dns.Msg, error) {
	r.queryMu.Lock()
	if cached, ok := r.queryCache[key]; ok && time.Now().Before(cached.until) {
		r.queryMu.Unlock()
		if cached.msg != nil {
			return cached.msg.Copy(), cached.err
		}
		return nil, cached.err
	}
	if pending := r.queryPending[key]; pending != nil {
		r.queryMu.Unlock()
		select {
		case <-pending.done:
			if pending.msg != nil {
				return pending.msg.Copy(), pending.err
			}
			return nil, pending.err
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	pending := &dnsPending{done: make(chan struct{})}
	r.queryPending[key] = pending
	r.queryMu.Unlock()
	msg, e := lookup()
	ttl := time.Second
	if e == nil {
		ttl = 30 * time.Second
		for _, rr := range append(append([]dns.RR{}, msg.Answer...), msg.Ns...) {
			v := time.Duration(rr.Header().Ttl) * time.Second
			if v < ttl {
				ttl = v
			}
		}
		if ttl < time.Second {
			ttl = time.Second
		}
	}
	r.queryMu.Lock()
	if len(r.queryCache) > 8192 {
		r.queryCache = map[string]dnsCached{}
	}
	// A losing speculative query is canceled as soon as a connection succeeds.
	// Its cancellation is not a DNS failure to cache for the next connection.
	if ctx.Err() == nil {
		r.queryCache[key] = dnsCached{msg: msg, err: e, until: time.Now().Add(ttl)}
	}
	pending.msg = msg
	pending.err = e
	delete(r.queryPending, key)
	close(pending.done)
	r.queryMu.Unlock()
	if msg != nil {
		return msg.Copy(), e
	}
	return nil, e
}
func (r *Router) queryOnce(ctx context.Context, host string, qtype uint16) (*dns.Msg, error) {
	if qtype == dns.TypeAAAA && r.cfg.NeteaseIPv6 && neteaseCDNAlias(host) != "" {
		if answer, err := r.neteaseAAAA(ctx, host); err == nil {
			return answer, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	if qtype == dns.TypeAAAA && (r.cfg.ChatGPTProxy != "" || r.cfg.ChatGPTIPv4) && isChatGPT(host) {
		q := new(dns.Msg)
		q.SetQuestion(dns.Fqdn(host), qtype)
		a := new(dns.Msg)
		a.SetReply(q)
		return a, nil
	}
	normalized := strings.ToLower(strings.TrimSuffix(host, "."))
	if qtype == dns.TypeAAAA && len(r.cfg.IPv6DNS) > 0 && !campusDomain(normalized) {
		campus, e := r.queryServers(ctx, host, qtype, r.cfg.DNS, false)
		if e == nil {
			for _, rr := range campus.Answer {
				if _, ok := rr.(*dns.AAAA); ok {
					return campus, nil
				}
			}
		}
		// Supplement missing public AAAA records, but do not turn a working
		// network resolver's NODATA into SERVFAIL when public DNS is blocked.
		// Leave room for a one-second TCP retry while remaining below
		// Android's DNS retry interval.
		checkCtx := ctx
		if e == nil {
			var cancel context.CancelFunc
			checkCtx, cancel = context.WithTimeout(ctx, 1500*time.Millisecond)
			defer cancel()
		}
		public, publicErr := r.supplementalAAAA(checkCtx, host)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if publicErr != nil && e == nil {
			return campus, nil
		}
		return public, publicErr
	}
	return r.queryServers(ctx, host, qtype, r.cfg.DNS, false)
}

// Supplemental resolvers can be reachable over only one transport. Race their
// TCP/UDP queries within the caller's budget so one dropped SYN cannot consume
// all the time before UDP or the second resolver gets a chance.
func (r *Router) queryPublicServers(ctx context.Context, host string, qtype uint16, servers []string) (*dns.Msg, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	type answer struct {
		msg *dns.Msg
		err error
	}
	results := make(chan answer, 2*len(servers))
	for _, server := range servers {
		for _, proto := range []string{"tcp", "udp"} {
			go func(server, proto string) {
				m, e := r.exchangeDNS(ctx, host, qtype, server, proto)
				results <- answer{m, e}
			}(server, proto)
		}
	}
	var valid *dns.Msg
	var last error
	for range 2 * len(servers) {
		select {
		case a := <-results:
			if a.err != nil {
				last = a.err
				continue
			}
			// NODATA from one resolver must not hide an AAAA response from
			// another. Keep it only if none of the remaining queries finds one.
			for _, rr := range a.msg.Answer {
				if rr.Header().Rrtype == qtype {
					return a.msg, nil
				}
			}
			if valid == nil || a.msg.Rcode == dns.RcodeSuccess {
				valid = a.msg
			}
		case <-ctx.Done():
			if valid != nil {
				return valid, nil
			}
			return nil, ctx.Err()
		}
	}
	if valid != nil {
		return valid, nil
	}
	return nil, fmt.Errorf("DNS lookup %s: %w", host, last)
}

func (r *Router) exchangeDNS(ctx context.Context, host string, qtype uint16, server, proto string) (*dns.Msg, error) {
	return r.exchangeDNSSubnet(ctx, host, qtype, server, proto, nil)
}

func (r *Router) exchangeDNSSubnet(ctx context.Context, host string, qtype uint16, server, proto string, subnet net.IP) (*dns.Msg, error) {
	if _, _, e := net.SplitHostPort(server); e != nil {
		server = net.JoinHostPort(server, "53")
	}
	q := new(dns.Msg)
	q.SetQuestion(dns.Fqdn(host), qtype)
	q.SetEdns0(1232, false)
	if subnet != nil {
		q.IsEdns0().Option = append(q.IsEdns0().Option, &dns.EDNS0_SUBNET{
			Code: dns.EDNS0SUBNET, Family: 2, SourceNetmask: 24,
			Address: append(net.IP(nil), subnet...),
		})
	}
	sub, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	c, e := r.rawDial(sub, proto, server)
	if e != nil {
		return nil, e
	}
	defer c.Close()
	// Cancel losing queries immediately, including already-connected sockets.
	stop := context.AfterFunc(sub, func() { c.Close() })
	defer stop()
	deadline, _ := sub.Deadline()
	if e = c.SetDeadline(deadline); e != nil {
		return nil, e
	}
	ans, _, e := (&dns.Client{Net: proto}).ExchangeWithConnContext(sub, q, &dns.Conn{Conn: c})
	if e != nil {
		return nil, e
	}
	if ans.Truncated {
		return nil, errors.New("truncated DNS response")
	}
	if ans.Rcode != dns.RcodeSuccess && ans.Rcode != dns.RcodeNameError {
		return nil, fmt.Errorf("DNS rcode %d", ans.Rcode)
	}
	return ans, nil
}

func (r *Router) queryServers(ctx context.Context, host string, qtype uint16, servers []string, publicIPv6 bool) (*dns.Msg, error) {
	if len(servers) == 0 {
		return nil, errors.New("no physical DNS servers configured")
	}
	if publicIPv6 {
		return r.queryPublicServers(ctx, host, qtype, servers)
	}
	var last error
	for _, server := range servers {
		for _, proto := range []string{"udp", "tcp"} {
			ans, e := r.exchangeDNS(ctx, host, qtype, server, proto)
			if e == nil {
				return ans, nil
			}
			last = e
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
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
	if r.cfg.ChatGPTProxy != "" && isChatGPT(host) {
		return r.dialChatGPT(ctx, host, port)
	}
	if r.cfg.ChatGPTIPv4 && isChatGPT(host) {
		addresses, e := r.addresses(ctx, host)
		if e != nil {
			return nil, e
		}
		c, e := r.family(ctx, addresses.V4, port, "tcp4")
		if e == nil {
			r.record(host, c, "tcp4", "chatgpt_ipv4")
		}
		return c, e
	}
	addresses, e := r.addresses(ctx, host)
	if e != nil {
		return nil, e
	}
	if len(addresses.V6) > 0 {
		c, e := r.dialIPv6(ctx, host, port, addresses.V6)
		if e != nil {
			return nil, fmt.Errorf("IPv6 required for %s; IPv4 fallback forbidden: %w", host, e)
		}
		r.record(host, c, "tcp6", "ipv6_required")
		return c, nil
	}
	reason := "no_aaaa"
	if net.ParseIP(host) != nil {
		reason = "literal_ipv4"
	}
	c, e := r.family(ctx, addresses.V4, port, "tcp4")
	if e == nil {
		r.record(host, c, "tcp4", reason)
	}
	return c, e
}

// Resolve returns both families without using the system proxy.
func (r *Router) Resolve(ctx context.Context, host string) (Result, error) {
	return r.addresses(ctx, host)
}
