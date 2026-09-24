#!/bin/bash
set -eEuo pipefail
# shellcheck source=macos/v6-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/v6-common.sh"

lock() {
    local owner
    mkdir -p "$RUN_DIR" "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    if ! mkdir "$RUN_DIR/v6only.lock" 2>/dev/null; then
        owner=$(cat "$RUN_DIR/v6only.lock/pid" 2>/dev/null || true)
        if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$RUN_DIR/v6only.lock/pid"
            rmdir "$RUN_DIR/v6only.lock"
            mkdir "$RUN_DIR/v6only.lock"
        else
            die '另一个配置操作正在执行。'; return 1
        fi
    fi
    printf '%s\n' "$$" > "$RUN_DIR/v6only.lock/pid"
    trap 'rm -f "$RUN_DIR/v6only.lock/pid"; rmdir "$RUN_DIR/v6only.lock"' EXIT
}

save_originals() {
    local stage
    if [[ -d "$ORIGINAL" ]]; then
        [[ "$(cat "$ORIGINAL/service")" == "$SERVICE" ]] || die '请先关闭原网络服务上的配置。'
        return
    fi
    stage=$(mktemp -d "$STATE_DIR/snapshot.XXXXXX")
    printf '%s\n' "$SERVICE" > "$stage/service"
    current_dns > "$stage/dns"
    current_bypass > "$stage/bypass"
    if [[ -e "$RESOLVER_DIR/$PORTAL_HOST" ]]; then
        [[ ! -L "$RESOLVER_DIR/$PORTAL_HOST" ]] || die '网关 resolver 是符号链接，请先检查。'
        cp -p "$RESOLVER_DIR/$PORTAL_HOST" "$stage/resolver"
    fi
    mv "$stage" "$ORIGINAL"
}

