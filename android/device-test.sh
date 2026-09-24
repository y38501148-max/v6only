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
bash "$PROJ/build-apk.sh"
OUT="$PROJ/build/device-tests"
mkdir -p "$OUT/obj" "$OUT/apk" "$OUT/web"
printf 'v6only network regression fixture\n' > "$OUT/web/marker"
(cd "$OUT/web" && exec python3 "$PROJ/tests/device/network-fixture.py") > "$OUT/http.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
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
"${ADB[@]}" install --no-incremental -r "$PROJ/v6only.apk"
"${ADB[@]}" install --no-incremental -r "$OUT/tests.apk"
"${ADB[@]}" shell appops set edu.buaa.v6only ACTIVATE_VPN allow
"${ADB[@]}" shell pm grant edu.buaa.v6only android.permission.POST_NOTIFICATIONS || true
case "${V6ONLY_TEST_SUITE:-network}" in
  network|ui|all) ;;
  *) echo 'V6ONLY_TEST_SUITE must be network, ui or all.' >&2; exit 1 ;;
esac
if [[ "${V6ONLY_TEST_SUITE:-network}" != ui ]]; then
  "${ADB[@]}" shell am instrument -w edu.buaa.v6only.tests/.NetworkSmoke | tee "$OUT/result.txt"
  grep -q 'PASS: all Android device regression checks' "$OUT/result.txt"
fi
if [[ "${V6ONLY_TEST_SUITE:-network}" != network ]]; then
  "$PROJ/ui-test.sh"
fi
