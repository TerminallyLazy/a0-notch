#!/usr/bin/env bash
# Launch Services regression: a direct Mach-O smoke test cannot catch a bad plist.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-"$ROOT/build/A0Notch.app"}
APP=$(cd "$APP" && pwd)
PRESENTATION=${2:-notch}
case "$PRESENTATION" in notch|capsule|slim) ;; *) echo "Invalid presentation" >&2; exit 2 ;; esac
"$ROOT/scripts/check-app-bundle.sh" "$APP"
LOGDIR=$(mktemp -d "$ROOT/build/launch-check.XXXXXX")
TOKEN="a0-packaging-$$-$(date +%s)"
OPEN_PID=
app_pids() { pgrep -f "A0Notch .*--$TOKEN" || true; }
cleanup() {
  local pid
  for pid in $(app_pids); do kill "$pid" 2>/dev/null || true; done
  if [[ -n "$OPEN_PID" ]]; then kill "$OPEN_PID" 2>/dev/null || true; wait "$OPEN_PID" 2>/dev/null || true; fi
  rm -rf "$LOGDIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# -n prevents accidentally testing/reusing an already-running instance.
# -W alone does not propagate app failure: require its explicit smoke pass too.
open -n -g -W --stdout "$LOGDIR/stdout" --stderr "$LOGDIR/stderr" "$APP" \
  --args --open "--presentation=$PRESENTATION" --smoke-test "--$TOKEN" >"$LOGDIR/open" 2>&1 &
OPEN_PID=$!
for ((i=0; i<150; i++)); do
  if ! kill -0 "$OPEN_PID" 2>/dev/null; then break; fi
  sleep 0.1
done
if kill -0 "$OPEN_PID" 2>/dev/null; then
  cat "$LOGDIR"/*; echo 'Launch Services smoke check timed out' >&2; exit 1
fi
STATUS=0
wait "$OPEN_PID" || STATUS=$?
OPEN_PID=
cat "$LOGDIR"/*
echo "OPEN_EXIT=$STATUS"
[[ "$STATUS" == 0 ]]
grep -qx 'SMOKE_TEST_PASS' "$LOGDIR/stdout"
! grep -q 'SMOKE_TEST_FAIL' "$LOGDIR/stdout"
grep -Eq "\"presentation\"[[:space:]]*:[[:space:]]*\"$PRESENTATION\"" "$LOGDIR/stdout"
[[ -z $(app_pids) ]]
echo "LAUNCH_CHECK_PASS: $APP"
