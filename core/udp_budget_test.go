package v6core

import (
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"net"
	"testing"
	"time"
)

type budgetUDP struct {
	net.Conn
	id stack.TransportEndpointID
}

func (c *budgetUDP) ID() *stack.TransportEndpointID { return &c.id }
func (c *budgetUDP) ReadFrom(b []byte) (int, net.Addr, error) {
	n, e := c.Read(b)
	return n, c.RemoteAddr(), e
}
func (c *budgetUDP) WriteTo(b []byte, _ net.Addr) (int, error) { return c.Write(b) }
func budgetConn(t *testing.T, ip string, port uint16) (*budgetUDP, net.Conn) {
	t.Helper()
	a, b := net.Pipe()
	t.Cleanup(func() { a.Close(); b.Close() })
	parsed := net.ParseIP(ip)
	var addr tcpip.Address
	if v4 := parsed.To4(); v4 != nil {
		addr = tcpip.AddrFrom4Slice(v4)
	} else {
		addr = tcpip.AddrFrom16Slice(parsed)
	}
	return &budgetUDP{a, stack.TransportEndpointID{LocalAddress: addr, LocalPort: port}}, b
}
func TestUDPLocalDestinationsDroppedWithoutSlots(t *testing.T) {
	r := New(Config{}, nil)
	defer r.Close()
	for _, ip := range []string{"255.255.255.255", "224.0.0.251", "ff02::fb", "169.254.1.2", "fe80::1", "127.0.0.1", "::1", "0.0.0.0", "::"} {
		c, peer := budgetConn(t, ip, 22222)
		r.HandleUDP(c)
		peer.SetReadDeadline(time.Now().Add(time.Second))
		if _, err := peer.Read(make([]byte, 1)); err == nil {
			t.Fatal("local flow accepted", ip)
		} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
			t.Fatal("local flow not closed", ip)
		}
	}
	if len(r.udpSlots) != 0 || len(r.dnsSlots) != 0 {
		t.Fatal("dropped flow consumed capacity")
	}
}
func TestUDPSaturationReservesDNSAndReleasesCapacity(t *testing.T) {
	r := New(Config{}, nil)
	defer r.Close()
	for i := 0; i < 256; i++ {
		c, _ := budgetConn(t, "192.0.2.1", 22222)
		r.HandleUDP(c)
	}
	rejected, peer := budgetConn(t, "192.0.2.2", 22222)
	r.HandleUDP(rejected)
	peer.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := peer.Read(make([]byte, 1)); err == nil {
		t.Fatal("overflow accepted")
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("overflow not closed")
	}
	dns, _ := budgetConn(t, "192.0.2.53", 53)
	r.HandleUDP(dns)
	if len(r.dnsSlots) != 1 {
		t.Fatal("P2P saturation blocked DNS")
	}
	other := New(Config{}, nil)
	defer other.Close()
	another, _ := budgetConn(t, "192.0.2.3", 22222)
	other.HandleUDP(another)
	if len(other.udpSlots) != 1 {
		t.Fatal("budgets interfere")
	}
	r.Close()
	until := time.Now().Add(2 * time.Second)
	for (len(r.udpSlots) > 0 || len(r.dnsSlots) > 0) && time.Now().Before(until) {
		time.Sleep(time.Millisecond)
	}
	if len(r.udpSlots) != 0 || len(r.dnsSlots) != 0 {
		t.Fatal("shutdown leaked slots")
	}
	closed, _ := budgetConn(t, "192.0.2.4", 22222)
	r.HandleUDP(closed)
	if len(r.udpSlots) != 0 {
		t.Fatal("stopped core leaked slots")
	}
}
