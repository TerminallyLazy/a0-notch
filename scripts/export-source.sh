#!/usr/bin/env bash
# Export only individually approved files; never stage the working tree wholesale.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
bash scripts/check-source-manifest.sh
mkdir -p build
STAGE=$(mktemp -d "$ROOT/build/source-export.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/a0-notch"
COPYFILE_DISABLE=1 tar -cf "$STAGE/source.tar" -T scripts/public-source-files.txt
tar -xf "$STAGE/source.tar" -C "$STAGE/a0-notch"
(cd "$STAGE/a0-notch" && find . -type f | sed 's|^./||' | LC_ALL=C sort) > "$STAGE/files"
cmp scripts/public-source-files.txt "$STAGE/files"
cp "$STAGE/files" build/public-source-manifest.txt
COPYFILE_DISABLE=1 tar -czf "$STAGE/a0-notch-source.tar.gz" -C "$STAGE" a0-notch
mv "$STAGE/a0-notch-source.tar.gz" build/a0-notch-source.tar.gz
echo 'SOURCE_EXPORT_PASS: build/a0-notch-source.tar.gz'
