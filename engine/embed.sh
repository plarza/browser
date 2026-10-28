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
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"

for name in JavaScriptCore WebCore WebKit WebKitLegacy WebGPU WebInspectorUI; do
  [ -d "$ENGINE/$name.framework" ] && ditto "$ENGINE/$name.framework" "$FW/$name.framework"
done
for lib in libwebrtc.dylib libANGLE-shared.dylib; do
  [ -e "$ENGINE/$lib" ] && ditto "$ENGINE/$lib" "$FW/$lib"
done

# Links the build leaves pointing back into its own folder: the real file
# when the build has it, gone when it doesn't.
while IFS= read -r link; do
  name="$(basename "$link")"
  rm -f "$link"
  [ -e "$ENGINE/$name" ] && ditto "$ENGINE/$name" "$link"
done < <(find -L "$FW" -type l -not -path '*/XPCServices/*')

XPC="$FW/WebKit.framework/Versions/A/XPCServices"
# A build's services are links to sibling bundles; an already assembled
# runtime has real service directories, which ditto has copied intact.
while IFS= read -r link; do
  name="$(basename "$link")"
  rm "$link"
  case "$name" in
    *CaptivePortal*|*Development*|*Model*) continue ;;
  esac
  ditto "$ENGINE/$name" "$link"
done < <(find "$XPC" -maxdepth 1 -type l -name '*.xpc')

# Every piece is re-signed inside out (WebKit's build leaves some seals
# stale). A release uses the Developer ID and the hardened runtime, and the
# XPC services keep their entitlements minus JIT (Core has none) and the
# debugger's, plus leave to read the dyld path the launcher sets. A local
# build signs ad hoc and keeps the build's entitlements.
if [ "$IDENTITY" = "-" ]; then
  sign() { codesign --force --sign - "$@"; }
else
  sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
fi
for lib in "$FW"/*.dylib "$FW/WebKit.framework/Versions/A/Frameworks"/*.dylib; do
  [ -e "$lib" ] && sign "$lib"
done
for service in "$XPC"/*.xpc; do
  ents="$(mktemp)"
  codesign -d --entitlements - --xml "$service" 2>/dev/null > "$ents.in" || true
  cp "$ents.in" "$ents"
  if [ "$IDENTITY" != "-" ]; then
    # Minus JIT (Core has none), the debugger's and Apple-private ones;
    # plus leave to read the dyld path the launcher sets.
    pb=/usr/libexec/PlistBuddy
    [ -s "$ents" ] || $pb -c "Save" "$ents" >/dev/null
    for key in $(plutil -convert json -o - "$ents" | jq -r 'keys[]'); do
      case "$key" in
        com.apple.security.cs.allow-jit|com.apple.security.get-task-allow|com.apple.private.*) $pb -c "Delete :$key" "$ents" ;;
      esac
    done
    $pb -c "Delete :com.apple.security.cs.allow-dyld-environment-variables" "$ents" 2>/dev/null || true
    $pb -c "Add :com.apple.security.cs.allow-dyld-environment-variables bool true" "$ents"
  fi
  if [ -s "$ents" ]; then sign --entitlements "$ents" "$service"; else sign "$service"; fi
  rm -f "$ents" "$ents.in"
done
for name in JavaScriptCore WebGPU WebCore WebKitLegacy WebInspectorUI WebKit; do
  [ -d "$FW/$name.framework" ] && sign "$FW/$name.framework"
done
