#!/bin/bash
# Builds the iPhone app on the system's WebKit (see SPEC.md, "iPhone").
#
#   iOS/build.sh             debug build for the simulator, into build/ios
#   iOS/build.sh device      debug build installed on a connected iPhone
#   iOS/build.sh testflight  release build uploaded to TestFlight (internal testers only)
#
# testflight signs and uploads with an App Store Connect key: ASC_KEY_ID and
# ASC_ISSUER_ID, the key at ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8.
set -euo pipefail
cd "$(dirname "$0")"
OUT=../build/ios
xcodegen generate --quiet
case "${1:-simulator}" in
simulator)
  xcodebuild -project Browser.xcodeproj -scheme Browser -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$OUT" -quiet build
  echo "$OUT/Build/Products/Debug-iphonesimulator/Browser.app"
  ;;
device)
  xcodebuild -project Browser.xcodeproj -scheme Browser -destination 'generic/platform=iOS' \
    -derivedDataPath "$OUT" -allowProvisioningUpdates -quiet build
  # The first connected device that isn't one of this Mac's simulators.
  DEVICE="$(xcrun devicectl list devices --hide-headers --hide-default-columns --columns Identifier --filter "State == 'connected'" 2>/dev/null \
    | awk '{print $1}' | grep -v -F -f <(xcrun simctl list devices | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}') | head -1 || true)"
  [ -n "$DEVICE" ] || { echo "No iPhone connected" >&2; exit 1; }
  xcrun devicectl device install app --device "$DEVICE" "$OUT/Build/Products/Debug-iphoneos/Browser.app"
  ;;
testflight)
  ASC_KEY_ID="${ASC_KEY_ID:-JH8H9T3AN9}"
  ASC_ISSUER_ID="${ASC_ISSUER_ID:-570b1823-77bf-407c-b0a6-8b4c726f5741}"
  AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
    -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  ARCHIVE="$OUT/Browser.xcarchive"
  rm -rf "$ARCHIVE" "$OUT/testflight"
  mkdir -p "$OUT"
  # Each upload needs a higher build number than the last: the time, in UTC.
  xcodebuild -project Browser.xcodeproj -scheme Browser -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" CURRENT_PROJECT_VERSION="$(date -u +%Y%m%d%H%M)" "${AUTH[@]}" -quiet archive
  cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>H5A6B4L9W8</string>
  <key>testFlightInternalTestingOnly</key><true/>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/export.plist" \
    -exportPath "$OUT/testflight" "${AUTH[@]}"
  ;;
*)
  echo "usage: iOS/build.sh [simulator|device|testflight]" >&2
  exit 1
  ;;
esac
