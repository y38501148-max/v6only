#!/bin/bash
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$PROJ/VERSION")"
OUT="$PROJ/desktop/src-tauri/resources/macos"
mkdir -p "$OUT"
(cd "$PROJ/core" && go build -trimpath -ldflags="-s -w -X main.version=$VERSION" -o "$OUT/v6core" ./cmd/v6core && go build -trimpath -ldflags='-s -w' -o "$OUT/v6service" ./cmd/v6service)
cp "$PROJ"/macos/*.sh "$PROJ/macos/anchor-v6only" "$OUT/"
(cd "$PROJ/desktop" && npm run tauri -- build --bundles app)
STAGING="$PROJ/build/dmg"
mkdir -p "$STAGING" "$PROJ/build/release"
rm -rf "$STAGING/V6Only.app"
cp -R "$PROJ/desktop/src-tauri/target/release/bundle/macos/V6Only.app" "$STAGING/"
ln -sfn /Applications "$STAGING/Applications"
hdiutil create -ov -volname V6Only -srcfolder "$STAGING" -format UDZO "$PROJ/build/release/V6Only-$VERSION-macOS-arm64.dmg"
