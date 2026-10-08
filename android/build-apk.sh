#!/bin/bash
# build-apk.sh — 无 gradle 本地 APK 构建流水线
# aapt2 link → javac → d8 → 打包 → zipalign → apksigner
# 依赖：ANDROID_HOME（~/Library/Android/sdk），JDK 17+，调试密钥库自动生成

set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
source "$PROJ/sdk-env.sh"
OUT="$PROJ/build"
KEYSTORE="${V6ONLY_KEYSTORE:-$PROJ/debug.keystore}"
APK="$PROJ/v6only.apk"

rm -rf "$OUT"; mkdir -p "$OUT/gen" "$OUT/obj" "$OUT/apk"
MANIFEST="$PROJ/app/src/main/AndroidManifest.xml"
if [[ ${V6ONLY_TEST_FIXTURE:-0} == 1 ]]; then
  [[ -z ${V6ONLY_KEYSTORE:-} ]] || { echo 'Fixture APK must use a debug key' >&2; exit 1; }
  MANIFEST="$OUT/fixture-manifest.xml"
  python3 - "$PROJ/app/src/main/AndroidManifest.xml" "$MANIFEST" <<'PY'
import sys
from pathlib import Path
s=Path(sys.argv[1]).read_text()
s=s.replace('</application>', '<activity android:name=".HandoverActivity" android:exported="false"/></application>')
s=s.replace('</application>', '<service android:name=".FixtureVpn" android:exported="false" android:permission="android.permission.BIND_VPN_SERVICE" android:foregroundServiceType="specialUse"><property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE" android:value="Disposable emulator networking fixture"/><intent-filter><action android:name="android.net.VpnService"/></intent-filter></service></application>')
s=s.replace('</application>', '<service android:name=".HandoverVpn" android:exported="false" android:permission="android.permission.BIND_VPN_SERVICE" android:foregroundServiceType="specialUse"><property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE" android:value="Disposable emulator handover fixture"/><meta-data android:name="android.net.VpnService.SUPPORTS_ALWAYS_ON" android:value="false"/><intent-filter><action android:name="android.net.VpnService"/></intent-filter></service></application>')
Path(sys.argv[2]).write_text(s)
PY
  APK="$PROJ/v6only-fixture.apk"
fi

echo "[1/6] aapt2 编译资源+链接 Manifest"
"$BT/aapt2" compile --dir "$PROJ/app/src/main/res" -o "$OUT/res.zip"
"$BT/aapt2" link -o "$OUT/apk/base.apk" \
  -I "$PLATFORM" \
  --manifest "$MANIFEST" \
  --java "$OUT/gen" \
  --auto-add-overlay \
  "$OUT/res.zip"

echo "[2/6] javac 编译"
find "$PROJ/app/src/main/java" "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
if [[ ${V6ONLY_TEST_FIXTURE:-0} == 1 ]]; then
  find "$PROJ/tests/fixture" -name '*.java' >> "$OUT/sources.txt"
fi
javac --release 17 \
  -classpath "$PLATFORM" \
  -d "$OUT/obj" \
  @"$OUT/sources.txt"

echo "[3/6] d8 转 dex"
find "$OUT/obj" -name '*.class' > "$OUT/classes.txt"
"$BT/d8" --release \
  --lib "$PLATFORM" \
  --min-api 29 \
  --output "$OUT/apk" \
  @"$OUT/classes.txt"

bash "$PROJ/build-native.sh"
python3 "$PROJ/../scripts/collect-licenses.py" "$OUT/apk/assets/third-party"
cp "$PROJ/../LICENSE" "$OUT/apk/assets/LICENSE"

echo "[4/6] 打入 classes.dex"
cd "$OUT/apk"
zip -qj base.apk classes.dex
zip -qr base.apk lib assets

echo "[5/6] zipalign"
"$BT/zipalign" -P 16 -f 4 base.apk aligned.apk

echo "[6/6] apksigner 签名"
if [[ -n "${V6ONLY_KEYSTORE:-}" ]]; then
  : "${V6ONLY_STORE_PASSWORD:?Set V6ONLY_STORE_PASSWORD for the release keystore}"
  : "${V6ONLY_KEY_PASSWORD:=$V6ONLY_STORE_PASSWORD}"
  export V6ONLY_STORE_PASSWORD V6ONLY_KEY_PASSWORD
elif [[ ! -f "$KEYSTORE" ]]; then
  keytool -genkeypair -keystore "$KEYSTORE" -storepass v6only -keypass v6only \
    -alias v6only -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=v6only, OU=rev, O=buaa, C=CN" >/dev/null 2>&1
fi
export V6ONLY_STORE_PASSWORD="${V6ONLY_STORE_PASSWORD:-v6only}"
export V6ONLY_KEY_PASSWORD="${V6ONLY_KEY_PASSWORD:-v6only}"
"$BT/apksigner" sign \
  --ks "$KEYSTORE" --ks-key-alias "${V6ONLY_KEY_ALIAS:-v6only}" \
  --ks-pass env:V6ONLY_STORE_PASSWORD --key-pass env:V6ONLY_KEY_PASSWORD \
  --v4-signing-enabled false --out "$APK" aligned.apk

"$BT/apksigner" verify --print-certs "$APK" | head -4
echo
echo "✅ 产物：$APK"
echo "   安装：adb install -r $APK"
