#!/bin/bash
set -euo pipefail
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$PROJ/core" && go build -trimpath -ldflags='-s -w' -o "$PROJ/macos/v6core" ./cmd/v6core)
codesign -s - "$PROJ/macos/v6core"
