"""Real LinkProperties/production-service regression; disposable rootable emulator only."""
import http.server
import os
import subprocess
import threading
import time

ADB = [os.environ.get('ADB', 'adb')]
if os.environ.get('ANDROID_SERIAL'):
    ADB += ['-s', os.environ['ANDROID_SERIAL']]


def adb(*args):
    return subprocess.check_output(ADB + list(args), text=True, stderr=subprocess.STDOUT, timeout=20).strip()


def shell(*args):
    return adb('shell', *args)


def wait(predicate, label):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            print('PASS: ' + label, flush=True)
            return
        time.sleep(.2)
    raise AssertionError(label)


def vpn():
    return 'ni{VPN CONNECTED extra: VPN:edu.buaa.v6only' in shell('dumpsys', 'connectivity')


def command(action):
    shell('am', 'start-foreground-service', '-n', 'edu.buaa.v6only/.V6VpnService', '-a', 'edu.buaa.v6only.' + action)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'v6only physical network restored\n')
    def log_message(self, *args):
        pass


assert shell('getprop', 'ro.kernel.qemu') == '1', 'Never change a personal phone with this fixture'
adb('root')
adb('wait-for-device')
assert shell('id', '-u') == '0', 'Rootable emulator required'
server = http.server.HTTPServer(('127.0.0.1', 18766), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
address = '2001:db8:10::22/64'
added_route = False
try:
    # StartupSmoke persists global/automatic mode; no test-only VPN service is used.
    out = shell('am', 'instrument', '-w', 'edu.buaa.v6only.tests/.StartupSmoke')
    assert 'PASS:' in out and 'FAIL:' not in out, out
    shell('am', 'start', '-n', 'edu.buaa.v6only/.MainActivity')
    command('START')
    wait(lambda: not vpn(), 'IPv4-only physical network keeps system routing')
    for iteration in range(2):
        # nodad keeps this synthetic address out of Android's tentative-address cache.
        shell('ip', '-6', 'addr', 'add', address, 'dev', 'wlan0', 'nodad')
        # Android 10 images can expose only a connected IPv6 subnet on Wi-Fi.
        # Supply the fixture's default route too: an address alone is deliberately
        # insufficient for the production readiness guard.
        routes = shell('ip', '-6', 'route', 'show', 'table', 'all')
        if not any(line.startswith('default ') and 'dev wlan0' in line for line in routes.splitlines()):
            shell('ip', '-6', 'route', 'add', 'default', 'via', 'fe80::2', 'dev', 'wlan0')
            added_route = True
        wait(vpn, 'IPv6 recovery establishes production VPN')
        shell('ip', '-6', 'addr', 'del', address, 'dev', 'wlan0')
        wait(lambda: not vpn(), 'IPv6 address loss releases VPN routes')
        notification = shell('dumpsys', 'notification', '--noredact')
        assert '当前网络没有可用 IPv6' in notification, 'Missing explicit standby reason'
        response = shell("printf 'GET / HTTP/1.0\\r\\nHost: fixture\\r\\n\\r\\n' | toybox nc -w 3 10.0.2.2 18766")
        assert 'v6only physical network restored' in response, response
        print('PASS: default HTTP works after IPv6 loss; monitor remains active', flush=True)
except BaseException:
    print(shell('ip', '-6', 'addr', 'show', 'dev', 'wlan0'), flush=True)
    print(shell('ip', '-6', 'route', 'show', 'table', 'all'), flush=True)
    print(shell('dumpsys', 'connectivity'), flush=True)
    print(shell('logcat', '-d', '-s', 'V6VpnService'), flush=True)
    raise
finally:
    if added_route:
        subprocess.run(ADB + ['shell', 'ip', '-6', 'route', 'del', 'default', 'via', 'fe80::2', 'dev', 'wlan0'], capture_output=True)
    subprocess.run(ADB + ['shell', 'ip', '-6', 'addr', 'del', address, 'dev', 'wlan0'], capture_output=True)
    command('STOP')
    server.shutdown()
    server.server_close()
print('PASS: production IPv6 loss/recovery regression', flush=True)
