#!/bin/bash
set -euo pipefail
# shellcheck source=macos/v6-common.sh
source "$(dirname "$0")/v6-common.sh"
require_root
LIB=/usr/local/lib/v6only
PLIST=/Library/LaunchDaemons/edu.buaa.v6only-watch.plist
if launchctl print system/edu.buaa.v6only-watch >/dev/null 2>&1; then
    launchctl bootout system/edu.buaa.v6only-watch
fi
# Keep installation and snapshots if restoration fails.
/bin/bash "$LIB/v6ctl.sh" off auto
rm -f "$PLIST" "$SUSPEND"
rm -rf "$LIB"
printf '已卸载。安装备份仍保留在 %s/backups。\n' "$STATE_DIR"
