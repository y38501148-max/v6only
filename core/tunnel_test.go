package v6core

import (
	"github.com/xjasonlyu/tun2socks/v2/core/device"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"sync/atomic"
	"testing"
)

type countedDevice struct {
	*channel.Endpoint
	closes atomic.Int32
}

func (d *countedDevice) Name() string { return "test" }
func (d *countedDevice) Type() string { return "test" }
func (d *countedDevice) Close()       { d.closes.Add(1); d.Endpoint.Close() }

var _ device.Device = (*countedDevice)(nil)

func TestTunnelReleasesDeviceOnce(t *testing.T) {
	d := &countedDevice{Endpoint: channel.New(16, 1500, "")}
	owned := &ownedDevice{Device: d}
	s := stack.New(stack.Options{})
	if e := s.CreateNIC(1, owned); e != nil {
		t.Fatal(e)
	}
	tunnel := &Tunnel{Device: owned, Stack: s, Router: New(Config{}, nil)}
	tunnel.Close()
	tunnel.Close()
	if n := d.closes.Load(); n != 1 {
		t.Fatalf("device closed %d times; fd may already have been reused", n)
	}
}
