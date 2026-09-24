#!/bin/bash
# Destructive network testing is permitted ONLY on GitHub-hosted disposable VMs.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && $(uname -s) == Darwin ]] || {
    echo 'Refusing to change networking outside a disposable GitHub-hosted macOS VM.' >&2; exit 1;
}
[[ $EUID == 0 ]] || { echo 'Run with sudo -E in CI.' >&2; exit 1; }
PROJ=$(cd "$(dirname "$0")/.." && pwd)
BIN="$PROJ/core/build/integration"
mkdir -p "$BIN"
CORE_PID=''; FIXTURE_PID=''
STATE_DIR="$BIN/runtime"
# Use the same physical bypass route implementation as the released controller.
source "$PROJ/macos/v6-runtime.sh"
stop_test_core() {
    if [[ -n "$CORE_PID" ]]; then
        kill "$CORE_PID" 2>/dev/null || true
        for _ in {1..50}; do kill -0 "$CORE_PID" 2>/dev/null || break; sleep 0.1; done
        kill -KILL "$CORE_PID" 2>/dev/null || true
        wait "$CORE_PID" 2>/dev/null || true
    fi
    CORE_PID=''
    rm -f "$BIN/ready"
}
cleanup() {
    stop_test_core
    remove_physical_routes || true
    [[ -z "$FIXTURE_PID" ]] || kill "$FIXTURE_PID" 2>/dev/null || true
    ifconfig lo0 inet 203.0.113.3 -alias 2>/dev/null || true
    ifconfig lo0 inet6 2001:db8:1::3 -alias 2>/dev/null || true
}
trap cleanup EXIT
for cmd in v6core netfixture netcheck; do (cd "$PROJ/core" && go build -o "$BIN/$cmd" "./cmd/$cmd"); done
ifconfig lo0 inet 203.0.113.3 255.255.255.255 alias
ifconfig lo0 inet6 2001:db8:1::3 prefixlen 128 alias
"$BIN/netfixture" --listen4 203.0.113.3 --listen6 2001:db8:1::3 > "$BIN/fixture.log" 2>&1 &
FIXTURE_PID=$!
start() {
    "$BIN/v6core" "$@" --device utun --ready "$BIN/ready" >> "$BIN/core.log" 2>&1 &
    CORE_PID=$!
    for _ in {1..50}; do [[ -s "$BIN/ready" ]] && break; sleep 0.1; done
    [[ -s "$BIN/ready" ]] || { cat "$BIN/core.log"; exit 1; }
    DEV=$(sed -n 's/.*"device":"\([a-z0-9]*\)".*/\1/p' "$BIN/ready")
    [[ "$DEV" == utun* ]] || exit 1
    ifconfig "$DEV" inet 198.18.0.1 198.18.0.1 netmask 255.255.255.0 up
    ifconfig "$DEV" inet6 fd00:198:18::1 prefixlen 64
}
start --interface lo0 --dns 203.0.113.3:15353 --fake-dns
route -n add -net 198.18.0.0/15 -interface "$DEV"
"$BIN/netcheck" --skip-sni || { cat "$BIN/core.log"; exit 1; }
stop_test_core
echo 'PASS controlled dual-stack sockets through macOS utun'

# Exercise full routing with the VM's own physical DNS; no loopback DNS setting.
PHYSICAL=$(route -n get default | awk '/interface:/{print $2}')
UPSTREAM=$(scutil --dns | awk '/nameserver\[0\]/{print $3;exit}')
[[ -n "$PHYSICAL" && -n "$UPSTREAM" ]] || exit 1
curl --noproxy '*' -fsS --max-time 20 https://example.com/ -o /dev/null
start --interface "$PHYSICAL" --dns "$UPSTREAM"
IFACE="$PHYSICAL"
setup_physical_routes
route -n add -net 0.0.0.0/1 -interface "$DEV"
route -n add -net 128.0.0.0/1 -interface "$DEV"
route -n add -inet6 ::/1 -interface "$DEV"
route -n add -inet6 8000::/1 -interface "$DEV"
curl --noproxy '*' -fsS --max-time 30 https://example.com/ -o /dev/null || { cat "$BIN/core.log"; exit 1; }
echo 'PASS real HTTPS with full macOS TUN routing'
stop_test_core
remove_physical_routes
[[ $(route -n get 1.1.1.1 | awk '/interface:/{print $2}') == "$PHYSICAL" ]]
curl --noproxy '*' -fsS --max-time 20 https://example.com/ -o /dev/null
echo 'PASS core exit restores physical routing and DNS remains usable'
