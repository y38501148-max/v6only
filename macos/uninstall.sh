#!/bin/bash
# uninstall.sh — 卸载 v6only 静默守护并完整还原
set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "需要 root：sudo $0" >&2; exit 1; }

LIB="/usr/local/lib/v6only"
PLIST_ID="edu.buaa.v6only-watch"
PLIST="/Library/LaunchDaemons/$PLIST_ID.plist"

echo "── 卸载 v6only 静默守护 ──"

# 1. 停守护
launchctl bootout system "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "✓ LaunchDaemon 已移除"

# 2. 回滚网络状态（若当前生效）
if [[ -f "$LIB/v6off.sh" ]]; then
  QUIET=1 "$LIB/v6off.sh" || true
fi

# 3. 清文件与标记
rm -f /var/run/v6only.active
rm -rf "$LIB"
echo "✅ 卸载完成，网络已还原"
