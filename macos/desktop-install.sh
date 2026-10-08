#!/bin/bash
set -eEuo pipefail
[[ $EUID -eq 0 ]] || { echo '需要管理员授权。' >&2; exit 1; }
DESKTOP_UID="${1:?Missing desktop UID}"
[[ "$DESKTOP_UID" =~ ^[0-9]+$ && "$DESKTOP_UID" -ge 500 ]] || { echo 'Invalid desktop UID' >&2;exit 1; }
INSTALL_MODE="${2:-enable}"
[[ "$INSTALL_MODE" == enable || "$INSTALL_MODE" == pause ]] || { echo "Invalid install mode" >&2;exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)
LIB=/usr/local/lib/v6only
STATE=/var/db/v6only
mkdir -p "$STATE/backups" /usr/local/lib
chmod 700 "$STATE"
BACKUP=$(mktemp -d "$STATE/backups/desktop.XXXXXX")
[[ ! -d "$LIB" ]] || cp -Rp "$LIB" "$BACKUP/lib"
[[ ! -f /var/run/v6only.suspend ]] || cp -p /var/run/v6only.suspend "$BACKUP/suspend"
WATCH_RUNNING=0
if launchctl print system/edu.buaa.v6only-watch >/dev/null 2>&1;then WATCH_RUNNING=1;fi
rollback_install() {
    local code=$?
    trap - ERR
    set +e
    launchctl bootout system/edu.buaa.v6only-watch 2>/dev/null
    launchctl bootout system/edu.buaa.v6only-desktop 2>/dev/null
    if [[ -f "$LIB/v6ctl.sh" ]];then /bin/bash "$LIB/v6ctl.sh" off auto;fi
    if [[ -d "$BACKUP/lib" ]];then
        [[ ! -d "$LIB" ]] || mv "$LIB" "$BACKUP/failed-lib"
        cp -Rp "$BACKUP/lib" "$LIB"
    fi
    for label in edu.buaa.v6only-watch edu.buaa.v6only-desktop;do
        if [[ -f "$BACKUP/$label.plist" ]];then cp -p "$BACKUP/$label.plist" "/Library/LaunchDaemons/$label.plist";fi
    done
    [[ ! -f "$BACKUP/suspend" ]] || cp -p "$BACKUP/suspend" /var/run/v6only.suspend
    if [[ "$WATCH_RUNNING" == 1 ]];then launchctl bootstrap system /Library/LaunchDaemons/edu.buaa.v6only-watch.plist;fi
    echo "安装失败，已尝试恢复旧版。备份：$BACKUP" >&2
    exit "$code"
}
trap rollback_install ERR
for label in edu.buaa.v6only-watch edu.buaa.v6only-desktop; do
 [[ ! -f "/Library/LaunchDaemons/$label.plist" ]] || cp -p "/Library/LaunchDaemons/$label.plist" "$BACKUP/"
 launchctl bootout "system/$label" 2>/dev/null || true
done
if [[ -f "$LIB/v6ctl.sh" ]];then /bin/bash "$LIB/v6ctl.sh" off auto; fi
: > /var/run/v6only.suspend
STAGE=$(mktemp -d /usr/local/lib/v6only-desktop-stage.XXXXXX)
for file in v6core v6service v6-common.sh v6-runtime.sh v6ctl.sh v6on.sh v6off.sh v6-watch.sh anchor-v6only test-suite.sh uninstall.sh;do
 [[ -f "$SRC/$file" ]] || { echo "缺少 $file" >&2;exit 1; }
 cp -p "$SRC/$file" "$STAGE/$file"
done
chown -R root:wheel "$STAGE"
chmod 755 "$STAGE" "$STAGE"/v6core "$STAGE"/v6service "$STAGE"/*.sh
chmod 644 "$STAGE/anchor-v6only"
if ! pfctl -sr 2>/dev/null | grep -Eq '^anchor "com\.apple/\*"( all)?$';then
 if [[ -z "$(pfctl -sr 2>/dev/null)" && -z "$(pfctl -sn 2>/dev/null)" ]];then pfctl -nf /etc/pf.conf;pfctl -f /etc/pf.conf;else echo 'PF 主规则缺少 com.apple/* 入口；保留现有规则，安装停止。' >&2;exit 1;fi
fi
if [[ -d "$LIB" ]];then mv "$LIB" "$BACKUP/replaced-lib";fi
mv "$STAGE" "$LIB"
for label in edu.buaa.v6only-watch edu.buaa.v6only-desktop;do
 plist="/Library/LaunchDaemons/$label.plist"
 if [[ "$label" == edu.buaa.v6only-watch ]];then ARGS="<string>/bin/bash</string><string>$LIB/v6-watch.sh</string>";else ARGS="<string>$LIB/v6service</string><string>--uid</string><string>$DESKTOP_UID</string>";fi
 cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$label</string><key>ProgramArguments</key><array>$ARGS</array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Background</string><key>StandardOutPath</key><string>/var/log/v6only.log</string><key>StandardErrorPath</key><string>/var/log/v6only.log</string></dict></plist>
PLIST
 chown root:wheel "$plist";chmod 644 "$plist";plutil -lint "$plist";launchctl bootstrap system "$plist"
done
# Keep the control service installed even if network validation fails. v6ctl
# restores its own network state; the desktop can show the exact failure.
if [[ "$INSTALL_MODE" == pause ]];then
 echo '后台服务已更新，保留转发暂停状态。'
elif ! /bin/bash "$LIB/v6ctl.sh" on >> /var/log/v6only.log 2>&1;then
 echo '后台服务已安装。转发检测未通过，网络已回滚；请在应用中查看日志。'
else
 echo '后台服务已安装，严格 IPv6 转发已开启。'
fi
trap - ERR
echo "旧版备份：$BACKUP"
