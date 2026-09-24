#!/bin/bash
# shellcheck disable=SC2034
# Shared configuration; compatible with macOS Bash 3.2.
V6_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IFACE="${IFACE:-en0}"
SERVICE="${SERVICE:-Wi-Fi}"
CAMPUS_DNS=(202.112.128.50 202.112.128.51)
# Campus resolvers return both A and AAAA, including internal names. Public
# IPv6 DNS can time out for off-campus domains here; keep it as fallback only.
DNS_SERVERS=("${CAMPUS_DNS[@]}" 2400:3200::1)
PORTAL_HOST=gw.buaa.edu.cn
PF_ANCHOR=com.apple/v6only
STATE_DIR="${STATE_DIR:-/var/db/v6only}"
RUN_DIR="${RUN_DIR:-/var/run}"
RESOLVER_DIR="${RESOLVER_DIR:-/etc/resolver}"
LOG="${LOG:-/var/log/v6only.log}"
MARKER="$RUN_DIR/v6only.active"
SUSPEND="$RUN_DIR/v6only.suspend"
ORIGINAL="$STATE_DIR/original"
CHECK_INTERVAL="${CHECK_INTERVAL:-20}"
RETRY_INTERVAL="${RETRY_INTERVAL:-300}"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
die() { printf 'v6only: %s\n' "$*" >&2; return 1; }
require_root() { [[ $EUID -eq 0 ]] || die '需要管理员权限，请使用 sudo。'; }
desired_dns() { printf '%s\n' "${DNS_SERVERS[@]}"; }
desired_resolver() { printf 'nameserver %s\n' "${CAMPUS_DNS[@]}"; }
rules_signature() { printf '%s\n' "$IFACE"; cksum < "$V6_DIR/anchor-v6only"; }

# Query this network service, not scutil's first (possibly VPN) resolver.
current_dns() {
    local value
    value=$(networksetup -getdnsservers "$SERVICE") || return 1
    if [[ "$value" == *"aren't any DNS Servers"* ]]; then printf 'Empty\n';
    else printf '%s\n' "$value"; fi
}
current_bypass() {
    local value
    value=$(networksetup -getproxybypassdomains "$SERVICE") || return 1
    [[ "$value" != *"aren't any bypass domains"* ]] || value=''
    if [[ -n "$value" ]]; then printf '%s\n' "$value"; fi
}
dns_active() { [[ "$(current_dns)" == "$(desired_dns)" ]]; }
bypass_active() { current_bypass | tr ',;' '\n\n' | grep -Fxq "$PORTAL_HOST"; }
pf_hook_present() {
    pfctl -sr 2>/dev/null | grep -Eq '^anchor "com\.apple/\*"( all)?$'
}
pf_active() {
    local actual
    pf_hook_present || return 1
    pfctl -s info 2>/dev/null | grep -q '^Status: Enabled' || return 1
    [[ -s "$STATE_DIR/pf.expected" ]] || return 1
    actual=$(pfctl -a "$PF_ANCHOR" -sr 2>/dev/null) || return 1
    [[ "$actual" == "$(cat "$STATE_DIR/pf.expected")" ]]
}
configuration_active() {
    [[ -f "$MARKER" && -d "$ORIGINAL" ]] || return 1
    [[ "$(cat "$ORIGINAL/service")" == "$SERVICE" ]] || return 1
    [[ -f "$STATE_DIR/rules.signature" ]] || return 1
    [[ "$(cat "$STATE_DIR/rules.signature")" == "$(rules_signature)" ]] || return 1
    dns_active && pf_active || return 1
    bypass_active || return 1
    [[ -f "$RESOLVER_DIR/$PORTAL_HOST" ]] || return 1
    [[ "$(cat "$RESOLVER_DIR/$PORTAL_HOST")" == "$(desired_resolver)" ]]
}

# A private 10/8 gateway alone does not identify the campus.
campus() {
    local packet summary dns token ssid
    packet=$(ipconfig getpacket "$IFACE" 2>/dev/null) || return 1
    dns=$(printf '%s\n' "$packet" | sed -n '/^domain_name_server /p')
    for token in "${CAMPUS_DNS[@]}"; do
        printf '%s\n' "$dns" | tr '{},' '   ' | grep -Fwq "$token" && return 0
    done
    if printf '%s\n' "$packet" | sed -n '/^domain_name /p;/^domain_search /p' |
        grep -Eqi '(^|[[:space:]"{,])([a-z0-9-]+\.)*buaa\.edu\.cn([[:space:]"},]|$)'; then
        return 0
    fi
    summary=$(ipconfig getsummary "$IFACE" 2>/dev/null) || return 1
    ssid=$(printf '%s\n' "$summary" | awk -F' : ' '/^[[:space:]]*SSID :/{print $2; exit}')
    case "$ssid" in BUAA-mobile|BUAA-WIFI|BUAA|BUAA-secure) return 0;; esac
    return 1
}

# No detached sleep process that could expire a newer pause.
suspended() {
    local until now
    [[ -f "$SUSPEND" ]] || return 1
    until=$(cat "$SUSPEND")
    case "$until" in ''|*[!0-9]*) return 0;; esac
    now=$(date +%s)
    [[ "$until" -gt "$now" ]] && return 0
    rm -f "$SUSPEND"
    return 1
}
