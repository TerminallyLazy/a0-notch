#!/usr/bin/env bash
# Reviewed file-level allowlist. New source files require an explicit review.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
MANIFEST=scripts/public-source-files.txt
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LC_ALL=C sort -u "$MANIFEST" > "$TMP/sorted"
cmp -s "$MANIFEST" "$TMP/sorted" || { echo 'Manifest must be sorted and unique.' >&2; exit 1; }
while IFS= read -r path; do
  case "$path" in
    ''|/*|*..*|*\\*|*[[:space:]]*|.a0proj/*|build/*|.git/*|*.log|*.pem|*.key|*.p12|*.env|*/config.json)
      echo 'Unsafe manifest entry.' >&2; exit 1;;
  esac
  [[ -f "$path" && ! -L "$path" ]] || { echo "Missing/linked manifest input: $path" >&2; exit 1; }
  parent=$(dirname "$path")
  while [[ "$parent" != . ]]; do
    [[ ! -L "$parent" ]] || { echo 'Linked parent refused.' >&2; exit 1; }
    parent=$(dirname "$parent")
  done
done < "$MANIFEST"
# These are the owned export trees. Other project roots (private research,
# historical reports, runtime metadata and builds) are deliberately not inputs.
find app/Sources app/Tests plugin scripts tests \
  -type d \( -name __pycache__ -o -name .pytest_cache \) -prune -o \
  \( -type f -o -type l \) ! -name .DS_Store ! -name '._*' ! -name '*.pyc' -print \
  | LC_ALL=C sort > "$TMP/actual"
LC_ALL=C comm -23 "$TMP/actual" "$TMP/sorted" > "$TMP/unexpected"
if [[ -s "$TMP/unexpected" ]]; then
  echo 'Unexpected source files; review and update the approved manifest before exporting.' >&2
  cat "$TMP/unexpected" >&2
  exit 1
fi
echo 'SOURCE_MANIFEST_PASS'
