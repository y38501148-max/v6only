#!/bin/bash
# Run only on a disposable emulator: changes v6only settings and removes its activity task.
set -euo pipefail
PROJ="$(cd "$(dirname "$0")" && pwd)"
source "$PROJ/sdk-env.sh"
ADB=("$SDK/platform-tools/adb")
if [[ -n "${ANDROID_SERIAL:-}" ]]; then ADB+=(-s "$ANDROID_SERIAL"); fi
if [[ "$("${ADB[@]}" shell getprop ro.kernel.qemu | tr -d '\r')" != 1 ]]; then
  echo 'Use a disposable emulator (set ANDROID_SERIAL), not a personal phone.' >&2
  exit 1
fi
if [[ -n "${V6ONLY_KEYSTORE:-}" ]]; then
  echo 'Device tests use the local debug key; unset V6ONLY_KEYSTORE.' >&2
  exit 1
fi
# The fixture lives on emulator loopback. Public captive-portal probes can be
# unreachable on CI and disable AndroidWifi auto-join before the app even starts.
"${ADB[@]}" shell settings put global captive_portal_mode 0
if [[ ${V6ONLY_TEST_SUITE:-network} == tunnel || ${V6ONLY_TEST_SUITE:-network} == handover ]]; then export V6ONLY_TEST_FIXTURE=1; fi
bash "$PROJ/build-apk.sh"
OUT="$PROJ/build/device-tests"
mkdir -p "$OUT/obj" "$OUT/apk" "$OUT/web"
printf 'v6only network regression fixture\n' > "$OUT/web/marker"
if [[ ${V6ONLY_TEST_SUITE:-network} == tunnel ]]; then
  (cd "$PROJ/../core" && go build -o "$OUT/netfixture" ./cmd/netfixture)
  "$OUT/netfixture" --listen4 127.0.0.1 --listen6 ::1 --v4 10.0.2.2 --v6 fec0::2 --bad6 ::1 > "$OUT/http.log" 2>&1 &
else
  (cd "$OUT/web" && exec python3 "$PROJ/tests/device/network-fixture.py") > "$OUT/http.log" 2>&1 &
fi
SERVER_PID=$!
cleanup() {
  local result=$?
  if [[ $result -ne 0 ]]; then
    "${ADB[@]}" shell dumpsys connectivity > "$OUT/connectivity.log" 2>&1 || true
    "${ADB[@]}" shell ip route show table all > "$OUT/routes.log" 2>&1 || true
    "${ADB[@]}" logcat -d -v threadtime > "$OUT/service.log" 2>&1 || true
  fi
  kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT
instrument() {
  python3 - "${ADB[@]}" shell am instrument -w "$1" <<'PYTHON'
import subprocess,sys
try:
    sys.exit(subprocess.run(sys.argv[1:],timeout=180).returncode)
except subprocess.TimeoutExpired:
    print("Instrumentation did not finish in 180 seconds",file=sys.stderr)
    sys.exit(1)
PYTHON
}
# Fail before running the app if either fixture could not bind.
sleep 0.3
kill -0 "$SERVER_PID" || { cat "$OUT/http.log" >&2; exit 1; }
"$BT/aapt2" link -o "$OUT/apk/base.apk" -I "$PLATFORM" \
  --manifest "$PROJ/tests/device/AndroidManifest.xml"
find "$PROJ/tests/device" -name '*.java' > "$OUT/sources.txt"
javac --release 17 -classpath "$PLATFORM:$PROJ/build/obj" -d "$OUT/obj" @"$OUT/sources.txt"
find "$OUT/obj" -name '*.class' > "$OUT/classes.txt"
"$BT/d8" --release --lib "$PLATFORM" --classpath "$PROJ/build/obj" --min-api 29 \
  --output "$OUT/apk" @"$OUT/classes.txt"
(cd "$OUT/apk" && zip -qj base.apk classes.dex)
"$BT/zipalign" -f 4 "$OUT/apk/base.apk" "$OUT/apk/aligned.apk"
"$BT/apksigner" sign --ks "$PROJ/debug.keystore" --ks-pass pass:v6only \
  --v4-signing-enabled false --out "$OUT/tests.apk" "$OUT/apk/aligned.apk"
APK="$PROJ/v6only.apk"
[[ ${V6ONLY_TEST_FIXTURE:-0} != 1 ]] || APK="$PROJ/v6only-fixture.apk"
"${ADB[@]}" install --no-incremental -r "$APK"
"${ADB[@]}" install --no-incremental -r "$OUT/tests.apk"
if [[ ${V6ONLY_TEST_SUITE:-network} == cellular ]]; then
  "${ADB[@]}" emu gsm data home
  "${ADB[@]}" shell svc wifi disable
  "${ADB[@]}" shell svc data enable
  "${ADB[@]}" shell appops set edu.buaa.v6only ACTIVATE_VPN deny
else
  "${ADB[@]}" shell appops set edu.buaa.v6only ACTIVATE_VPN allow
fi
if [[ $("${ADB[@]}" shell getprop ro.build.version.sdk | tr -d '\r') -ge 33 ]]; then
  "${ADB[@]}" shell pm grant edu.buaa.v6only android.permission.POST_NOTIFICATIONS
fi
case "${V6ONLY_TEST_SUITE:-network}" in
  network|ui|all|tunnel|cellular|handover|other-vpn) ;;
  *) echo 'V6ONLY_TEST_SUITE must be network, ui, all, tunnel, cellular, handover or other-vpn.' >&2; exit 1 ;;
esac
# A failed consent test can leave an OS dialog above the next instrumentation activity.
"${ADB[@]}" shell am force-stop com.android.vpndialogs
"${ADB[@]}" shell am force-stop edu.buaa.v6only
if [[ ${V6ONLY_TEST_SUITE:-network} == other-vpn ]]; then
  "${ADB[@]}" shell svc wifi disable
  "${ADB[@]}" shell svc data enable
  "${ADB[@]}" shell appops set edu.buaa.v6only.tests ACTIVATE_VPN allow
  instrument edu.buaa.v6only.tests/.OtherVpnSmoke | tee "$OUT/result.txt"
  "${ADB[@]}" shell am force-stop edu.buaa.v6only.tests
  grep -q 'PASS: cellular start/reapply/update/stop preserve another VPN' "$OUT/result.txt"
  exit
fi
if [[ ${V6ONLY_TEST_SUITE:-network} == handover ]]; then
  instrument edu.buaa.v6only.tests/.HandoverSmoke | tee "$OUT/result.txt"
  grep -q 'PASS: Android campus-to-cellular handover' "$OUT/result.txt"
  exit
fi
if [[ ${V6ONLY_TEST_SUITE:-network} == cellular ]]; then
  instrument edu.buaa.v6only.tests/.CellularSmoke | tee "$OUT/result.txt"
  grep -q 'PASS: cellular startup' "$OUT/result.txt"
  exit
fi
if [[ ${V6ONLY_TEST_SUITE:-network} == tunnel ]]; then
  instrument edu.buaa.v6only.tests/.TunnelSmoke | tee "$OUT/result.txt"
  grep -q 'PASS: Android native tunnel integration' "$OUT/result.txt"
  exit
fi
if [[ "${V6ONLY_TEST_SUITE:-network}" != ui ]]; then
  instrument edu.buaa.v6only.tests/.NetworkSmoke | tee "$OUT/result.txt"
  grep -q 'PASS: all Android device regression checks' "$OUT/result.txt"
fi
if [[ "${V6ONLY_TEST_SUITE:-network}" != network ]]; then
  "$PROJ/ui-test.sh"
fi
