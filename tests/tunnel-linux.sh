#!/bin/bash
# Run only inside a disposable container/VM. Never touches the host namespace.
set -euo pipefail
[[ $(uname -s) == Linux && ${V6ONLY_DISPOSABLE_NETWORK:-} == 1 ]] || {
    echo 'Requires a disposable Linux VM/container and V6ONLY_DISPOSABLE_NETWORK=1.' >&2; exit 1;
}
[[ -f /.dockerenv || ${GITHUB_ACTIONS:-} == true ]] || exit 1
PROJ=$(cd "$(dirname "$0")/.." && pwd)
BIN=$(mktemp -d)
CLIENT="v6-client-$$"; SERVER="v6-server-$$"
cleanup() {
    for ns in "$CLIENT" "$SERVER"; do
        ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
        ip netns del "$ns" 2>/dev/null || true
    done
    rm -rf "$BIN"
}
trap cleanup EXIT
(cd "$PROJ/core" && go build -o "$BIN/v6core" ./cmd/v6core && go build -o "$BIN/netfixture" ./cmd/netfixture && go build -o "$BIN/netcheck" ./cmd/netcheck)
ip netns add "$CLIENT"; ip netns add "$SERVER"
ip link add client0 type veth peer name server0
ip link set client0 netns "$CLIENT"; ip link set server0 netns "$SERVER"
for ns in "$CLIENT" "$SERVER"; do ip -n "$ns" link set lo up; done
ip -n "$CLIENT" addr add 192.0.2.2/24 dev client0
ip -n "$SERVER" addr add 192.0.2.1/24 dev server0
ip -n "$CLIENT" -6 addr add fd00:feed:1::2/64 dev client0 nodad
ip -n "$SERVER" -6 addr add fd00:feed:1::1/64 dev server0 nodad
ip -n "$CLIENT" link set client0 up; ip -n "$SERVER" link set server0 up
ip -n "$SERVER" addr add 203.0.113.3/32 dev lo
ip -n "$SERVER" -6 addr add 2001:db8:1::3/128 dev lo nodad
ip -n "$CLIENT" route add default via 192.0.2.1
ip -n "$CLIENT" -6 route add default via fd00:feed:1::1
ip netns exec "$SERVER" "$BIN/netfixture" --listen4 203.0.113.3 --listen6 2001:db8:1::3 > "$BIN/fixture.log" 2>&1 &
for _ in {1..100}; do grep -q 'fixture ready' "$BIN/fixture.log" && break; sleep 0.1; done
grep -q 'fixture ready' "$BIN/fixture.log" || { cat "$BIN/fixture.log"; exit 1; }
ip netns exec "$CLIENT" "$BIN/v6core" --interface client0 --device v6test --fake-dns --dns 203.0.113.3:15353 --ready "$BIN/ready" > "$BIN/core.log" 2>&1 &
for _ in {1..50}; do [[ -f "$BIN/ready" ]] && break; sleep 0.1; done
[[ -f "$BIN/ready" ]] || { cat "$BIN/core.log"; exit 1; }
ip -n "$CLIENT" addr add 198.18.0.1/24 dev v6test
ip -n "$CLIENT" -6 addr add fd00:198:18::1/64 dev v6test nodad
ip -n "$CLIENT" link set v6test up
ip -n "$CLIENT" route add 0.0.0.0/1 dev v6test
ip -n "$CLIENT" route add 128.0.0.0/1 dev v6test
ip -n "$CLIENT" -6 route add ::/1 dev v6test
ip -n "$CLIENT" -6 route add 8000::/1 dev v6test
if ! ip netns exec "$CLIENT" "$BIN/netcheck"; then cat "$BIN/core.log" "$BIN/fixture.log"; exit 1; fi
CORE_PID=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$BIN/ready")
kill "$CORE_PID"
for _ in {1..50}; do ip -n "$CLIENT" link show v6test >/dev/null 2>&1 || break; sleep 0.1; done
ip -n "$CLIENT" route get 203.0.113.3 | grep -q 'dev client0'
ip netns exec "$CLIENT" curl --noproxy '*' -fsS --max-time 5 http://203.0.113.3:18080/ | grep -q tcp4
echo 'PASS: core exit removes TUN routes; physical network remains usable'
