#!/bin/bash
# Builds Islet.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
(cd Driver && ./build.sh >/dev/null)

APP=build/Islet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Islet "$APP/Contents/MacOS/Islet"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp -R Driver/build/IsletAudio.driver "$APP/Contents/Resources/"
# SwiftPM resource bundles (e.g. Lottie) must sit next to the executable's Resources.
for b in .build/release/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# Embed dynamic frameworks (Lottie) and point the executable at them.
mkdir -p "$APP/Contents/Frameworks"
cp -R .build/release/Lottie.framework "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Islet" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Frameworks/Lottie.framework"
codesign --force --sign - "$APP/Contents/Resources/IsletAudio.driver"
codesign --force --sign - "$APP"

echo "Built $(pwd)/$APP"
