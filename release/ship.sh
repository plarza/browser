#!/bin/bash
# Notarises a Developer-ID-signed Core.app and lays out a release:
# build/release/Core.dmg (to install), Core.zip (for the updater) and
# latest.json (the updater's feed entry).
#
# Needs, once: xcrun notarytool store-credentials core
set -euo pipefail
APP="$1"
VERSION="$2"
OUT="build/release"
PROFILE="${CORE_NOTARY_PROFILE:-core}"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
rm -rf "$OUT" && mkdir -p "$OUT"

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT/notarize.zip"

ditto -c -k --keepParent "$APP" "$OUT/Core.zip"
hdiutil create -quiet -volname Core -srcfolder "$APP" -ov -format ULFO "$OUT/Core.dmg"
codesign --sign "${CORE_SIGN_IDENTITY:?}" --timestamp "$OUT/Core.dmg"
xcrun notarytool submit "$OUT/Core.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Core.dmg"

SHA="$(shasum -a 256 "$OUT/Core.zip" | cut -d' ' -f1)"
URL="${CORE_DOWNLOAD_URL:?the https folder releases are served from}/Core-$VERSION.zip"
printf '{"version": "%s", "build": %s, "url": "%s", "sha256": "%s"}\n' "$VERSION" "$BUILD" "$URL" "$SHA" > "$OUT/latest.json"
mv "$OUT/Core.zip" "$OUT/Core-$VERSION.zip"
echo "$OUT"
