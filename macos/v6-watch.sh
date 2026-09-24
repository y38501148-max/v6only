#!/bin/bash
# v6-watch.sh — 校园网感知静默守护 v2（launchd 根守护，开机自启）
#
# v2 行为（按用户需求定版）：
#   - 校园网内：应用「v6 优先」DNS 策略（v6 上游 + 校园 v4 兜底）
#   - 不再全局封 v4：v4-only 站点直连 v4，双栈站 Happy Eyeballs 竞速走 v6
#   - suspend 接口：touch /var/run/v6only.suspend 后守护暂停一切动作；
#     rm 掉恢复。用户手动 v6off.sh 会自动落 suspend 标记，不再 20 秒被拉回
#
# 检测信号（任一命中即校园网）：DHCP router ∈ 10/8 / DHCP DNS 网段 / 域名 / SSID

IFACE="${IFACE:-en0}"
SSID_LIST="${SSID_LIST:-BUAA-mobile BUAA-WIFI BUAA BUAA-secure}"
LOG="/var/log/v6only.log"
MARKER="/var/run/v6only.active"
SUSPEND="/var/run/v6only.suspend"
LIBDIR="/usr/local/lib/v6only"
CHECK_INTERVAL="${CHECK_INTERVAL:-20}"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

dhcp_field() {
  ipconfig getpacket "$IFACE" 2>/dev/null \
    | grep -A1 "^$1 " | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

gw_hit() {
  local gw; gw=$(dhcp_field "router")
  [[ -n "$gw" && ${gw%%.*} -eq 10 ]] && return 0
  return 1
}

dns_hit() {
  local dns; dns=$(dhcp_field "domain_name_server")
  [[ -z "$dns" ]] && return 1
  local b0 rest b1
  b0=${dns%%.*}; rest=${dns#*.}; b1=${rest%%.*}
  [[ "$b0" == "202" && "$b1" == "112" ]] && return 0
  [[ "$b0" == "10" ]] && return 0
  return 1
}

domain_hit() {
  ipconfig getpacket "$IFACE" 2>/dev/null | grep -qi 'buaa\.edu\.cn'
}

ssid_hit() {
  local s
  s=$(ipconfig getsummary "$IFACE" 2>/dev/null \
    | awk -F' : ' '/^[[:space:]]*SSID :/{gsub(/^[ \t]+|[ \t]+$/,"",$2);print $2;exit}')
  [[ -z "$s" || "$s" == "<redacted>" || "$s" == *unknown* ]] && return 1
  for w in $SSID_LIST; do [[ "$s" == "$w" ]] && return 0; done
  return 1
}

campus() { gw_hit || dns_hit || domain_hit || ssid_hit; }

dns_active() {
  # v6 优先 DNS 策略是否已生效（查当前第一个 nameserver 是不是我们设的）
  local ns
  ns=$(scutil --dns 2>/dev/null | grep 'nameserver\[0\]' | awk '{print $3}' | head -1)
  [[ "$ns" == "2400:3200:baba::1" ]]
}

silently_on() {
  [[ -f "$SUSPEND" ]] && return 0          # 用户挂起，不动作
  if [[ ! -f "$MARKER" ]] || ! dns_active; then
    QUIET=1 "$LIBDIR/v6on.sh" >> "$LOG" 2>&1
    log "campus detected (gw=$(dhcp_field router)) → v6-prefer ON"
  fi
}

silently_off() {
  [[ -f "$SUSPEND" ]] && return 0
  if [[ -f "$MARKER" ]]; then
    QUIET=1 "$LIBDIR/v6off.sh" >> "$LOG" 2>&1
    log "left campus → v6-prefer OFF"
  fi
}

log "v6-watch v2 started (iface=$IFACE mode=v6-prefer ssids=[$SSID_LIST])"
while true; do
  if [[ -f "$SUSPEND" ]]; then
    sleep "$CHECK_INTERVAL"
    continue
  fi
  if campus; then
    silently_on
  else
    silently_off
  fi
  sleep "$CHECK_INTERVAL"
done
