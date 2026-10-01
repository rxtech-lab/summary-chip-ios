#!/bin/bash
set -euo pipefail

: "${SPARKLE_KEY:?SPARKLE_KEY is required}"
: "${VERSION:?VERSION is required}"
: "${BUILD_NUMBER:?BUILD_NUMBER is required}"
if [[ ! "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: only stable semver releases can publish the update feed" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPARKLE_BIN="${SPARKLE_BIN:-output/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin}"
APP_PATH="${APP_PATH:-output/output.xcarchive/Products/Applications/summary-chip.app}"
ARCHIVE="${ARCHIVE:-SummaryChip.dmg}"
PAGES_DIR="${PAGES_DIR:-output/pages}"
DOWNLOAD_PREFIX="https://github.com/rxtech-lab/summary-chip-ios/releases/download/$VERSION/"
mkdir -p "$PAGES_DIR"

# Work in an isolated directory so CI leftovers cannot leak into the feed.
WORK_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/summary-appcast.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
cp "$ARCHIVE" "$WORK_DIR/SummaryChip.dmg"
printf '%s' "${RELEASE_NOTE:-}" > "$WORK_DIR/notes.txt"
python3 - "$WORK_DIR" <<'PY'
import html, pathlib, sys
p = pathlib.Path(sys.argv[1])
notes = html.escape((p / "notes.txt").read_text())
(p / "SummaryChip.html").write_text('<!DOCTYPE html><html lang="en"><meta charset="utf-8"><title>Chippy release notes</title><body><pre style="white-space:pre-wrap">' + notes + '</pre></body></html>')
PY

# Pass the signing key over stdin; never put it in argv or in published artifacts.
printf '%s' "$SPARKLE_KEY" | "$SPARKLE_BIN/generate_appcast" "$WORK_DIR" \
  --ed-key-file - --maximum-deltas 0 \
  --link "https://github.com/rxtech-lab/summary-chip-ios/releases/tag/$VERSION" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --release-notes-url-prefix "https://update.summary.rxlab.app/"

python3 "$SCRIPT_DIR/validate-appcast.py" "$WORK_DIR/appcast.xml" "$ARCHIVE" \
  "$APP_PATH/Contents/Info.plist" "$DOWNLOAD_PREFIX"
cp "$WORK_DIR/appcast.xml" "$WORK_DIR/SummaryChip.html" "$PAGES_DIR/"
printf '%s\n' 'update.summary.rxlab.app' > "$PAGES_DIR/CNAME"
touch "$PAGES_DIR/.nojekyll"
