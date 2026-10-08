// netfixture is a disposable-network test server, never included in releases.
package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"fmt"
	"github.com/miekg/dns"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

func main() {
	v4 := flag.String("v4", "203.0.113.3", "A fixture address")
	v6 := flag.String("v6", "2001:db8:1::3", "AAAA fixture address")
	bad6 := flag.String("bad6", "2001:db8:2::3", "unreachable AAAA address")
	listen4 := flag.String("listen4", "0.0.0.0", "IPv4 bind address")
	listen6 := flag.String("listen6", "::", "IPv6 bind address")
	supplementFixture := flag.Bool("supplement-fixture", false, "serve blocked and transport-dependent supplemental DNS")
	flag.Parse()
	var hits4, hits6 atomic.Int64
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	must(err)
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "dual.test"}, DNSNames: []string{"dual.test", "v4.test", "broken6.test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour * 24), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	must(err)
	pair, err := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}))
	must(err)
	for _, family := range []string{"4", "6"} {
		host := *listen4
		if family == "6" {
			host = *listen6
		}
		handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/stats" {
				fmt.Fprintf(w, "%d %d\n", hits4.Load(), hits6.Load())
				return
			}
			if family == "4" {
				hits4.Add(1)
			} else {
				hits6.Add(1)
			}
			if r.URL.Path == "/video" {
				for range 8192 {
					fmt.Fprint(w, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
				}
			}
			fmt.Fprintln(w, "tcp"+family)
		})
		for _, port := range []string{"18080", "8443"} {
			l, err := net.Listen("tcp"+family, net.JoinHostPort(host, port))
			must(err)
			if port == "8443" {
				l = tls.NewListener(l, &tls.Config{Certificates: []tls.Certificate{pair}})
			}
			go http.Serve(l, handler)
		}
		banner, err := net.Listen("tcp"+family, net.JoinHostPort(host, "18081"))
		must(err)
		go func() {
			for {
				c, e := banner.Accept()
				if e != nil {
					return
				}
				fmt.Fprintln(c, "banner"+family)
				c.Close()
			}
		}()
		udp, err := net.ListenPacket("udp"+family, net.JoinHostPort(host, "18080"))
		must(err)
		go func() {
			b := make([]byte, 65535)
			for {
				n, a, e := udp.ReadFrom(b)
				if e != nil {
					return
				}
				udp.WriteTo(append([]byte("udp"+family+":"), b[:n]...), a)
			}
		}()
	}
	makeDNSHandler := func(supplement bool) dns.HandlerFunc {
		return func(w dns.ResponseWriter, q *dns.Msg) {
			a := new(dns.Msg)
			a.SetReply(q)
			a.RecursionAvailable = true
			if len(q.Question) != 1 {
				a.Rcode = dns.RcodeFormatError
				w.WriteMsg(a)
				return
			}
			question := q.Question[0]
			host := question.Name
			if host == "absent.test." {
				a.Rcode = dns.RcodeNameError
				w.WriteMsg(a)
				return
			}
			if host == "dnsfail.test." {
				a.Rcode = dns.RcodeServerFailure
				w.WriteMsg(a)
				return
			}
			hdr := dns.RR_Header{Name: host, Rrtype: question.Qtype, Class: dns.ClassINET, Ttl: 30}
			switch question.Qtype {
			case dns.TypeA:
				if host != "v6.test." {
					a.Answer = []dns.RR{&dns.A{Hdr: hdr, A: net.ParseIP(*v4)}}
				}
			case dns.TypeAAAA:
				if host != "v4.test." && (!strings.HasPrefix(host, "supplement-") || (supplement && w.RemoteAddr().Network() == "tcp")) {
					ip := *v6
					if host == "broken6.test." {
						ip = *bad6
					}
					a.Answer = []dns.RR{&dns.AAAA{Hdr: hdr, AAAA: net.ParseIP(ip)}}
				}
			}
			w.WriteMsg(a)
		}
	}
	handler := makeDNSHandler(false)
	udp, err := net.ListenPacket("udp4", net.JoinHostPort(*listen4, "15353"))
	must(err)
	tcp, err := net.Listen("tcp4", net.JoinHostPort(*listen4, "15353"))
	must(err)
	go (&dns.Server{PacketConn: udp, Handler: handler}).ActivateAndServe()
	go (&dns.Server{Listener: tcp, Handler: handler}).ActivateAndServe()
	if *supplementFixture {
		blockedUDP, e := net.ListenPacket("udp6", net.JoinHostPort(*listen6, "15354"))
		must(e)
		blockedTCP, e := net.Listen("tcp6", net.JoinHostPort(*listen6, "15354"))
		must(e)
		drop := dns.HandlerFunc(func(dns.ResponseWriter, *dns.Msg) {})
		go (&dns.Server{PacketConn: blockedUDP, Handler: drop}).ActivateAndServe()
		go (&dns.Server{Listener: blockedTCP, Handler: drop}).ActivateAndServe()
		publicUDP, e := net.ListenPacket("udp4", net.JoinHostPort(*listen4, "15355"))
		must(e)
		publicTCP, e := net.Listen("tcp4", net.JoinHostPort(*listen4, "15355"))
		must(e)
		go (&dns.Server{PacketConn: publicUDP, Handler: makeDNSHandler(true)}).ActivateAndServe()
		go (&dns.Server{Listener: publicTCP, Handler: makeDNSHandler(true)}).ActivateAndServe()
	}
	fmt.Println("fixture ready")
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt, syscall.SIGTERM)
	<-ch
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
