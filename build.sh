#!/bin/bash
# Assembles Browser.app around the SwiftPM binary, with Browser's own WebKit
# inside it. The patched engine is mandatory for every build.
#
#   ./build.sh               release build, ad-hoc signed, into build/Browser.app
#   ./build.sh debug         the same, debug
#   ./build.sh release ship  + Developer ID signature, notarised DMG
#
# The engine is built by engine/build.sh; a missing or unpatched engine
# is a build error, before any existing app bundle is replaced.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
STEP="${2:-app}"
APP="build/Browser.app"
VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
ENGINE="${BROWSER_ENGINE:-$HOME/repos/browser-engine/webkit/WebKitBuild/Release}"

for name in JavaScriptCore WebCore WebKit; do
  [ -f "$ENGINE/$name.framework/Versions/A/$name" ] || {
    echo "Browser requires its patched engine: $ENGINE/$name.framework is missing. Run engine/build.sh or set BROWSER_ENGINE." >&2
    exit 1
  }
done
LC_ALL=C grep -a -q '_setBrowserFingerprintSeed:' "$ENGINE/WebKit.framework/Versions/A/WebKit" || {
  echo "Browser refuses an unpatched WebKit: $ENGINE" >&2
  exit 1
}

swift build -c "$CONFIG" --product Browser
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Browser"
DYLD_FRAMEWORK_PATH="$ENGINE" DYLD_LIBRARY_PATH="$ENGINE" "$BIN" --check-engine

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/BrowserApp"
clang -O2 -mmacosx-version-min=26.0 -o "$APP/Contents/MacOS/Browser" engine/launcher.c
sed -e "s/VERSION/$VERSION/" -e "s/BUILD/$BUILD/" release/Info.plist > "$APP/Contents/Info.plist"
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

./engine/embed.sh "$ENGINE" "$APP" "$IDENTITY"

codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --entitlements release/Browser.entitlements --sign "$IDENTITY" "$APP/Contents/MacOS/BrowserApp"
codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --sign "$IDENTITY" "$APP/Contents/MacOS/Browser"
codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --entitlements release/Browser.entitlements --sign "$IDENTITY" "$APP"

"$APP/Contents/MacOS/Browser" --check-engine

if [ "$STEP" = "ship" ]; then
  ./release/ship.sh "$APP" "$VERSION"
fi
echo "$APP"
