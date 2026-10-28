#!/bin/bash
# Assembles Core.app around the SwiftPM binary, with Core's own WebKit
# inside it when engine/ has been built.
#
#   ./build.sh               release build, ad-hoc signed, into build/Core.app
#   ./build.sh debug         the same, debug
#   ./build.sh release ship  + Developer ID signature, notarised DMG
#
# The engine is built by engine/build.sh; without it the app runs on the
# system WebKit and says so in its sidebar.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
STEP="${2:-app}"
APP="build/Core.app"
VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
ENGINE="${CORE_ENGINE:-$HOME/repos/core-engine/webkit/WebKitBuild/Release}"

swift build -c "$CONFIG" --product Core
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Core"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/CoreApp"
clang -O2 -mmacosx-version-min=26.0 -o "$APP/Contents/MacOS/Core" engine/launcher.c
sed -e "s/VERSION/$VERSION/" -e "s/BUILD/$BUILD/" release/Info.plist > "$APP/Contents/Info.plist"
[ -f release/AppIcon.icns ] && cp release/AppIcon.icns "$APP/Contents/Resources/"

IDENTITY="-"
RUNTIME=()
if [ "$STEP" = "ship" ]; then
  IDENTITY="${CORE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
  [ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in the keychain" >&2; exit 1; }
  export CORE_SIGN_IDENTITY="$IDENTITY"
  RUNTIME=(--options runtime --timestamp)
fi

if [ -d "$ENGINE/WebKit.framework" ]; then
  ./engine/embed.sh "$ENGINE" "$APP" "$IDENTITY"
fi

codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --entitlements release/Core.entitlements --sign "$IDENTITY" "$APP/Contents/MacOS/CoreApp"
codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --sign "$IDENTITY" "$APP/Contents/MacOS/Core"
codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --entitlements release/Core.entitlements --sign "$IDENTITY" "$APP"

if [ "$STEP" = "ship" ]; then
  ./release/ship.sh "$APP" "$VERSION"
fi
echo "$APP"
