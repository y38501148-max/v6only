#!/bin/bash
# install-launchd.sh — 安装 v6only 静默守护（launchd 根守护，开机自启）
# 安装内容：
#   /usr/local/lib/v6only/{v6on.sh,v6off.sh,anchor-v6only}   引擎（root 执行）
#   /usr/local/lib/v6only/v6-watch.sh                        SSID 感知守护循环
#   /Library/LaunchDaemons/edu.buaa.v6only-watch.plist       开机自启注册
# 卸载：/usr/local/lib/v6only/uninstall.sh

set -euo pipefail
[[ $EUID -ne 0 ]] && { echo "需要 root：sudo $0" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")/.." && pwd)"
LIB="/usr/local/lib/v6only"
PLIST_ID="edu.buaa.v6only-watch"
PLIST="/Library/LaunchDaemons/$PLIST_ID.plist"
LOG="/var/log/v6only.log"

echo "── 安装 v6only 静默守护 ──"

# 0. 若已装过，先停旧的
if launchctl list "$PLIST_ID" >/dev/null 2>&1; then
  launchctl bootout system "$PLIST" 2>/dev/null || true
fi

# 1. 部署引擎
mkdir -p "$LIB"
cp "$SRC/v6on.sh" "$SRC/v6off.sh" "$SRC/anchor-v6only" "$LIB/"
cp "$SRC/autostart/v6-watch.sh" "$LIB/"
chmod 700 "$LIB"/*.sh
chmod 644 "$LIB/anchor-v6only"

# 2. 生成 LaunchDaemon plist（KeepAlive=开机自启+崩溃拉起）
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$PLIST_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$LIB/v6-watch.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# 3. 注册并立即拉起
launchctl bootstrap system "$PLIST"
launchctl kickstart system/"$PLIST_ID"

sleep 2
if launchctl list "$PLIST_ID" >/dev/null 2>&1; then
  echo "✅ 守护已安装并运行"
  echo "   日志：$LOG"
  echo "   卸载：sudo $LIB/uninstall.sh"
else
  echo "⚠️ 注册未确认，检查：sudo launchctl list | grep v6only"
fi
