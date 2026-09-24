"""Local HTTP and DNS-over-TCP fixtures, reachable only by test emulator/host."""
import http.server
import socket
import socketserver
import struct
import threading

class HTTP6(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6

class DNS(socketserver.ThreadingTCPServer):
    allow_reuse_address = True

class DNSHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        size = self.rfile.read(2)
        if len(size) != 2:
            return
        query = self.rfile.read(struct.unpack('!H', size)[0])
        # Fixture accepts the fixed example.com A/IN query sent by NetworkSmoke.
        if len(query) != 29 or query[12:] != b'\x07example\x03com\0\0\x01\0\x01':
            return
        answer = query[:2] + b'\x81\x80\0\x01\0\x01\0\0\0\0' + query[12:]
        answer += b'\xc0\x0c\0\x01\0\x01\0\0\0\x3c\0\x04\xc0\0\x02\x7b'
        self.wfile.write(struct.pack('!H', len(answer)) + answer)

http4 = http.server.ThreadingHTTPServer(('127.0.0.1', 18765), http.server.SimpleHTTPRequestHandler)
http6 = HTTP6(('::1', 18765), http.server.SimpleHTTPRequestHandler)
dns = DNS(('127.0.0.1', 18753), DNSHandler)
threading.Thread(target=dns.serve_forever, daemon=True).start()
threading.Thread(target=http6.serve_forever, daemon=True).start()
http4.serve_forever()
