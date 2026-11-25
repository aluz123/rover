#!/bin/bash
# Rover — by Alex Towfigh (MIT License).
# Builds Rover.app with plain swiftc (works with just the Command Line Tools; no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")/.."
B=.build/rover; mkdir -p "$B"
ARCH=$(uname -m)
T="$ARCH-apple-macos13.0"
swiftc -target "$T" -Ounchecked -wmo -parse-as-library -module-name RoverCore \
  -emit-module -emit-module-path "$B/RoverCore.swiftmodule" \
  -emit-library -static -o "$B/libRoverCore.a" Sources/RoverCore/*.swift
swiftc -target "$T" -O -wmo -module-name Rover -I "$B" -L "$B" -lRoverCore Sources/Rover/*.swift -o "$B/Rover"

APP=dist/Rover.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$B/Rover" "$APP/Contents/MacOS/Rover"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/AppIcon.icns "$APP/Contents/Resources/"
cp assets/MenuBar.png assets/MenuBar@2x.png "$APP/Contents/Resources/"
# A stable signing identity lets macOS remember file access across rebuilds; fall back to ad-hoc.
ID=$(security find-identity -p codesigning -v 2>/dev/null | grep -m1 -E "Apple Development|Developer ID Application" | awk '{print $2}' || true)
codesign --force --sign "${ID:--}" --identifier com.alextowfigh.rover "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
echo "built $APP"
