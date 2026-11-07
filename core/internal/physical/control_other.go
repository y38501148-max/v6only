//go:build !darwin && !linux && !windows

package physical

import "net"

func bind(uintptr, string, net.IP, *net.Interface) error {
	return nil
}
