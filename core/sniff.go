package v6core

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"strings"
	"time"
)

type bufferedConn struct {
	net.Conn
	r io.Reader
}

func (c *bufferedConn) Read(b []byte) (int, error) { return c.r.Read(b) }
func (c *bufferedConn) CloseWrite() error {
	if v, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return v.CloseWrite()
	}
	return c.Conn.Close()
}

// ParseSNI parses a complete TLS ClientHello record; malformed input fails closed.
func ParseSNI(b []byte) string {
	if len(b) < 9 || b[0] != 22 || b[5] != 1 {
		return ""
	}
	n := int(binary.BigEndian.Uint16(b[3:5]))
	if n < 4 || n+5 > len(b) {
		return ""
	}
	b = b[9 : 5+n]
	take := func(n int) []byte {
		if n < 0 || len(b) < n {
			b = nil
			return nil
		}
		v := b[:n]
		b = b[n:]
		return v
	}
	if take(34) == nil {
		return ""
	}
	v := take(1)
	if v == nil || take(int(v[0])) == nil {
		return ""
	}
	v = take(2)
	if v == nil || take(int(binary.BigEndian.Uint16(v))) == nil {
		return ""
	}
	v = take(1)
	if v == nil || take(int(v[0])) == nil {
		return ""
	}
	v = take(2)
	if v == nil {
		return ""
	}
	ext := take(int(binary.BigEndian.Uint16(v)))
	for len(ext) >= 4 {
		typ := binary.BigEndian.Uint16(ext)
		size := int(binary.BigEndian.Uint16(ext[2:]))
		ext = ext[4:]
		if size > len(ext) {
			return ""
		}
		v := ext[:size]
		ext = ext[size:]
		if typ != 0 {
			continue
		}
		if len(v) < 5 || int(binary.BigEndian.Uint16(v)) != len(v)-2 {
			return ""
		}
		v = v[2:]
		for len(v) >= 3 {
			kind := v[0]
			n := int(binary.BigEndian.Uint16(v[1:]))
			v = v[3:]
			if n > len(v) {
				return ""
			}
			if kind == 0 {
				host := strings.ToLower(string(v[:n]))
				if validHost(host) {
					return host
				}
				return ""
			}
			v = v[n:]
		}
	}
	return ""
}
func validHost(s string) bool {
	if len(s) == 0 || len(s) > 253 || !strings.Contains(s, ".") {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '.') {
			return false
		}
	}
	return true
}
func sniff(c net.Conn, port uint16) (net.Conn, string) {
	c.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	defer c.SetReadDeadline(time.Time{})
	reader := bufio.NewReaderSize(c, 65536)
	header, e := reader.Peek(5)
	if e != nil {
		return &bufferedConn{c, reader}, ""
	}
	if header[0] == 22 {
		n := int(binary.BigEndian.Uint16(header[3:5])) + 5
		if n <= 65536 {
			b, e := reader.Peek(n)
			if e == nil {
				return &bufferedConn{c, reader}, ParseSNI(b)
			}
		}
		return &bufferedConn{c, reader}, ""
	}
	if bytes.HasPrefix(header, []byte("GET ")) || bytes.HasPrefix(header, []byte("POST ")) || bytes.HasPrefix(header, []byte("HEAD ")) || bytes.HasPrefix(header, []byte("PUT ")) || bytes.HasPrefix(header, []byte("OPTIONS ")[:5]) || bytes.HasPrefix(header, []byte("CONNE")) {
		var saved bytes.Buffer
		for saved.Len() < 32768 {
			line, e := reader.ReadString('\n')
			saved.WriteString(line)
			if strings.HasPrefix(strings.ToLower(line), "host:") {
				host := strings.TrimSpace(line[5:])
				if h, _, e := net.SplitHostPort(host); e == nil {
					host = h
				}
				return &bufferedConn{c, io.MultiReader(&saved, reader)}, strings.ToLower(host)
			}
			if e != nil || line == "\r\n" {
				break
			}
		}
		return &bufferedConn{c, io.MultiReader(&saved, reader)}, ""
	}
	return &bufferedConn{c, reader}, ""
}
