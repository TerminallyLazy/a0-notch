#!/usr/bin/env bash
# Independent controller check with explicit test contract stubs; no shared app build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ $(uname -s) != Darwin ]] || ! command -v xcrun >/dev/null 2>&1; then
    echo "SKIP: DesktopZeroController checks require macOS and an existing Swift compiler." >&2
    exit 77
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/a0-desktop-zero-checks.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export CLANG_MODULE_CACHE_PATH="$WORK/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK/swift-cache"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" -sdk "$SDK" -module-cache-path "$WORK/swift-cache" \
    -framework AppKit -framework SwiftUI \
    "$ROOT/app/Sources/A0Notch/DesktopZeroController.swift" \
    "$ROOT/app/Tests/DesktopZeroStandalone/DesktopZeroContractChecks.swift" \
    -o "$WORK/desktop-zero-checks"
"$WORK/desktop-zero-checks" "$@"
