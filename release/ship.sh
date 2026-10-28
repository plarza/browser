#!/bin/bash
# Notarises a Developer-ID-signed Browser.app and lays out a release:
# build/release/Browser-<version>.dmg. Updates are manual: install the new DMG.
#
# Needs, once: xcrun notarytool store-credentials browser
set -euo pipefail
APP="$1"
VERSION="$2"
OUT="build/release"
PROFILE="${BROWSER_NOTARY_PROFILE:-browser}"
rm -rf "$OUT" && mkdir -p "$OUT"

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT/notarize.zip"

hdiutil create -quiet -volname Browser -srcfolder "$APP" -ov -format ULFO "$OUT/Browser-$VERSION.dmg"
codesign --sign "${BROWSER_SIGN_IDENTITY:?}" --timestamp "$OUT/Browser-$VERSION.dmg"
xcrun notarytool submit "$OUT/Browser-$VERSION.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Browser-$VERSION.dmg"
echo "$OUT"
