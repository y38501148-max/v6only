#!/bin/bash
# Run after device-test.sh built/installed the matching instrumentation APK.
set -euo pipefail
PROJ="$(cd "$(dirname "$0")" && pwd)"
source "$PROJ/sdk-env.sh"
ADB=("$SDK/platform-tools/adb")
if [[ -n "${ANDROID_SERIAL:-}" ]]; then ADB+=(-s "$ANDROID_SERIAL"); fi
if [[ "$("${ADB[@]}" shell getprop ro.kernel.qemu | tr -d '\r')" != 1 ]]; then
  echo 'UI checks require a disposable emulator.' >&2
  exit 1
fi
OUT="$PROJ/build/ui-tests"
mkdir -p "$OUT"
restore() {
  "${ADB[@]}" shell cmd uimode night no >/dev/null || true
  "${ADB[@]}" shell settings put system font_scale 1.0 >/dev/null || true
  "${ADB[@]}" shell wm size reset >/dev/null || true
}
trap restore EXIT
run_case() {
  "${ADB[@]}" shell am instrument -w -e scenario "$1" edu.buaa.v6only.tests/.UiSmoke | tee "$OUT/$1.txt"
  grep -q "PASS: Android UI checks ($1)" "$OUT/$1.txt"
}
restore
run_case light
"${ADB[@]}" shell cmd uimode night yes
run_case dark
"${ADB[@]}" shell wm size 840x1600
"${ADB[@]}" shell settings put system font_scale 1.5
run_case compact-large-font
"${ADB[@]}" shell settings put system font_scale 1.0
"${ADB[@]}" shell wm size 1600x840
run_case landscape
"${ADB[@]}" pull /sdcard/Android/data/edu.buaa.v6only/files/ui-checks "$OUT/"
