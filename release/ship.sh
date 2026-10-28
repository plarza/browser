#!/bin/bash
# Notarises a Developer-ID-signed Azote.app and lays out a release:
# build/release/Azote-<version>.dmg. Updates are manual: install the new DMG.
#
# Needs, once: xcrun notarytool store-credentials azote
set -euo pipefail
APP="$1"
VERSION="$2"
OUT="build/release"
PROFILE="${AZOTE_NOTARY_PROFILE:-azote}"
rm -rf "$OUT" && mkdir -p "$OUT"

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT/notarize.zip"

hdiutil create -quiet -volname Azote -srcfolder "$APP" -ov -format ULFO "$OUT/Azote-$VERSION.dmg"
codesign --sign "${AZOTE_SIGN_IDENTITY:?}" --timestamp "$OUT/Azote-$VERSION.dmg"
xcrun notarytool submit "$OUT/Azote-$VERSION.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Azote-$VERSION.dmg"
echo "$OUT"
