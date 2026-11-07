package physical

import (
	"math/bits"
	"net"

	"golang.org/x/sys/windows"
)

func bind(fd uintptr, network string, ip net.IP, iface *net.Interface) error {
	const unicastInterface = 31
	handle := windows.Handle(fd)
	switch network {
	case "tcp6", "udp6":
		if err := windows.SetsockoptInt(handle, windows.IPPROTO_IPV6, unicastInterface, iface.Index); err != nil {
			return err
		}
		if network != "udp6" || ip != nil {
			return nil
		}
		fallthrough
	case "tcp4", "udp4":
		// Winsock expects the IPv4 index in network byte order.
		return windows.SetsockoptInt(handle, windows.IPPROTO_IP, unicastInterface, int(bits.ReverseBytes32(uint32(iface.Index))))
	}
	return nil
}
