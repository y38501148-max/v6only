#!/bin/bash
set -euo pipefail
PROJ=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(cat "$PROJ/VERSION")
OUT="$PROJ/build/release/v6only-macos-$VERSION"
mkdir -p "$OUT/macos"
for arch in arm64 amd64; do
    (cd "$PROJ/core" && GOOS=darwin GOARCH="$arch" CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=$VERSION" -o "$PROJ/build/v6core-$arch" ./cmd/v6core)
done
lipo -create "$PROJ/build/v6core-arm64" "$PROJ/build/v6core-amd64" -output "$OUT/macos/v6core"
codesign -s - "$OUT/macos/v6core"
cp "$PROJ"/macos/*.sh "$PROJ/macos/anchor-v6only" "$OUT/macos/"
cp "$PROJ/README.md" "$PROJ/LICENSE" "$PROJ/VERSION" "$OUT/"
python3 "$PROJ/scripts/collect-licenses.py" "$OUT/third-party"
git -C "$PROJ" rev-parse HEAD > "$OUT/COMMIT"
(cd "$PROJ/build/release" && zip -qr "v6only-macos-$VERSION.zip" "v6only-macos-$VERSION")
