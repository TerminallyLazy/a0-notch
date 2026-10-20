#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
XCODEGEN=$(command -v xcodegen || true)
if [[ -z "$XCODEGEN" && -x /opt/homebrew/bin/xcodegen ]]; then XCODEGEN=/opt/homebrew/bin/xcodegen; fi
if [[ -z "$XCODEGEN" ]]; then
  echo 'XcodeGen unavailable; using dependency-free SwiftPM packaging.'
  exec "$ROOT/scripts/package-app.sh" debug
fi
PLIST_HASH=$(shasum -a 256 app/Info.plist)
"$XCODEGEN" generate --spec project.yml
[[ "$(shasum -a 256 app/Info.plist)" == "$PLIST_HASH" ]] || { echo "XcodeGen changed the source plist" >&2; exit 1; }
xcodebuild -project A0Notch.xcodeproj -scheme A0Notch -configuration Debug -destination 'platform=macOS' -derivedDataPath "$ROOT/build/DerivedData" build
"$ROOT/scripts/check-app-bundle.sh" "$ROOT/build/DerivedData/Build/Products/Debug/A0Notch.app"
