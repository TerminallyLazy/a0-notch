#!/usr/bin/env bash
# Simplified dependency-free adaptation of guide-macos-spm-packaging's MIT template.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
CONF=${1:-debug}
case "$CONF" in debug|release) ;; *) echo 'Usage: package-app.sh [debug|release]' >&2; exit 2;; esac
mkdir -p build .build/clang-cache .build/swift-cache
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-cache"
swift build --disable-sandbox --cache-path "$ROOT/.build/cache" -c "$CONF" --product A0Notch
BIN=$(swift build --disable-sandbox --cache-path "$ROOT/.build/cache" -c "$CONF" --show-bin-path)
DEST="$ROOT/build/A0Notch.app"
STAGE=$(mktemp -d "$ROOT/build/app-package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/A0Notch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Fresh bundle and Mach-O inode: neither stale resources nor cached vnode
# signatures from a previously executed app can enter this package.
cp "$BIN/A0Notch" "$APP/Contents/MacOS/A0Notch"
cp app/Info.plist "$APP/Contents/Info.plist"
# Keep resources self-contained, independent of SwiftPM's build-tree fallback.
RESOURCE_BUNDLE="$BIN/a0_notch_A0Notch.bundle"
if [[ -d "$RESOURCE_BUNDLE/Contents/Resources/Branding" ]]; then
  BRANDING="$RESOURCE_BUNDLE/Contents/Resources/Branding"
else
  BRANDING="$RESOURCE_BUNDLE/Branding"
fi
[[ -d "$BRANDING" ]] || { echo "SwiftPM branding resources missing: $RESOURCE_BUNDLE" >&2; exit 1; }
ditto "$BRANDING" "$APP/Contents/Resources/Branding"
cp app/A0Notch.icns "$APP/Contents/Resources/A0Notch.icns"
chmod +x "$APP/Contents/MacOS/A0Notch"
xattr -cr "$APP"
codesign --force --options runtime --entitlements app/A0Notch.entitlements --sign - "$APP"
codesign --verify --strict "$APP"
"$ROOT/scripts/check-app-bundle.sh" "$APP"
# Preserve the previous package until the new one has passed all checks.
if [[ -e "$DEST" ]]; then mv "$DEST" "$STAGE/previous.app"; fi
if ! mv "$APP" "$DEST"; then
  [[ ! -e "$STAGE/previous.app" ]] || mv "$STAGE/previous.app" "$DEST"
  exit 1
fi
echo "Packaged: $DEST"
