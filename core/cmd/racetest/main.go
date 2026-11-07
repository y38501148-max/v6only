package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"sort"
	"syscall"
	"time"

	core "github.com/y38501148-max/v6only/core"
	"github.com/y38501148-max/v6only/core/internal/physical"
)

func main() {
	target := flag.String("target", "", "public IPv6 literal and port, e.g. [2402:f000:1:400::2]:443")
	iface := flag.String("interface", "", "physical interface name")
	count := flag.Int("count", 20, "TCP handshakes per mode")
	flag.Parse()
	host, port, err := net.SplitHostPort(*target)
	ip := net.ParseIP(host)
	if err != nil || ip == nil || ip.To4() != nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || *count < 1 {
		log.Fatal("provide a public IPv6 -target with a port and a positive -count")
	}
	var control func(string, string, syscall.RawConn) error
	if *iface != "" {
		device, err := net.InterfaceByName(*iface)
		if err != nil {
			log.Fatal(err)
		}
		control = physical.Control(device)
	}

	direct := core.New(core.Config{Race: &core.RaceConfig{}}, control)
	defer direct.Close()
	racing := core.New(core.Config{}, control)
	defer racing.Close()
	routers := []*core.Router{direct, racing}
	latencies := make([][]time.Duration, len(routers))
	for i := 0; i < *count; i++ {
		for j := range routers {
			// Alternate which mode goes first in each pair.
			mode := (i + j) % len(routers)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			start := time.Now()
			conn, err := routers[mode].Dial(ctx, host, port)
			elapsed := time.Since(start)
			cancel()
			if err == nil {
				conn.Close()
				latencies[mode] = append(latencies[mode], elapsed)
			}
		}
	}
	for i, name := range []string{"direct", "race"} {
		samples := latencies[i]
		fmt.Printf("%s: %d/%d successful", name, len(samples), *count)
		if n := len(samples); n > 0 {
			sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
			fmt.Printf(", successful handshakes p50=%v p90=%v max=%v", samples[(n-1)/2], samples[(9*n+9)/10-1], samples[n-1])
		}
		fmt.Println()
	}
}
