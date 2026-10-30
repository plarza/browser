#!/bin/bash
# Builds Browser.app using the system WebKit.
#
#   ./build.sh               release build into build/Browser.app
#   ./build.sh debug         debug build with a separate app identity
#   ./build.sh release ship  Developer ID sign + notarised DMG
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
STEP="${2:-app}"
APP="build/Browser.app"
VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
swift build -c "$CONFIG" --product Browser
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Browser"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Browser"
# A debug build is its own app to macOS, so it has its own WebKit data
# (~/Library/WebKit/network.aza.browser.debug): the self-test and the
# screenshot delete data stores, and must never reach the real Browser's.
ID=network.aza.browser
[ "$CONFIG" = debug ] && ID=network.aza.browser.debug
sed -e "s/VERSION/$VERSION/" -e "s/BUILD/$BUILD/" -e "s/network\.aza\.browser/$ID/" release/Info.plist > "$APP/Contents/Info.plist"
# The icon: release/Browser.icon (Icon Composer's format, a plain glyph on a
# fill), which actool renders into the Liquid Glass icon and an .icns.
# actool resolves relative paths against a directory of its own: absolute ones.
xcrun actool "$PWD/release/Browser.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon Browser --platform macosx \
  --minimum-deployment-target 26.0 --output-partial-info-plist "$PWD/$APP/Contents/icon.plist" >/dev/null
rm "$APP/Contents/icon.plist"
# The picture blank tabs show until someone chooses their own.
cp release/morning.webp "$APP/Contents/Resources/"
cp release/Browser.icon/Assets/B.svg "$APP/Contents/Resources/B.svg"
cp -R release/engines "$APP/Contents/Resources/Engines"

# A stable certificate, so macOS remembers what it was allowed (the
# microphone, the camera) across builds; an ad-hoc signature is a new app to
# it every time.
IDENTITY="${BROWSER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
RUNTIME=()
if [ "$STEP" = "ship" ]; then
  IDENTITY="${BROWSER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
  [ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in the keychain" >&2; exit 1; }
  export BROWSER_SIGN_IDENTITY="$IDENTITY"
  RUNTIME=(--options runtime --timestamp)
fi

codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --entitlements release/Browser.entitlements --sign "$IDENTITY" "$APP"

if [ "$STEP" = "ship" ]; then
  ./release/ship.sh "$APP" "$VERSION"
fi
echo "$APP"
