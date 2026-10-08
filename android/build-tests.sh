#!/bin/bash
# Build instrumentation without replacing the production APK or its native libraries.
set -euo pipefail
PROJ="$(cd "$(dirname "$0")" && pwd)"
source "$PROJ/sdk-env.sh"
OUT="$PROJ/build/instrumentation"
mkdir -p "$OUT/obj" "$OUT/apk"
"$BT/aapt2" link -o "$OUT/apk/base.apk" -I "$PLATFORM" --manifest "$PROJ/tests/device/AndroidManifest.xml"
find "$PROJ/tests/device" -name '*.java' > "$OUT/sources.txt"
javac --release 17 -classpath "$PLATFORM:$PROJ/build/obj" -d "$OUT/obj" @"$OUT/sources.txt"
find "$OUT/obj" -name '*.class' > "$OUT/classes.txt"
"$BT/d8" --release --lib "$PLATFORM" --classpath "$PROJ/build/obj" --min-api 29 --output "$OUT/apk" @"$OUT/classes.txt"
(cd "$OUT/apk" && zip -qj base.apk classes.dex)
"$BT/zipalign" -f 4 "$OUT/apk/base.apk" "$OUT/apk/aligned.apk"
"$BT/apksigner" sign --ks "$PROJ/debug.keystore" --ks-pass pass:v6only --v4-signing-enabled false --out "$OUT/tests.apk" "$OUT/apk/aligned.apk"
