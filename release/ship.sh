#!/bin/bash
# Notarises a Developer-ID-signed Core.app and lays out a release:
# build/release/Core-<version>.dmg. Updates are manual: install the new DMG.
#
# Needs, once: xcrun notarytool store-credentials core
set -euo pipefail
APP="$1"
VERSION="$2"
OUT="build/release"
PROFILE="${CORE_NOTARY_PROFILE:-core}"
rm -rf "$OUT" && mkdir -p "$OUT"

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT/notarize.zip"

hdiutil create -quiet -volname Core -srcfolder "$APP" -ov -format ULFO "$OUT/Core-$VERSION.dmg"
codesign --sign "${CORE_SIGN_IDENTITY:?}" --timestamp "$OUT/Core-$VERSION.dmg"
xcrun notarytool submit "$OUT/Core-$VERSION.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Core-$VERSION.dmg"
echo "$OUT"
