#!/usr/bin/env bash
# All six production modules; no app manifest/build or Zero stubs.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ $(uname -s) != Darwin ]] || ! command -v xcrun >/dev/null 2>&1; then
    echo 'SKIP: real Zero integration requires macOS and an existing Swift compiler.' >&2
    exit 77
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/a0-zero-integration.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# Preserve original path/control points/material routines exactly, in addition to pixels.
for routine in drawShell shellPath; do
    awk -v name="$routine" '/^    private func / { if (index($0, "func " name "(")) active=1 } active { print } active && /^    }/ { exit }' \
        "$ROOT/app/Sources/A0Notch/ZeroView.swift" > "$WORK/live-$routine"
    awk -v name="$routine" '/^    private func / { if (index($0, "func " name "(")) active=1 } active { print } active && /^    }/ { exit }' \
        "$ROOT/app/Tests/ZeroIntegrationStandalone/OriginalZeroShell.swift" > "$WORK/original-$routine"
    test -s "$WORK/live-$routine"
    cmp "$WORK/live-$routine" "$WORK/original-$routine"
done
echo 'PASS: original Zero shell path and material source preserved exactly.'
export CLANG_MODULE_CACHE_PATH="$WORK/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK/swift-cache"
SOURCES=()
for name in ZeroView ZeroCharacter ZeroWardrobe DesktopZeroController NotchSoundPlayer GlobalHotkeys; do
    SOURCES+=("$ROOT/app/Sources/A0Notch/$name.swift")
done
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$WORK/swift-cache" -framework AppKit -framework SwiftUI \
    -framework AVFoundation -framework Carbon "${SOURCES[@]}" \
    "$ROOT/app/Tests/ZeroIntegrationStandalone/ZeroPaletteSupport.swift" \
    "$ROOT/app/Tests/ZeroIntegrationStandalone/OriginalZeroShell.swift" \
    "$ROOT/app/Tests/ZeroIntegrationStandalone/ZeroIntegrationChecks.swift" \
    -o "$WORK/zero-integration-checks"
echo 'PASS: Swift 6 complete-concurrency compile of all six real modules (palette-only support).'
"$WORK/zero-integration-checks" "$@"
