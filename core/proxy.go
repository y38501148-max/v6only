package v6core

import (
	"context"
	"io"
	"net"
	"net/http"
	"time"
)

func (r *Router) HTTPProxy() http.Handler {
	transport := &http.Transport{Proxy: nil, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, e := net.SplitHostPort(address)
		if e != nil {
			return nil, e
		}
		return r.Dial(ctx, host, port)
	}, ForceAttemptHTTP2: false, IdleConnTimeout: 30 * time.Second}
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Method == http.MethodConnect {
			host, port, e := net.SplitHostPort(req.Host)
			if e != nil {
				http.Error(w, "invalid CONNECT", 400)
				return
			}
			remote, e := r.Dial(req.Context(), host, port)
			if e != nil {
				http.Error(w, "destination unreachable", 502)
				return
			}
			defer remote.Close()
			client, buf, e := w.(http.Hijacker).Hijack()
			if e != nil {
				return
			}
			defer client.Close()
			client.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
			if buf.Reader.Buffered() > 0 {
				b, _ := buf.Reader.Peek(buf.Reader.Buffered())
				remote.Write(b)
			}
			Relay(client, remote)
			return
		}
		if req.URL.Scheme != "http" || req.URL.Host == "" {
			http.Error(w, "absolute HTTP URL required", 400)
			return
		}
		req.RequestURI = ""
		req.Header.Del("Proxy-Connection")
		req.Header.Del("Proxy-Authorization")
		res, e := transport.RoundTrip(req)
		if e != nil {
			http.Error(w, "destination unreachable", 502)
			return
		}
		defer res.Body.Close()
		for k, v := range res.Header {
			w.Header()[k] = v
		}
		w.WriteHeader(res.StatusCode)
		io.Copy(w, res.Body)
	})
}
