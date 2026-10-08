#!/bin/bash
set -uo pipefail
# shellcheck source=macos/v6-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/v6-common.sh"
NEXT_RETRY=0

watch_once() {
    local now
    suspended && return 0
    now=$(date +%s)
    [[ "$now" -ge "$NEXT_RETRY" ]] || return 0
    if campus; then
        configuration_active && return 0
        # A broken running core must restore connectivity, not repeatedly seize
        # the same network. Manual on can resume after the fault is investigated.
        if [[ -f "$MARKER" ]] && ! core_active && core_network_matches; then
            /bin/bash "$V6_DIR/v6ctl.sh" off >> "$LOG" 2>&1 || return 1
            : > "$SUSPEND"
            log 'forwarding core lost → restored system network and paused'
            return 0
        fi
        if /bin/bash "$V6_DIR/v6ctl.sh" on >> "$LOG" 2>&1; then
            log 'campus detected → configuration applied'
        else
            log 'apply failed; retry delayed'
            NEXT_RETRY=$((now + RETRY_INTERVAL))
        fi
    elif [[ -f "$MARKER" || -d "$ORIGINAL" ]]; then
        if /bin/bash "$V6_DIR/v6ctl.sh" off auto >> "$LOG" 2>&1; then
            log 'left campus → previous configuration restored'
        else
            log 'restore failed; retry delayed'
            NEXT_RETRY=$((now + RETRY_INTERVAL))
        fi
    fi
}

watch_main() {
    require_root || return 1
    log "watch started (iface=$IFACE service=$SERVICE interval=$CHECK_INTERVAL)"
    while true; do watch_once; sleep "$CHECK_INTERVAL"; done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then watch_main; fi
