#!/bin/bash
# README's screenshot: Browser with these tabs open and the new tab page in
# front, drawn by the app itself into release/screenshot.png. Run it again
# whenever the window changes.
#
#   release/screenshot.sh            light
#   release/screenshot.sh dark       dark
#   FILL=1 release/screenshot.sh     the new tab picture behind the sidebar too
#
# The pages load from the internet into a throwaway data folder: nothing from
# your own Browser (history, cookies, tabs) is used or touched.
set -euo pipefail
cd "$(dirname "$0")/.."

TABS=(
  https://artificialanalysis.ai/
  https://openrouter.ai/models
  https://github.com/WebKit/WebKit
  https://en.wikipedia.org/wiki/WebKit
  https://news.ycombinator.com/
  https://gpx.studio/
  https://www.onshape.com/en/
  https://musicbrainz.org/
)
# This one is shown as a Persist tab.
PERSIST=https://github.com/WebKit/WebKit

APPEARANCE="${1:-light}"
OUT="$PWD/release/screenshot.png"
STORE="$(mktemp -d)"
trap 'rm -rf "$STORE"' EXIT

./build.sh debug >/dev/null
build/Browser.app/Contents/MacOS/Browser \
  -browserStore "$STORE" \
  -browserScreenshot "$OUT" \
  -browserScreenshotTabs "$(IFS=,; echo "${TABS[*]}")" \
  -browserScreenshotPersist "$PERSIST" \
  -browserScreenshotAppearance "$APPEARANCE" \
  -browserScreenshotFill "$([ "${FILL:-0}" = 1 ] && echo YES || echo NO)"
echo "$OUT"
