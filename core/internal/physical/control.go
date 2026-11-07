package physical

import (
	"net"
	"syscall"
)

// Control binds outbound sockets before connect so the TUN cannot capture them.
func Control(iface *net.Interface) func(string, string, syscall.RawConn) error {
	return func(network, address string, raw syscall.RawConn) error {
		host, _, _ := net.SplitHostPort(address)
		ip := net.ParseIP(host)
		if ip != nil && !ip.IsGlobalUnicast() {
			return nil
		}
		var bindErr error
		if err := raw.Control(func(fd uintptr) {
			bindErr = bind(fd, network, ip, iface)
		}); err != nil {
			return err
		}
		return bindErr
	}
}
