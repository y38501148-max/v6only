package v6core

import (
	"context"
	"errors"
	"fmt"
	tcore "github.com/xjasonlyu/tun2socks/v2/core"
	"github.com/xjasonlyu/tun2socks/v2/core/adapter"
	"github.com/xjasonlyu/tun2socks/v2/core/device"
	"github.com/xjasonlyu/tun2socks/v2/core/device/fdbased"
	"github.com/xjasonlyu/tun2socks/v2/core/device/tun"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"sync"
	"time"
)

type Tunnel struct {
	Device    device.Device
	Stack     *stack.Stack
	Router    *Router
	closeOnce sync.Once
}

// ownedDevice permits both explicit shutdown and stack NIC removal to close
// the link safely. Drivers such as fdbased.Close are not themselves idempotent.
type ownedDevice struct {
	device.Device
	once sync.Once
}

func (d *ownedDevice) Close() { d.once.Do(d.Device.Close) }

func (r *Router) StartDevice(name string, fd int) (*Tunnel, error) {
	var d device.Device
	var e error
	if fd >= 0 {
		d, e = fdbased.Open(strconv.Itoa(fd), 1500, 0)
		if e != nil {
			os.NewFile(uintptr(fd), "tun").Close()
		}
	} else {
		d, e = tun.Open(name, 1500)
	}
	if e != nil {
		return nil, e
	}
	d = &ownedDevice{Device: d}
	s, e := tcore.CreateStack(&tcore.Config{LinkEndpoint: d, TransportHandler: r})
	if e != nil {
		d.Close()
		return nil, e
	}
	return &Tunnel{Device: d, Stack: s, Router: r}, nil
}
func (t *Tunnel) Close() {
	t.closeOnce.Do(func() {
		t.Router.Close()
		// Stop readers before closing their descriptor. Explicit close unblocks
		// the macOS/Windows IO reader; NIC removal then closes the same owned
		// device safely without touching a descriptor that has been reused.
		t.Device.Attach(nil)
		t.Device.Close()
		t.Stack.Close()
		t.Stack.Wait()
	})
}

func (r *Router) HandleTCP(c adapter.TCPConn) {
	if r.track(c) {
		go r.tcp(c)
	}
}
func (r *Router) tcp(c adapter.TCPConn) {
	defer r.untrack(c)
	id := c.ID()
	ip := net.IP(id.LocalAddress.AsSlice())
	port := id.LocalPort
	if ip.String() == healthAddress && port == healthPort {
		c.SetWriteDeadline(time.Now().Add(2 * time.Second))
		io.WriteString(c, healthReply)
		return
	}
	if port == 53 {
		r.dnsTCP(c)
		return
	}
	host := r.domain(ip.String())
	var conn net.Conn = c
	if !isFake(ip) {
		var s string
		conn, s = sniff(c, port)
		if validHost(s) {
			host = s
		}
	}
	if host == "" {
		host = ip.String()
	}
	remote, e := r.Dial(r.ctx, host, strconv.Itoa(int(port)))
	if e != nil {
		log.Printf("TCP forwarding failed for %s:%d: %v", host, port, e)
		return
	}
	if !r.track(remote) {
		return
	}
	defer r.untrack(remote)
	Relay(conn, remote)
}
func Relay(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	copyOne := func(dst, src net.Conn) {
		defer wg.Done()
		io.Copy(dst, src)
		if c, ok := dst.(interface{ CloseWrite() error }); ok {
			c.CloseWrite()
		} else {
			dst.SetReadDeadline(time.Now().Add(2 * time.Second))
		}
		src.SetReadDeadline(time.Now().Add(5 * time.Second))
	}
	go copyOne(a, b)
	go copyOne(b, a)
	wg.Wait()
}
func (r *Router) HandleUDP(c adapter.UDPConn) {
	if r.track(c) {
		go r.udp(c)
	}
}
func (r *Router) udp(c adapter.UDPConn) {
	defer r.untrack(c)
	id := c.ID()
	ip := net.IP(id.LocalAddress.AsSlice())
	port := id.LocalPort
	if port == 53 {
		b := make([]byte, 65535)
		for {
			c.SetReadDeadline(time.Now().Add(30 * time.Second))
			n, e := c.Read(b)
			if e != nil {
				return
			}
			ans := r.DNS(r.ctx, b[:n])
			if len(ans) > 0 {
				if _, e = c.Write(ans); e != nil {
					return
				}
			}
		}
	}
	host := r.domain(ip.String())
	if host == "" {
		if ip.To4() != nil && port == 443 {
			return
		}
		host = ip.String()
	}
	first := make([]byte, 65535)
	c.SetReadDeadline(time.Now().Add(30 * time.Second))
	n, e := c.Read(first)
	if e != nil {
		return
	}
	first = first[:n]
	remote, response, e := r.OpenUDP(r.ctx, host, strconv.Itoa(int(port)), first)
	if e != nil {
		log.Printf("UDP forwarding failed: %v", e)
		return
	}
	if !r.track(remote) {
		return
	}
	defer r.untrack(remote)
	if len(response) > 0 {
		if _, e = c.Write(response); e != nil {
			return
		}
	}
	var wg sync.WaitGroup
	wg.Add(2)
	pump := func(dst, src net.Conn) {
		defer wg.Done()
		defer dst.SetReadDeadline(time.Now())
		buf := make([]byte, 65535)
		for {
			src.SetReadDeadline(time.Now().Add(60 * time.Second))
			n, e := src.Read(buf)
			if e != nil {
				return
			}
			if _, e = dst.Write(buf[:n]); e != nil {
				return
			}
		}
	}
	go pump(c, remote)
	go pump(remote, c)
	wg.Wait()
}