set_dns_file() {
    local item values=()
    while IFS= read -r item; do [[ -z "$item" ]] || values+=("$item"); done < "$1"
    [[ ${#values[@]} -gt 0 ]] || values=(Empty)
    networksetup -setdnsservers "$SERVICE" "${values[@]}"
}
set_bypass_file() {
    local item values=()
    while IFS= read -r item; do [[ -z "$item" ]] || values+=("$item"); done < "$1"
    [[ ${#values[@]} -gt 0 ]] || values=(Empty)
    networksetup -setproxybypassdomains "$SERVICE" "${values[@]}"
}

# Restore only values still owned by this tool; preserve later user edits.
restore() {
    local failed=0 token dns
    if [[ -d "$ORIGINAL" ]]; then
        SERVICE=$(cat "$ORIGINAL/service")
        if dns=$(current_dns); then
            if [[ "$dns" == "$(desired_dns)" || "$dns" == $'202.112.128.50\n202.112.128.51\n2400:3200::1' ]]; then set_dns_file "$ORIGINAL/dns" || failed=1; fi
        else
            failed=1
        fi
        if [[ -f "$STATE_DIR/bypass.added" ]]; then
            # We add a separate exact-host entry; preserve all other entries,
            # including domains the user added after activation.
            if current_bypass > "$STATE_DIR/bypass.current"; then
                awk -v host="$PORTAL_HOST" '$0 != host' "$STATE_DIR/bypass.current" > "$STATE_DIR/bypass.restore"
                set_bypass_file "$STATE_DIR/bypass.restore" || failed=1
            else
                failed=1
            fi
        fi
        if [[ -f "$RESOLVER_DIR/$PORTAL_HOST" ]] &&
            [[ "$(cat "$RESOLVER_DIR/$PORTAL_HOST")" == "$(desired_resolver)" ]]; then
            if [[ -f "$ORIGINAL/resolver" ]]; then
                cp -p "$ORIGINAL/resolver" "$RESOLVER_DIR/$PORTAL_HOST" || failed=1
            else
                rm -f "$RESOLVER_DIR/$PORTAL_HOST" || failed=1
            fi
        fi
    fi
    if [[ -f "$STATE_DIR/pf.loaded" ]]; then
        pfctl -a "$PF_ANCHOR" -F rules || failed=1
    fi
    if [[ -f "$STATE_DIR/pf.token" ]]; then
        token=$(cat "$STATE_DIR/pf.token")
        if pfctl -s References 2>/dev/null | grep -Fwq "$token"; then
            pfctl -X "$token" || failed=1
        fi
    fi
    stop_core || failed=1
    if [[ "$failed" -eq 0 ]]; then
        rm -rf "$ORIGINAL"
        rm -f "$MARKER" "$STATE_DIR/pf.loaded" "$STATE_DIR/pf.token" \
            "$STATE_DIR/pf.expected" "$STATE_DIR/bypass.expected" "$STATE_DIR/bypass.added" \
            "$STATE_DIR/bypass.current" "$STATE_DIR/bypass.restore" "$STATE_DIR/rules.signature"
    fi
    return "$failed"
}

apply_failed() {
    local status=$?
    trap - ERR
    set +e
    printf '配置失败，正在撤销本次管理的网络设置。\n' >&2
    if restore; then
        # A failed activation requires an explicit retry, never repeated network
        # takeover in the background on the same broken configuration.
        : > "$SUSPEND"
    else
        printf '部分回滚失败，快照保留于 %s。\n' "$STATE_DIR" >&2
    fi
    exit "$status"
}

on() {
    local addresses result token resolver_tmp
    if ! campus; then
        if [[ -d "$ORIGINAL" ]]; then off auto; fi
        die '当前未识别到校园网，未开启配置。'; return 1
    fi
    if configuration_active; then
        rm -f "$SUSPEND"
        printf '配置已生效，无需重复应用。\n'
        return
    fi
    [[ "$IFACE" =~ ^[a-zA-Z][a-zA-Z0-9]*$ ]] || die '非法网卡名称。'
    addresses=$(ifconfig "$IFACE" inet6)
    printf '%s\n' "$addresses" | grep -Eq 'inet6 [23][0-9a-fA-F]{3}:' || die '该接口暂无全球 IPv6 地址。'
    pf_hook_present || die 'PF 主规则缺少 com.apple/* 入口；请按 README 迁移旧版，未修改网络。'
    pfctl -n -a "$PF_ANCHOR" -D "v6only_if=$IFACE" -f "$V6_DIR/anchor-v6only"
    [[ ! -L "$RESOLVER_DIR/$PORTAL_HOST" ]] || die '网关 resolver 是符号链接，请先检查。'
    save_originals
    trap apply_failed ERR
    current_bypass > "$STATE_DIR/bypass.expected"
    if ! tr ',;' '\n\n' < "$STATE_DIR/bypass.expected" | grep -Fxq "$PORTAL_HOST"; then
        touch "$STATE_DIR/bypass.added"
        printf '%s\n' "$PORTAL_HOST" >> "$STATE_DIR/bypass.expected"
    fi
    start_core
    networksetup -setdnsservers "$SERVICE" "${DNS_SERVERS[@]}"
    set_bypass_file "$STATE_DIR/bypass.expected"
    if [[ ! -d "$RESOLVER_DIR" ]]; then mkdir -m 755 "$RESOLVER_DIR"; fi
    resolver_tmp=$(mktemp "$RESOLVER_DIR/.v6only.XXXXXX")
    desired_resolver > "$resolver_tmp"
    chmod 644 "$resolver_tmp"
    mv "$resolver_tmp" "$RESOLVER_DIR/$PORTAL_HOST"
    pfctl -a "$PF_ANCHOR" -D "v6only_if=$IFACE" -f "$V6_DIR/anchor-v6only"
    touch "$STATE_DIR/pf.loaded"
    token=$(cat "$STATE_DIR/pf.token" 2>/dev/null || true)
    if ! pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
        result=$(pfctl -E 2>&1)
        token=$(printf '%s\n' "$result" | awk '/Token[[:space:]]*:/ {print $NF; exit}')
        [[ "$token" =~ ^[0-9]+$ ]] || die "无法读取 PF 引用令牌：$result"
        printf '%s\n' "$token" > "$STATE_DIR/pf.token"
    fi
    pfctl -a "$PF_ANCHOR" -sr > "$STATE_DIR/pf.expected"
    rules_signature > "$STATE_DIR/rules.signature"
    touch "$MARKER"
    configuration_active || die '配置读回校验失败。'
    validate_forwarding || die '转发后的 DNS/TLS 连通性验证失败，恢复原网络。'
    rm -f "$SUSPEND"
    trap - ERR
    printf '已应用 IPv6 优先转发；同域名的 IPv6 连接全部失败后才回退 IPv4。\n'
}

off() {
    local mode="${1:-manual}"
    if [[ -f "$MARKER" && ! -d "$ORIGINAL" ]]; then
        die '旧版缺少设置快照，拒绝全局关闭 PF；请先完成迁移。'; return 1
    fi
    restore
    if [[ "$mode" == manual ]]; then
        printf '%s\n' "$(( $(date +%s) + 1800 ))" > "$SUSPEND"
    fi
    printf '已撤销 v6only 管理的设置，保留其他代理和 PF 规则。\n'
}

main() {
    require_root
    umask 077
    case "${1:-status}" in
        on) lock; on;;
        off) lock; off "${2:-manual}";;
        status)
            if configuration_active; then printf 'IPv6 优先转发已生效。\n';
            else die '配置未完整生效。'; fi;;
        *) die '用法：v6ctl.sh on | off [auto] | status';;
    esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
