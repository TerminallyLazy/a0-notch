#!/usr/bin/env bash
# Standalone source checks only: never invokes SwiftPM/Xcode or writes shared .build/build.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ $(uname -s) != Darwin ]]; then
    echo "SKIP: sound/hotkey executable checks require macOS AppKit, Carbon and AVFoundation." >&2
    exit 77
fi
if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "SKIP: Swift compiler unavailable; no dependencies will be installed." >&2
    exit 77
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/a0-sound-hotkey-checks.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export CLANG_MODULE_CACHE_PATH="$WORK/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK/swift-cache"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" -sdk "$SDK" -module-cache-path "$WORK/swift-cache" \
    -framework AppKit -framework AVFoundation -framework Carbon \
    "$ROOT/app/Sources/A0Notch/NotchSoundPlayer.swift" \
    "$ROOT/app/Sources/A0Notch/GlobalHotkeys.swift" \
    "$ROOT/app/Tests/SoundHotkeyStandalone/SoundHotkeyModuleChecks.swift" \
    -o "$WORK/sound-hotkey-checks"
"$WORK/sound-hotkey-checks" "$@"
