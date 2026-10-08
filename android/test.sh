#!/bin/bash
set -euo pipefail
PROJ="$(cd "$(dirname "$0")" && pwd)"
OUT="$PROJ/build/tests"
mkdir -p "$OUT"
javac --release 17 -d "$OUT" \
  "$PROJ/app/src/main/java/edu/buaa/v6only/CampusPolicy.java" \
  "$PROJ/tests/edu/buaa/v6only/CampusPolicyTest.java"
java -ea -cp "$OUT" edu.buaa.v6only.CampusPolicyTest
javac --release 17 -d "$OUT" "$PROJ/app/src/main/java/edu/buaa/v6only/BackgroundPolicy.java" "$PROJ/tests/edu/buaa/v6only/BackgroundPolicyTest.java"
java -ea -cp "$OUT" edu.buaa.v6only.BackgroundPolicyTest
