#!/bin/bash
# Read-only diagnostics: never toggle PF, change DNS, clear caches or log out.
set -uo pipefail
# shellcheck source=macos/v6-common.sh
source "$(dirname "$0")/v6-common.sh"
FAIL=0
check() {
    local name="$1"; shift
    if "$@"; then printf '[PASS] %s\n' "$name";
    else printf '[FAIL] %s\n' "$name"; FAIL=$((FAIL + 1)); fi
}
probe() {
    local family="$1" url="$2" result
    result=$(curl "$family" --noproxy '*' --head --silent --show-error \
        --connect-timeout 5 --max-time 10 -o /dev/null \
        -w 'HTTP=%{http_code} remote=%{remote_ip}' "$url") || return 1
    printf '       %s\n' "$result"
}
dns_probe() {
    local result
    result=$(dig "@${DNS_SERVERS[0]}" www.bilibili.com AAAA +short +time=3 +tries=1) || return 1
    printf '%s\n' "$result" | grep -Eq '^[0-9a-fA-F:]+:[0-9a-fA-F:]+$'
}
check '该服务 DNS 配置与共享配置一致' dns_active
check '校园识别（不是任意 10/8 网关）' campus
check '网关专用校园 DNS resolver' test -f "$RESOLVER_DIR/$PORTAL_HOST"
if [[ $EUID -eq 0 ]]; then check '配置读回完整，包括 PF 实际规则' configuration_active;
else printf '[SKIP] PF 运行态检查需要 sudo；其余检查继续。\n'; fi
printf '系统代理设置（代理出口协议需另行检查）：\n'
scutil --proxy
if [[ "${1:-}" != --offline ]]; then
    check '首选 DNS 能返回公网 AAAA 记录' dns_probe
    check '公网 IPv4 可用' probe -4 https://www.baidu.com/
    check '公网 IPv6 可用' probe -6 https://www.bilibili.com/
    check '校园网关可用' probe -4 https://gw.buaa.edu.cn/
fi
printf '失败项：%s。连接成功不代表所有应用都使用 IPv6。\n' "$FAIL"
exit "$FAIL"
