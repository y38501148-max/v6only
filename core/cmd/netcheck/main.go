// netcheck exercises real sockets through an already configured disposable TUN.
package main

import (
	"crypto/tls"
	"flag"
	"fmt"
	"github.com/miekg/dns"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

func main() {
	server := flag.String("dns", "198.18.0.2:53", "TUN DNS endpoint")
	raw := flag.String("raw", "203.0.113.3", "IPv4 fixture for uncached TLS SNI")
	skipSNI := flag.Bool("skip-sni", false, "fixture IP is local to the runner and bypasses its TUN")
	flag.Parse()
	resolve := func(host, proto string) string {
		q := new(dns.Msg)
		q.SetQuestion(host+".", dns.TypeA)
		a, _, e := (&dns.Client{Net: proto, Timeout: 8 * time.Second}).Exchange(q, *server)
		must(e)
		if a.Rcode != 0 || len(a.Answer) != 1 {
			panic(fmt.Sprint("DNS answer: ", a))
		}
		return a.Answer[0].(*dns.A).A.String()
	}
	for _, item := range []struct{ host, want string }{{"dual.test", "6"}, {"v4.test", "4"}, {"broken6.test", "4"}, {"v6.test", "6"}} {
		ip := resolve(item.host, "udp")
		if ip != resolve(item.host, "tcp") {
			panic("DNS transports disagree")
		}
		c, e := net.DialTimeout("tcp4", net.JoinHostPort(ip, "18080"), 10*time.Second)
		must(e)
		c.SetDeadline(time.Now().Add(10 * time.Second))
		fmt.Fprintf(c, "GET / HTTP/1.0\r\nHost: %s\r\n\r\n", item.host)
		b, e := io.ReadAll(c)
		c.Close()
		must(e)
		if !strings.HasSuffix(string(b), "tcp"+item.want+"\n") {
			panic("HTTP " + item.host + ": " + string(b))
		}
		c, e = net.DialTimeout("udp4", net.JoinHostPort(ip, "18080"), time.Second)
		must(e)
		c.SetDeadline(time.Now().Add(12 * time.Second))
		_, e = c.Write([]byte("marker"))
		must(e)
		b = make([]byte, 100)
		n, e := c.Read(b)
		c.Close()
		must(e)
		if string(b[:n]) != "udp"+item.want+":marker" {
			panic("UDP " + item.host + ": " + string(b[:n]))
		}
		fmt.Println("PASS", item.host, "TCP/UDP selects IPv"+item.want, "through IPv4 TUN entry")
	}
	// Connect an uncached IPv4 address with TLS SNI. The upstream must still be IPv6.
	tr := &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, DialTLSContext: nil}
	tr.DialTLS = func(network, address string) (net.Conn, error) {
		return tls.DialWithDialer(&net.Dialer{Timeout: 10 * time.Second}, "tcp4", net.JoinHostPort(*raw, "8443"), &tls.Config{ServerName: "dual.test", InsecureSkipVerify: true})
	}
	client := &http.Client{Transport: tr, Timeout: 15 * time.Second}
	if !*skipSNI {
		res, e := client.Get("https://dual.test:8443/")
		must(e)
		b, e := io.ReadAll(res.Body)
		res.Body.Close()
		must(e)
		if string(b) != "tcp6\n" {
			panic("TLS SNI did not select IPv6: " + string(b))
		}
		fmt.Println("PASS TLS SNI upgrades literal IPv4 connection to IPv6")
	}
	ip := resolve("dual.test", "udp")
	c, e := net.DialTimeout("tcp4", net.JoinHostPort(ip, "18081"), 10*time.Second)
	must(e)
	c.SetDeadline(time.Now().Add(10 * time.Second))
	b, e := io.ReadAll(c)
	c.Close()
	must(e)
	if string(b) != "banner6\n" {
		panic("server-first protocol failed")
	}
	fmt.Println("PASS server-first TCP and peer close")
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
