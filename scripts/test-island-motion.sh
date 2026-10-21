#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[[ $(uname -s) == Darwin ]] || exit 77
LOCK=/tmp/a0-notch-build.lock
mkdir "$LOCK" 2>/dev/null || { echo 'Build lock busy' >&2; exit 75; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/notch-motion.XXXXXX")
trap 'rm -rf "$WORK"; rmdir "$LOCK"' EXIT
cd "$ROOT"
LOG="$ROOT/build/logs/ui-motion"
mkdir -p "$LOG"
swift build -c release --scratch-path build/ui-motion-swift > "$LOG/release.log" 2>&1
swift test --scratch-path build/ui-motion-swift --filter 'IslandWakePolicyTests|IslandGeometryTests|IslandStateMachineTests|ExpandedPresentationModelTests' > "$LOG/core-tests.log" 2>&1
xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library -emit-library -emit-module -module-name NotchCore app/Sources/NotchCore/*.swift -o "$WORK/libNotchCore.dylib" -emit-module-path "$WORK/NotchCore.swiftmodule"
SOURCES=()
for file in app/Sources/A0Notch/*.swift; do
  [[ $(basename "$file") == A0NotchApp.swift ]] || SOURCES+=("$file")
done
for test in IslandDriverChecks IslandPerformanceChecks; do
  xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library -I "$WORK" -L "$WORK" -lNotchCore -Xlinker -rpath -Xlinker "$WORK" "${SOURCES[@]}" "app/Tests/IslandDriverStandalone/$test.swift" -o "$WORK/$test"
  if [[ "$test" == IslandPerformanceChecks ]]; then
    "$WORK/$test" "$LOG/performance" --snapshots &
    PID=$!
    if [[ ${PROFILE_COMPACT:-0} == 1 ]]; then
      sleep 20
      sample "$PID" 3 -file "$LOG/compact-sample.txt" >/dev/null 2>&1 || true
    fi
    wait "$PID"
  else
    "$WORK/$test"
  fi
done
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library app/Sources/A0Notch/ZeroView.swift app/Sources/A0Notch/ZeroCharacter.swift app/Sources/A0Notch/ZeroWardrobe.swift app/Tests/ZeroIntegrationStandalone/ZeroPaletteSupport.swift app/Tests/ZeroIntegrationStandalone/ZeroLifecycleChecks.swift -o "$WORK/ZeroLifecycleChecks"
"$WORK/ZeroLifecycleChecks"
bash scripts/test-zero-integration.sh
bash scripts/test-app-integration.sh
printf 'PASS: release build, focused core, native driver, performance, renderer lifecycle, real Zero and Store checks\n'
