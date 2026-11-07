package physical

import (
	"net"

	"golang.org/x/sys/unix"
)

func bind(fd uintptr, _ string, _ net.IP, iface *net.Interface) error {
	return unix.BindToDevice(int(fd), iface.Name)
}
