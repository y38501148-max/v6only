package v6core

import (
	"context"
	"errors"
	"net"
	"path/filepath"
	"testing"
	"time"
)

func TestTrafficPersistsAndFiltersExactRange(t *testing.T) {
	p := filepath.Join(t.TempDir(), "traffic.db")
	s, e := OpenTraffic(p)
	if e != nil {
		t.Fatal(e)
	}
	now := time.Now().Unix()
	s.mu.Lock()
	s.pending[now-100] = Bytes{11, 12, 13, 14}
	s.pending[now] = Bytes{101, 102, 103, 104}
	s.mu.Unlock()
	if e = s.Close(); e != nil {
		t.Fatal(e)
	}
	r, e := ReadTraffic(p, now, now+1)
	if e != nil || r.Bytes != (Bytes{101, 102, 103, 104}) {
		t.Fatal(r, e)
	}
	r, e = ReadTraffic(p, now-200, now)
	if e != nil || r.Bytes != (Bytes{11, 12, 13, 14}) {
		t.Fatal(r, e)
	}
}
func TestStrictUDPDoesNotFallBack(t *testing.T) {
	r := New(Config{FamilyTimeoutMS: 50}, nil)
	defer r.Close()
	r.LookupOverride = func(context.Context, string) (Result, error) { return dual(), nil }
	var calls []string
	r.DialOverride = func(ctx context.Context, n, a string) (net.Conn, error) {
		calls = append(calls, n)
		return nil, errors.New("IPv6 unreachable")
	}
	_, _, e := r.OpenUDP(context.Background(), "dual.test", "443", []byte("quic"))
	if e == nil || len(calls) != 1 || calls[0] != "udp6" {
		t.Fatal(calls, e)
	}
}

func TestCountingUDPStillUsesDatagramFraming(t *testing.T) {
	l, e := net.ListenPacket("udp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer l.Close()
	go func() {
		b := make([]byte, 99)
		n, a, e := l.ReadFrom(b)
		if e == nil {
			l.WriteTo(b[:n], a)
		}
	}()
	c, e := net.Dial("udp4", l.LocalAddr().String())
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	s, e := OpenTraffic(filepath.Join(t.TempDir(), "traffic.db"))
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	wrapped := &countingPacketConn{&countingConn{Conn: c, s: s, v6: false}, c.(net.PacketConn)}
	rtr := New(Config{}, nil)
	defer rtr.Close()
	rtr.record("video.test", wrapped, "udp4", "no_aaaa")
	var conn net.Conn = wrapped
	if _, ok := conn.(net.PacketConn); !ok {
		t.Fatal("UDP identity lost")
	}
	conn.SetDeadline(time.Now().Add(time.Second))
	payload := []byte{0, 1, 2, 3, 4, 5}
	if _, e = conn.Write(payload); e != nil {
		t.Fatal(e)
	}
	b := make([]byte, 99)
	n, e := conn.Read(b)
	if e != nil || n != len(payload) {
		t.Fatal(n, e)
	}
	flows := rtr.Flows("")
	if len(flows) != 1 || flows[0].UploadBytes != 6 || flows[0].DownloadBytes != 6 {
		t.Fatal(flows)
	}
	r, e := s.Report(0, time.Now().Unix()+1)
	if e != nil || r.V4Up != 6 || r.V4Down != 6 || r.V6Up != 0 {
		t.Fatal(r, e)
	}
}
