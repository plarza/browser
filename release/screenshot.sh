#!/bin/bash
# README's screenshot: Browser with these tabs open and the new tab page in
# front, drawn by the app itself into release/screenshot.webp (quality 80).
# Run it again whenever the window changes; the settings below say what it
# shows.
#
# The pages load from the internet into a throwaway data folder: nothing from
# your own Browser (history, cookies, tabs) is used or touched.
set -euo pipefail
cd "$(dirname "$0")/.."

TABS=(
    https://aza.network/
    https://github.com/plarza
    https://git.aza.network/
    https://en.wikipedia.org/wiki/Socratic_dialogue
    https://jasonfantl.com/posts/What-is-Entropy/
    https://en.wikipedia.org/wiki/Kolmogorov_complexity
    https://news.ycombinator.com/
    https://www.lesswrong.com/posts/epZLSoNvjW53tqNj9/evolutionary-psychology
)

# Shown as a Persist tab.
PERSIST=https://github.com/plarza
# light or dark.
APPEARANCE=light
# yes: the new tab picture behind the sidebar too.
FILL=yes

OUT="$PWD/release/screenshot.webp"
STORE="$(mktemp -d)"
PNG="$STORE/screenshot.png"
trap 'rm -rf "$STORE"' EXIT

command -v cwebp >/dev/null || brew install webp
./build.sh debug >/dev/null
build/Browser.app/Contents/MacOS/Browser \
  -browserStore "$STORE" \
  -browserScreenshot "$PNG" \
  -browserScreenshotTabs "$(IFS=,; echo "${TABS[*]}")" \
  -browserScreenshotPersist "$PERSIST" \
  -browserScreenshotAppearance "$APPEARANCE" \
  -browserScreenshotFill "$([ "$FILL" = yes ] && echo YES || echo NO)" \
  -sidebarWidth 336
cwebp -quiet -q 80 "$PNG" -o "$OUT"
echo "$OUT"
