#!/bin/bash
# Shared build configuration. Source from build/test scripts.
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
BT="${ANDROID_BUILD_TOOLS:-$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)}"
PLATFORM="${ANDROID_PLATFORM_JAR:-$(ls "$SDK"/platforms/*/android.jar 2>/dev/null | sort -V | tail -1)}"
if [[ ! -x "$BT/aapt2" || ! -f "$PLATFORM" ]]; then
  echo 'Install Android SDK build-tools and platform API 34+, or set ANDROID_HOME.' >&2
  exit 1
fi
