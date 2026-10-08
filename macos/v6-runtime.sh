#!/bin/bash
CORE_LABEL=edu.buaa.v6only-core
CORE_READY="$STATE_DIR/core.ready"
network_signature() {
    ipconfig getifaddr "$IFACE" 2>/dev/null || true
    for family in inet inet6; do
        route -n get -"$family" -ifscope "$IFACE" default 2>/dev/null | awk '/gateway:/{print $2}'
    done
}
core_network_matches() {
    [[ -f "$STATE_DIR/core.network" ]] && [[ "$(cat "$STATE_DIR/core.network")" == "$(network_signature)" ]]
}
setup_physical_routes() {
    local family gateway prefix prefixes
    mkdir -p "$STATE_DIR"
    for family in inet inet6; do
        gateway=$(route -n get -"$family" -ifscope "$IFACE" default 2>/dev/null | awk '/gateway:/{print $2}')
        [[ -n "$gateway" && "$gateway" != link* ]] || continue
        if [[ "$family" == inet ]]; then prefixes='0.0.0.0/1 128.0.0.0/1'; else prefixes='::/1 8000::/1'; fi
        for prefix in $prefixes; do
            # Darwin's interface-bound sockets still need a route at least as
            # specific as the TUN capture. Scoped entries serve only the bound
            # physical interface; unbound applications use the TUN entries.
            route -n add -"$family" -ifscope "$IFACE" -net "$prefix" "$gateway" || return 1
            printf '%s %s %s %s\n' "$family" "$prefix" "$gateway" "$IFACE" >> "$STATE_DIR/core.routes"
        done
    done
}
remove_physical_routes() {
    local family prefix gateway iface current failed=0
    [[ -f "$STATE_DIR/core.routes" ]] || return 0
    while read -r family prefix gateway iface; do
        if ! route -n delete -"$family" -ifscope "$iface" -net "$prefix" "$gateway" >/dev/null 2>&1; then
            # Wi-Fi roaming may have already removed these scoped routes.
            # Only report a failure if the exact owned route still exists.
            current=$(route -n get -"$family" -ifscope "$iface" "$prefix" 2>/dev/null || true)
            if [[ "$(printf '%s\n' "$current" | awk '/gateway:/{print $2}')" == "$gateway" ]] &&
               printf '%s\n' "$current" | awk '/mask:/{print $2}' | grep -Eq '^(128\.0\.0\.0|8000::)$'; then failed=1; fi
        fi
    done < "$STATE_DIR/core.routes"
    [[ $failed == 0 ]] || return 1
    rm -f "$STATE_DIR/core.routes"
}
core_device() { [[ -f "$CORE_READY" ]] || return 0; sed -n 's/.*"device":"\([a-z0-9]*\)".*/\1/p' "$CORE_READY" 2>/dev/null; }
core_active() {
    local dev
    [[ -f "$CORE_READY" ]] || return 1
    dev=$(core_device)
    [[ "$dev" == utun* ]] || return 1
    curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:17890/health | grep -q 'ipv6-only-unless-no-aaaa' || return 1
    [[ "$(route -n get -inet 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')" == "$dev" ]] || return 1
    [[ "$(route -n get -inet6 2001:4860::8888 2>/dev/null | awk '/interface:/{print $2}')" == "$dev" ]]
}
validate_forwarding() {
    # Check complete DNS/TLS/TCP paths after route activation, not just /health.
    local url attempt
    for attempt in {1..12}; do
        if curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:17890/health | grep -q '"data_path_verified":true'; then break; fi
        sleep 1
    done
    curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:17890/health | grep -q '"data_path_verified":true' || return 1
    for url in https://gw.buaa.edu.cn/ https://www.bilibili.com/; do
        curl --noproxy '*' --silent --show-error --head --connect-timeout 10 --max-time 20 "$url" -o /dev/null || return 1
    done
}
stop_core() {
    local pid _attempt
    pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$CORE_READY" 2>/dev/null || true)
    if launchctl print "system/$CORE_LABEL" >/dev/null 2>&1; then launchctl bootout "system/$CORE_LABEL"; fi
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        for _attempt in {1..50}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null && [[ $(ps -p "$pid" -o comm=) == "$V6_DIR/v6core" ]]; then
            kill -KILL "$pid"
        fi
    fi
    remove_physical_routes || return 1
    # Closing the owned utun removes all its routes. No global route/PF flush.
    rm -f "$CORE_READY" "$STATE_DIR/core.plist" "$STATE_DIR/core.network"
}
start_core() {
    local dev _attempt
    core_active && core_network_matches && return 0
    [[ -x "$V6_DIR/v6core" ]] || die '缺少 v6core 二进制，请先运行 macos/build.sh。'
    stop_core
    cat > "$STATE_DIR/core.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$CORE_LABEL</string>
<key>ProgramArguments</key><array>
<string>$V6_DIR/v6core</string><string>--interface</string><string>$IFACE</string>
<string>--dns</string><string>202.112.128.50,202.112.128.51</string>
<string>--chatgpt-proxy</string><string>127.0.0.1:7890</string>
<string>--ipv6-dns</string><string>2400:3200::1,2400:3200:baba::1</string>
<string>--device</string><string>utun</string>
<string>--ready</string><string>$CORE_READY</string>
<string>--stats-db</string><string>$STATE_DIR/traffic.sqlite</string>
</array><key>RunAtLoad</key><true/><key>KeepAlive</key><false/>
<key>StandardOutPath</key><string>$STATE_DIR/core.log</string>
<key>StandardErrorPath</key><string>$STATE_DIR/core.log</string>
</dict></plist>
PLIST
    chmod 600 "$STATE_DIR/core.plist"
    launchctl bootstrap system "$STATE_DIR/core.plist"
    for _attempt in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -s "$CORE_READY" ]]; then break; fi
        sleep 1
    done
    dev=$(core_device)
    [[ "$dev" =~ ^utun[0-9]+$ ]] || die '转发核心未就绪。'
    ifconfig "$dev" inet 198.18.0.1 198.18.0.1 netmask 255.255.255.0 up
    ifconfig "$dev" inet6 fd00:198:18::1 prefixlen 64
    setup_physical_routes
    network_signature > "$STATE_DIR/core.network"
    route -n add -net 0.0.0.0/1 -interface "$dev"
    route -n add -net 128.0.0.0/1 -interface "$dev"
    route -n add -inet6 ::/1 -interface "$dev"
    route -n add -inet6 8000::/1 -interface "$dev"
    core_active || die '转发核心路由校验失败。'
}
