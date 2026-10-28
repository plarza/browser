#!/bin/bash
# Puts Core's WebKit inside Core.app: the frameworks, the two libraries
# they load beside themselves, and WebKit's XPC services as real folders
# (the build leaves them as symlinks). The launcher (engine/launcher.c)
# points dyld here.
#
#   engine/embed.sh <WebKitBuild/Release> <Core.app> <signing identity, or ->
set -euo pipefail
ENGINE="$1"
APP="$2"
IDENTITY="${3:--}"
here="$(cd "$(dirname "$0")" && pwd)"
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"

for name in JavaScriptCore WebCore WebKit WebKitLegacy WebGPU WebInspectorUI; do
  [ -d "$ENGINE/$name.framework" ] && ditto "$ENGINE/$name.framework" "$FW/$name.framework"
done
for lib in libwebrtc.dylib libANGLE-shared.dylib; do
  [ -e "$ENGINE/$lib" ] && ditto "$ENGINE/$lib" "$FW/$lib"
done

XPC="$FW/WebKit.framework/Versions/A/XPCServices"
for link in "$XPC"/*.xpc; do
  name="$(basename "$link")"
  rm -f "$link"
  case "$name" in
    # Not used by Core: the captive-portal, development and model processes.
    *CaptivePortal*|*Development*|*Model*) continue ;;
  esac
  ditto "$ENGINE/$name" "$XPC/$name"
done

# Local builds keep the build's own ad-hoc signatures. A release re-signs
# every piece inside out with the Developer ID and the hardened runtime;
# the XPC services keep their entitlements minus JIT (Core has none) and
# the debugger's, plus leave to read the dyld path the launcher sets.
if [ "$IDENTITY" != "-" ]; then
  sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
  for lib in "$FW"/*.dylib "$FW/WebKit.framework/Versions/A/Frameworks"/*.dylib; do
    [ -e "$lib" ] && sign "$lib"
  done
  for service in "$XPC"/*.xpc; do
    ents="$(mktemp)"
    codesign -d --entitlements - --xml "$service" 2>/dev/null > "$ents.in" || true
    python3 "$here/entitlements.py" "$ents.in" > "$ents"
    sign --entitlements "$ents" "$service"
    rm -f "$ents" "$ents.in"
  done
  for name in JavaScriptCore WebGPU WebCore WebKitLegacy WebInspectorUI WebKit; do
    [ -d "$FW/$name.framework" ] && sign "$FW/$name.framework"
  done
fi
