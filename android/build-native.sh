#!/bin/bash
set -euo pipefail
PROJ="$(cd "$(dirname "$0")" && pwd)"
source "$PROJ/sdk-env.sh"
NDK="${ANDROID_NDK_HOME:-$SDK/ndk/29.0.13846066}"
case "$(uname -s)" in Darwin) HOST_TAG=darwin-x86_64;; Linux) HOST_TAG=linux-x86_64;; *) echo 'Build Android native libraries on macOS/Linux' >&2; exit 1;; esac
for ABI in ${V6ONLY_ANDROID_ABIS:-arm64-v8a x86_64}; do
 case "$ABI" in arm64-v8a) ARCH=arm64; TARGET=aarch64-linux-android;; x86_64) ARCH=amd64; TARGET=x86_64-linux-android;; *) echo "Unsupported ABI $ABI" >&2; exit 1;; esac
 CC_PATH="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/${TARGET}29-clang"
 [[ -x "$CC_PATH" ]] || { echo "Missing NDK compiler: $CC_PATH" >&2; exit 1; }
 mkdir -p "$PROJ/build/apk/lib/$ABI"
 (cd "$PROJ/../core" && CGO_ENABLED=1 GOOS=android GOARCH="$ARCH" CC="$CC_PATH" go build -trimpath -ldflags='-s -w' -buildmode=c-shared -o "$PROJ/build/apk/lib/$ABI/libv6core.so" ./mobile)
 rm -f "$PROJ/build/apk/lib/$ABI/libv6core.h"
done
