#!/bin/bash
# Pure address/readiness assertions on Android's runtime. No APK installation,
# app data access, VPN startup, or network settings changes.
set -euo pipefail
PROJ="$(cd "$(dirname "$0")" && pwd)"
source "$PROJ/sdk-env.sh"
: "${ANDROID_SERIAL:?Select the Android device with ANDROID_SERIAL}"
ADB_BIN="${ADB:-adb}"
OUT="$PROJ/build/readiness-unit"
REMOTE="/data/local/tmp/v6only-readiness-$$.dex"
mkdir -p "$OUT/obj" "$OUT/dex"
javac --release 17 -classpath "$PLATFORM" -d "$OUT/obj" \
  "$PROJ/app/src/main/java/edu/buaa/v6only/NetworkReadiness.java" \
  "$PROJ/tests/device/edu/buaa/v6only/tests/ReadinessSmoke.java"
find "$OUT/obj" -name '*.class' > "$OUT/classes.txt"
"$BT/d8" --lib "$PLATFORM" --min-api 29 --output "$OUT/dex" @"$OUT/classes.txt"
trap '"$ADB_BIN" -s "$ANDROID_SERIAL" shell rm -f "$REMOTE" >/dev/null 2>&1 || true' EXIT
"$ADB_BIN" -s "$ANDROID_SERIAL" push "$OUT/dex/classes.dex" "$REMOTE"
"$ADB_BIN" -s "$ANDROID_SERIAL" shell "CLASSPATH=$REMOTE app_process /system/bin edu.buaa.v6only.tests.ReadinessSmoke"
