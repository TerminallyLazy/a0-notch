#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[[ $(uname -s) == Darwin ]] || exit 77
WORK=$(mktemp -d "${TMPDIR:-/tmp}/notch-dictation.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
CORE=("$ROOT"/app/Sources/NotchCore/*.swift)
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -emit-library -emit-module -module-name NotchCore "${CORE[@]}" -o "$WORK/libNotchCore.dylib" -emit-module-path "$WORK/NotchCore.swiftmodule"
SOURCES=()
for file in "$ROOT"/app/Sources/A0Notch/*.swift; do
  [[ $(basename "$file") == A0NotchApp.swift ]] || SOURCES+=("$file")
done
# Includes the real Apple adapter; only the injected FakeSpeech is ever started.
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -I "$WORK" -L "$WORK" -lNotchCore -Xlinker -rpath -Xlinker "$WORK" "${SOURCES[@]}" "$ROOT/app/Tests/DictationStandalone/DictationChecks.swift" -o "$WORK/checks"
"$WORK/checks" "$ROOT"
