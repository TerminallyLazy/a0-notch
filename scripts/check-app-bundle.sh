#!/usr/bin/env bash
# Validate launch-critical metadata, not merely plist syntax or code signing.
set -euo pipefail
APP=${1:?Usage: check-app-bundle.sh path/to/A0Notch.app}
PLIST="$APP/Contents/Info.plist"
plutil -lint "$PLIST"
if plutil -convert xml1 -o - "$PLIST" | grep -Eq '\$\(|\$\{'; then
  echo "Unresolved build setting in $PLIST" >&2; exit 1
fi
expect() {
  local actual
  actual=$(plutil -extract "$1" raw -o - "$PLIST")
  [[ "$actual" == "$2" ]] || { echo "$1: expected '$2', got '$actual'" >&2; exit 1; }
}
expect CFBundleExecutable A0Notch
expect CFBundleIdentifier community.agentzero.notch
expect CFBundleName A0Notch
expect CFBundleIconFile A0Notch.icns
[[ -s "$APP/Contents/Resources/A0Notch.icns" ]]
BRANDING="$APP/Contents/Resources/Branding"
for asset in AgentZeroSymbol.png AgentZeroWordmark.png AgentZeroIcon.png rubik-variable.ttf roboto-mono-variable.ttf rubik-OFL.txt roboto-mono-OFL.txt AgentZero-MIT.txt SHA256SUMS; do
  [[ -s "$BRANDING/$asset" ]] || { echo "Missing branding asset: $asset" >&2; exit 1; }
done
(cd "$BRANDING" && shasum -a 256 -c SHA256SUMS)
expect CFBundlePackageType APPL
expect CFBundleShortVersionString 1.0
expect CFBundleVersion 1
expect LSMinimumSystemVersion 14.0
expect LSUIElement true
[[ $(plutil -type LSUIElement "$PLIST") == boolean ]]
[[ -x "$APP/Contents/MacOS/A0Notch" ]]
file "$APP/Contents/MacOS/A0Notch" | grep -q 'Mach-O'
codesign --verify --strict "$APP"
echo "BUNDLE_CHECK_PASS: $APP"
