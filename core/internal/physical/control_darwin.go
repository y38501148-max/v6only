package physical

import (
	"net"

	"golang.org/x/sys/unix"
)

func bind(fd uintptr, network string, _ net.IP, iface *net.Interface) error {
	switch network {
	case "tcp4", "udp4":
		return unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, iface.Index)
	case "tcp6", "udp6":
		return unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, iface.Index)
	}
	return nil
}