// UDP connect() cannot prove reachability. Wait for an actual first response.
// Retry the initial datagram only while establishing a flow, never race v4 with v6.
func (r *Router) OpenUDP(ctx context.Context, host, port string, first []byte) (net.Conn, []byte, error) {
	if (r.cfg.ChatGPTProxy != "" || r.cfg.ChatGPTIPv4) && isChatGPT(host) {
		return nil, nil, fmt.Errorf("ChatGPT uses TCP through its IPv4 proxy")
	}
	result, e := r.addresses(ctx, host)
	if e != nil {
		return nil, nil, e
	}
	var last error = errors.New("no UDP addresses")
	families := [][]net.IP{result.V6, nil}
	if len(result.V6) == 0 {
		families[1] = result.V4
	}
	for family, ips := range families {
		budget := time.Duration(r.cfg.FamilyTimeoutMS) * time.Millisecond
		if len(ips) == 0 {
			continue
		}
		per := budget / time.Duration(len(ips))
		if per < 250*time.Millisecond {
			per = 250 * time.Millisecond
		}
		for _, ip := range ips {
			network := "udp6"
			reason := "ipv6_response"
			if family == 1 {
				network = "udp4"
				reason = "no_aaaa"
			}
			sub, cancel := context.WithTimeout(ctx, per)
			c, e := r.rawDial(sub, network, net.JoinHostPort(ip.String(), port))
			if e == nil {
				c.SetDeadline(time.Now().Add(per))
				_, e = c.Write(first)
				if e == nil {
					buf := make([]byte, 65535)
					var n int
					n, e = c.Read(buf)
					if e == nil {
						cancel()
						c.SetDeadline(time.Time{})
						r.record(host, c, network, reason)
						return c, buf[:n], nil
					}
					// An unanswered arbitrary UDP datagram may already have been
					// processed. Do not replay it at another IP/family. QUIC and NTP
					// have protocol-level duplicate handling and explicit responses.
					if timeout, ok := e.(net.Error); ok && timeout.Timeout() && port != "443" && port != "123" && ctx.Err() == nil {
						cancel()
						c.SetDeadline(time.Time{})
						r.record(host, c, network, "udp_response_pending")
						return c, nil, nil
					}
				}
				c.Close()
			}
			cancel()
			last = e
			if ctx.Err() != nil {
				return nil, nil, ctx.Err()
			}
		}
	}
	return nil, nil, fmt.Errorf("UDP unreachable: %w", last)
}
