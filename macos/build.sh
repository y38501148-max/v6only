#!/bin/bash
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(cat "$PROJ/VERSION")
(cd "$PROJ/core" && go build -trimpath -ldflags="-s -w -X main.version=$VERSION" -o "$PROJ/macos/v6core" ./cmd/v6core)
codesign -s - "$PROJ/macos/v6core"
