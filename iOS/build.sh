#!/bin/bash
# Builds the iPhone app on the system's WebKit (see the README's iOS section).
#
#   iOS/build.sh            debug build for the simulator, into build/ios
#   iOS/build.sh device     debug build signed for a connected iPhone, installed on it
#   iOS/build.sh testflight release build uploaded to TestFlight (internal testers only)
#
# testflight signs and uploads with an App Store Connect team key:
# ASC_KEY_ID and ASC_ISSUER_ID, the key at
# ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate -q
if [ "${1:-}" = testflight ]; then
  KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
  AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  OUT=../build/ios/testflight
  rm -rf "$OUT" ../build/ios/Browser.xcarchive
  # Each upload needs a higher build number than the last.
  xcodebuild -project Browser.xcodeproj -scheme Browser -configuration Release -destination 'generic/platform=iOS' \
    -archivePath ../build/ios/Browser.xcarchive "${AUTH[@]}" CURRENT_PROJECT_VERSION="$(date -u +%Y%m%d%H%M)" -quiet archive
  cat > ../build/ios/ExportTestFlight.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>export</string>
<key>testFlightInternalTestingOnly</key><true/>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath ../build/ios/Browser.xcarchive -exportPath "$OUT" \
    -exportOptionsPlist ../build/ios/ExportTestFlight.plist "${AUTH[@]}" -quiet
  xcrun altool --upload-app -f "$OUT/Browser.ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
elif [ "${1:-}" = device ]; then
  xcodebuild -project Browser.xcodeproj -scheme Browser -destination 'generic/platform=iOS' \
    -derivedDataPath ../build/ios -allowProvisioningUpdates -quiet build
  APP=../build/ios/Build/Products/Debug-iphoneos/Browser.app
  DEVICE="$(xcrun devicectl list devices --hide-headers --hide-default-columns --columns Identifier 2>/dev/null | head -1)"
  xcrun devicectl device install app --device "$DEVICE" "$APP"
else
  xcodebuild -project Browser.xcodeproj -scheme Browser -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath ../build/ios -quiet build
fi
