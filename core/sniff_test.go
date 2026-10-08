package v6core

import (
	"bytes"
	"crypto/tls"
	"io"
	"net"
	"testing"
)

func TestSniffVideoPorts(t *testing.T) {
	for _, port := range []uint16{443, 4483, 8082} {
		t.Run(fmtPort(port), func(t *testing.T) {
			a, b := net.Pipe()
			defer a.Close()
			defer b.Close()
			go tls.Client(a, &tls.Config{ServerName: "cdn.bilivideo.com"}).Handshake()
			_, host := sniff(b, port)
			if host != "cdn.bilivideo.com" {
				t.Fatalf("port %d host=%q", port, host)
			}
		})
	}
	request := []byte("GET /video HTTP/1.1\r\nHost: cdn.bilivideo.com:8082\r\nRange: bytes=0-9\r\n\r\n")
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	go a.Write(request)
	c, host := sniff(b, 8082)
	if host != "cdn.bilivideo.com" {
		t.Fatal(host)
	}
	got := make([]byte, len(request))
	if _, e := io.ReadFull(c, got); e != nil || !bytes.Equal(got, request) {
		t.Fatalf("buffered request corrupted %q %v", got, e)
	}
}
func fmtPort(port uint16) string {
	if port == 4483 {
		return "TLS4483"
	}
	if port == 8082 {
		return "TLS8082"
	}
	return "TLS443"
}
