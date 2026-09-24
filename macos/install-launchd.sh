#!/bin/bash
# Installs only after source validation and a recoverable backup.
set -eEuo pipefail
# shellcheck source=macos/v6-common.sh
source "$(dirname "$0")/v6-common.sh"
require_root
umask 077
LIB=/usr/local/lib/v6only
PLIST_ID=edu.buaa.v6only-watch
PLIST="/Library/LaunchDaemons/$PLIST_ID.plist"
MODE="${1:-}"
FILES=(v6-common.sh v6ctl.sh v6on.sh v6off.sh v6-watch.sh test-suite.sh uninstall.sh anchor-v6only)
for file in "${FILES[@]}"; do
    [[ -f "$V6_DIR/$file" ]] || die "缺少源文件：$file"
    if [[ "$file" == *.sh ]]; then /bin/bash -n "$V6_DIR/$file"; fi
done
[[ "$IFACE" == en0 && "$SERVICE" == Wi-Fi ]] || die '安装器当前仅配置 Wi-Fi/en0；其他接口请手动运行控制脚本。'
pfctl -n -a "$PF_ANCHOR" -f "$V6_DIR/anchor-v6only"
RULES=$(pfctl -sr 2>/dev/null)
MIGRATE=0
if ! pf_hook_present; then
    if [[ "$MODE" == --migrate-legacy ]]; then
        EXPECTED='block drop out on en0 inet proto udp from any to ! <campus_v4> port = 53
block drop out on en0 inet proto tcp from any to ! <campus_v4> port = 53
pass out on en0 inet6 all flags S/SA keep state'
        [[ "$RULES" == "$EXPECTED" ]] || die '主规则不符合已知旧版，拒绝自动迁移。'
    elif [[ "$MODE" == --initialize-pf ]]; then
        [[ -z "$RULES" && -z "$(pfctl -sn 2>/dev/null)" ]] || die '现有 PF 规则非空，拒绝初始化。'
    else
        die '缺少 PF anchor 入口；旧版使用 --migrate-legacy，空规则初装使用 --initialize-pf。'
    fi
    pfctl -nf /etc/pf.conf
    MIGRATE=1
fi
mkdir -p "$STATE_DIR/backups"
chmod 700 "$STATE_DIR"
BACKUP=$(mktemp -d "$STATE_DIR/backups/install.XXXXXX")
[[ ! -d "$LIB" ]] || cp -Rp "$LIB" "$BACKUP/lib"
[[ ! -f "$PLIST" ]] || cp -p "$PLIST" "$BACKUP/daemon.plist"
[[ ! -f "$MARKER" ]] || cp -p "$MARKER" "$BACKUP/active"
[[ ! -f "$SUSPEND" ]] || cp -p "$SUSPEND" "$BACKUP/suspend"
mkdir "$BACKUP/runtime"
for file in original pf.expected pf.loaded pf.token bypass.expected bypass.added rules.signature; do
    [[ ! -e "$STATE_DIR/$file" ]] || cp -Rp "$STATE_DIR/$file" "$BACKUP/runtime/"
done
pfctl -sr > "$BACKUP/pf.rules" 2>/dev/null
pfctl -sn > "$BACKUP/pf.nat" 2>/dev/null
networksetup -getdnsservers "$SERVICE" > "$BACKUP/dns"
scutil --proxy > "$BACKUP/proxy"
STAGE=$(mktemp -d /usr/local/lib/v6only-stage.XXXXXX)
for file in "${FILES[@]}"; do cp "$V6_DIR/$file" "$STAGE/$file"; done
chown -R root:wheel "$STAGE"
chmod 755 "$STAGE" "$STAGE"/*.sh
chmod 644 "$STAGE/anchor-v6only"
WAS_RUNNING=0
if launchctl print "system/$PLIST_ID" >/dev/null 2>&1; then WAS_RUNNING=1; fi

installation_failed() {
    local status=$?
    trap - ERR
    set +e
    launchctl bootout "system/$PLIST_ID" 2>/dev/null
    # v6ctl handles rollback of its own partial application.
    if [[ -d "$ORIGINAL" ]]; then /bin/bash "$LIB/v6ctl.sh" off auto; fi
    if [[ -d "$BACKUP/lib" ]]; then
        rm -rf "$LIB"
        cp -Rp "$BACKUP/lib" "$LIB"
    else
        rm -rf "$LIB"
    fi
    if [[ "$MIGRATE" -eq 1 && -f "$BACKUP/lib/anchor-v6only" ]]; then
        pfctl -f "$BACKUP/lib/anchor-v6only"
    fi
    [[ ! -f "$BACKUP/active" ]] || cp -p "$BACKUP/active" "$MARKER"
    [[ ! -f "$BACKUP/suspend" ]] || cp -p "$BACKUP/suspend" "$SUSPEND"
    for file in "$BACKUP/runtime/"*; do
        [[ ! -e "$file" ]] || cp -Rp "$file" "$STATE_DIR/"
    done
    if [[ -f "$BACKUP/active" && -f "$LIB/v6ctl.sh" ]]; then
        /bin/bash "$LIB/v6ctl.sh" on
    fi
    if [[ -f "$BACKUP/daemon.plist" ]]; then
        cp -p "$BACKUP/daemon.plist" "$PLIST"
        if [[ "$WAS_RUNNING" -eq 1 ]]; then launchctl bootstrap system "$PLIST"; fi
    else
        rm -f "$PLIST"
    fi
    printf '安装失败；已尝试恢复旧版，备份：%s\n' "$BACKUP" >&2
    exit "$status"
}
trap installation_failed ERR
if [[ "$WAS_RUNNING" -eq 1 ]]; then launchctl bootout "system/$PLIST_ID"; fi
# The old shell may have an in-flight child; wait before changing its files/rules.
for _attempt in 1 2 3 4 5; do
    if ! pgrep -f '^/bin/bash /usr/local/lib/v6only/v6(on|off)\.sh' >/dev/null; then break; fi
    sleep 2
done
if pgrep -f '^/bin/bash /usr/local/lib/v6only/v6(on|off)\.sh' >/dev/null; then
    die '旧版配置操作仍在运行，停止安装。'
fi
if [[ "$MIGRATE" -eq 1 ]]; then pfctl -f /etc/pf.conf; fi
if [[ -d "$LIB" ]]; then mv "$LIB" "$BACKUP/replaced-lib"; fi
mv "$STAGE" "$LIB"
# A legacy active marker is not a snapshot of the previous network settings.
if [[ ! -d "$ORIGINAL" ]]; then rm -f "$MARKER"; fi
if campus && ! suspended; then /bin/bash "$LIB/v6ctl.sh" on; fi
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$PLIST_ID</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$LIB/v6-watch.sh</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>$LOG</string>
<key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
plutil -lint "$PLIST"
launchctl bootstrap system "$PLIST"
launchctl print "system/$PLIST_ID" >/dev/null
trap - ERR
printf '安装完成。配置备份：%s\n验证：sudo %s/test-suite.sh\n' "$BACKUP" "$LIB"
