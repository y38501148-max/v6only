#!/bin/bash
# build-apk.sh — 无 gradle 本地 APK 构建流水线
# aapt2 link → javac → d8 → 打包 → zipalign → apksigner
# 依赖：ANDROID_HOME（~/Library/Android/sdk），JDK 17+，调试密钥库自动生成

set -euo pipefail

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/35.0.0"
PLATFORM="$SDK/platforms/android-36/android.jar"
PROJ="$(cd "$(dirname "$0")" && pwd)"
OUT="$PROJ/build"
KEYSTORE="$PROJ/debug.keystore"

rm -rf "$OUT"; mkdir -p "$OUT/gen" "$OUT/obj" "$OUT/apk"

echo "[1/6] aapt2 编译资源+链接 Manifest"
"$BT/aapt2" compile --dir "$PROJ/app/src/main/res" -o "$OUT/res.zip"
"$BT/aapt2" link -o "$OUT/apk/base.apk" \
  -I "$PLATFORM" \
  --manifest "$PROJ/app/src/main/AndroidManifest.xml" \
  --java "$OUT/gen" \
  --auto-add-overlay \
  "$OUT/res.zip"

echo "[2/6] javac 编译"
find "$PROJ/app/src/main/java" "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
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

echo "[4/6] 打入 classes.dex"
cd "$OUT/apk"
zip -qj base.apk classes.dex

echo "[5/6] zipalign"
"$BT/zipalign" -f 4 base.apk aligned.apk

echo "[6/6] apksigner 签名"
if [[ ! -f "$KEYSTORE" ]]; then
  keytool -genkeypair -keystore "$KEYSTORE" -storepass v6only -keypass v6only \
    -alias v6only -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=v6only, OU=rev, O=buaa, C=CN" >/dev/null 2>&1
fi
"$BT/apksigner" sign \
  --ks "$KEYSTORE" --ks-pass pass:v6only --key-pass pass:v6only \
  --out "$PROJ/v6only.apk" aligned.apk

"$BT/apksigner" verify --print-certs "$PROJ/v6only.apk" | head -4
echo
echo "✅ 产物：$PROJ/v6only.apk"
echo "   安装：adb install -r $PROJ/v6only.apk"
