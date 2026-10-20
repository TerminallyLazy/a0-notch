#!/usr/bin/env bash
# Requires XcodeGen and a logged-in macOS GUI session; installs nothing.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
if ! command -v xcodegen >/dev/null && [[ ! -x /opt/homebrew/bin/xcodegen ]]; then
  echo 'XcodeGen required to verify both build paths (no fallback in this test).' >&2
  exit 2
fi
LOGS="$ROOT/build/logs/packaging-regression"
mkdir -p "$LOGS"
PLIST_HASH=$(shasum -a 256 app/Info.plist)
step() {
  local label=$1 status=0
  shift
  "$@" >"$LOGS/$label.log" 2>&1 || status=$?
  echo "$label EXIT=$status"
  if [[ "$status" != 0 ]]; then cat "$LOGS/$label.log"; exit "$status"; fi
  [[ "$(shasum -a 256 app/Info.plist)" == "$PLIST_HASH" ]] || {
    echo "Source plist mutated during $label" >&2; exit 1;
  }
}
for order in xcode-first swiftpm-first; do
  if [[ "$order" == xcode-first ]]; then builders=(xcode swiftpm); else builders=(swiftpm xcode); fi
  for builder in "${builders[@]}"; do
    if [[ "$builder" == xcode ]]; then
      step "$order-$builder-build" ./scripts/build-xcode.sh
      app=build/DerivedData/Build/Products/Debug/A0Notch.app
    else
      step "$order-$builder-build" ./scripts/package-app.sh debug
      app=build/A0Notch.app
    fi
    step "$order-$builder-launch" ./scripts/test-app-launch.sh "$app"
  done
done
echo 'PACKAGING_REGRESSION_PASS: both build orders; source plist unchanged; four Launch Services launches'
