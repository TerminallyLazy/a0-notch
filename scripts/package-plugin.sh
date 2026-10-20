#!/usr/bin/env bash
# Build a clean standalone ZIP from the reviewed file-level manifest.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
command -v zip >/dev/null || { echo 'zip is required; nothing installed.' >&2; exit 2; }
bash scripts/check-source-manifest.sh
mkdir -p build
STAGE=$(mktemp -d "$ROOT/build/plugin-package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/a0_notch"
grep '^plugin/' scripts/public-source-files.txt | sed 's|^plugin/||' > "$STAGE/files"
COPYFILE_DISABLE=1 tar -cf "$STAGE/plugin.tar" -C plugin -T "$STAGE/files"
tar -xf "$STAGE/plugin.tar" -C "$STAGE/a0_notch"
(cd "$STAGE" && zip -q -X -r plugin.zip a0_notch)
mv "$STAGE/plugin.zip" build/a0_notch-plugin.zip
unzip -tq build/a0_notch-plugin.zip
echo 'PLUGIN_PACKAGE_PASS: build/a0_notch-plugin.zip'
