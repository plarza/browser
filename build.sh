#!/bin/bash
# Assembles Azote.app around the SwiftPM binary, with Azote's own WebKit
# inside it. The patched engine is mandatory for every build.
#
#   ./build.sh               release build, ad-hoc signed, into build/Azote.app
#   ./build.sh debug         the same, debug
#   ./build.sh release ship  + Developer ID signature, notarised DMG
#
# The engine is built by engine/build.sh; a missing or unpatched engine
# is a build error, before any existing app bundle is replaced.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
STEP="${2:-app}"
APP="build/Azote.app"
VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
ENGINE="${AZOTE_ENGINE:-$HOME/repos/azote-engine/webkit/WebKitBuild/Release}"

for name in JavaScriptCore WebCore WebKit; do
  [ -f "$ENGINE/$name.framework/Versions/A/$name" ] || {
    echo "Azote requires its patched engine: $ENGINE/$name.framework is missing. Run engine/build.sh or set AZOTE_ENGINE." >&2
    exit 1
  }
done
LC_ALL=C grep -a -q '_setAzoteFingerprintSeed:' "$ENGINE/WebKit.framework/Versions/A/WebKit" || {
  echo "Azote refuses an unpatched WebKit: $ENGINE" >&2
  exit 1
}

swift build -c "$CONFIG" --product Azote
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Azote"
DYLD_FRAMEWORK_PATH="$ENGINE" DYLD_LIBRARY_PATH="$ENGINE" "$BIN" --check-engine

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/AzoteApp"
clang -O2 -mmacosx-version-min=26.0 -o "$APP/Contents/MacOS/Azote" engine/launcher.c
sed -e "s/VERSION/$VERSION/" -e "s/BUILD/$BUILD/" release/Info.plist > "$APP/Contents/Info.plist"
# The icon: release/Azote.icon (Icon Composer's format, a plain glyph on a
# fill), which actool renders into the Liquid Glass icon and an .icns.
# actool resolves relative paths against a directory of its own: absolute ones.
xcrun actool "$PWD/release/Azote.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon Azote --platform macosx \
  --minimum-deployment-target 26.0 --output-partial-info-plist "$PWD/$APP/Contents/icon.plist" >/dev/null
rm "$APP/Contents/icon.plist"
# The picture blank tabs show until someone chooses their own.
cp release/morning.webp "$APP/Contents/Resources/"
cp release/Azote.icon/Assets/A.svg "$APP/Contents/Resources/A.svg"
cp -R release/engines "$APP/Contents/Resources/Engines"

# A stable certificate, so macOS remembers what it was allowed (the
# microphone, the camera) across builds; an ad-hoc signature is a new app to
# it every time.
IDENTITY="${AZOTE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
RUNTIME=()
if [ "$STEP" = "ship" ]; then
  IDENTITY="${AZOTE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
  [ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in the keychain" >&2; exit 1; }
  export AZOTE_SIGN_IDENTITY="$IDENTITY"
  RUNTIME=(--options runtime --timestamp)
fi

./engine/embed.sh "$ENGINE" "$APP" "$IDENTITY"

codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --entitlements release/Azote.entitlements --sign "$IDENTITY" "$APP/Contents/MacOS/AzoteApp"
codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --sign "$IDENTITY" "$APP/Contents/MacOS/Azote"
codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --entitlements release/Azote.entitlements --sign "$IDENTITY" "$APP"

"$APP/Contents/MacOS/Azote" --check-engine

if [ "$STEP" = "ship" ]; then
  ./release/ship.sh "$APP" "$VERSION"
fi
echo "$APP"
