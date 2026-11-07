package v6core

import (
	"context"
	"errors"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestSourcePortRaceScope(t *testing.T) {
	for _, test := range []struct {
		name, host, primary string
		config              *RaceConfig
		want                int
	}{
		{"default", "public.example", "2001:db8::1", nil, 6},
		{"literal", "2001:db8::1", "2001:db8::1", nil, 6},
		{"capped", "public.example", "2001:db8::1", &RaceConfig{Ports: 50}, 6},
		{"disabled", "public.example", "2001:db8::1", &RaceConfig{}, 1},
		{"campus", "WWW.BUAA.EDU.CN.", "2001:db8::1", nil, 1},
		{"local", "printer.local", "2001:db8::1", nil, 1},
		{"private", "private.example", "fd00::1", nil, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			var mu sync.Mutex
			calls := map[string]int{}
			r := New(Config{Race: test.config}, func(network, address string, _ syscall.RawConn) error {
				if network != "tcp6" {
					t.Errorf("unexpected network %s", network)
				}
				mu.Lock()
				calls[address]++
				mu.Unlock()
				return errors.New("simulated connection failure")
			})
			defer r.Close()
			r.LookupOverride = func(context.Context, string) (Result, error) {
				return Result{V6: []net.IP{net.ParseIP(test.primary), net.ParseIP("2001:db8::2")}}, nil
			}
			_, err := r.Dial(context.Background(), test.host, "443")
			if err == nil {
				t.Fatal("unexpected successful dial")
			}
			mu.Lock()
			defer mu.Unlock()
			if calls[net.JoinHostPort(test.primary, "443")] != test.want {
				t.Fatalf("expected %d primary attempts, got %v", test.want, calls)
			}
			if net.ParseIP(test.host) == nil && calls["[2001:db8::2]:443"] != 1 {
				t.Fatalf("secondary address must have one attempt, got %v", calls)
			}
		})
	}
}

func TestSourcePortRaceWinsAfterFirstFailure(t *testing.T) {
	ln, err := net.Listen("tcp6", "[::1]:0")
	if err != nil {
		t.Skipf("IPv6 loopback unavailable: %v", err)
	}
	defer ln.Close()
	var calls atomic.Int32
	r := New(Config{}, func(_, _ string, _ syscall.RawConn) error {
		if calls.Add(1) == 1 {
			return errors.New("simulated failure on first source port")
		}
		return nil
	})
	defer r.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	start := time.Now()
	conn, err := r.raceDial(ctx, ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if time.Since(start) < raceStagger {
		t.Fatal("second socket started without staggering")
	}
	_, port, err := net.SplitHostPort(conn.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() == 2 && port == strconv.Itoa(racePortBase) {
		t.Fatal("winning socket reused the first attempt's port")
	}
}

func TestSourcePortRaceCancellation(t *testing.T) {
	r := New(Config{}, nil)
	defer r.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	done := make(chan error, 1)
	go func() {
		conn, err := r.raceDial(ctx, "[2001:db8::1]:443")
		if conn != nil {
			conn.Close()
		}
		done <- err
	}()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected cancellation, got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled race did not return")
	}
}
