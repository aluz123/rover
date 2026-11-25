#!/bin/bash
# Rover — by Alex Towfigh (MIT License).
# Builds a universal (Apple silicon + Intel) Rover.app and zips it for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" scripts/Info.plist)
B=.build/release; rm -rf "$B"; mkdir -p "$B"
for ARCH in arm64 x86_64; do
  T="$ARCH-apple-macos13.0"; O="$B/$ARCH"; mkdir -p "$O"
  swiftc -target "$T" -Ounchecked -wmo -parse-as-library -module-name RoverCore \
    -emit-module -emit-module-path "$O/RoverCore.swiftmodule" -emit-library -static -o "$O/libRoverCore.a" Sources/RoverCore/*.swift
  swiftc -target "$T" -O -wmo -module-name Rover -I "$O" -L "$O" -lRoverCore Sources/Rover/*.swift -o "$O/Rover"
done
APP=dist/release/Rover.app
rm -rf dist/release; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$B/arm64/Rover" "$B/x86_64/Rover" -output "$APP/Contents/MacOS/Rover"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/AppIcon.icns assets/MenuBar.png assets/MenuBar@2x.png "$APP/Contents/Resources/"
# Public builds: a Developer ID if you have one (then notarize), otherwise an anonymous ad-hoc signature.
# (An Apple Development certificate would embed your Apple ID email in the app for anyone to read.)
ID=$(security find-identity -p codesigning -v 2>/dev/null | grep -m1 -E "Developer ID Application" | awk '{print $2}' || true)
codesign --force --options runtime --timestamp --sign "${ID:--}" --identifier com.alextowfigh.rover "$APP" 2>/dev/null \
  || codesign --force --options runtime --sign "${ID:--}" --identifier com.alextowfigh.rover "$APP"
ZIP="dist/release/Rover-$VER.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
# Notarize when there's a Developer ID and saved notary credentials (one-time setup:
#   xcrun notarytool store-credentials rover-notary --apple-id <you> --team-id <TEAM> --password <app-specific password>)
if [ -n "$ID" ] && xcrun notarytool history --keychain-profile rover-notary >/dev/null 2>&1; then
  echo "notarizing (takes a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile rover-notary --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the ticket stapled
  spctl -a -vv "$APP" && echo "Gatekeeper: accepted"
else
  echo "not notarized (no Developer ID or no 'rover-notary' credentials); first launch needs Open Anyway"
fi
cp "$ZIP" dist/release/Rover.zip   # stable name for releases/latest/download/Rover.zip
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
lipo -archs "$APP/Contents/MacOS/Rover"
echo "release: $ZIP"
