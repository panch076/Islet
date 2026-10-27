#!/bin/bash
# Builds the Islet Audio HAL plug-in into Driver/build/IsletAudio.driver and ad-hoc signs it.
# Usage: ./build.sh            (universal x86_64 + arm64)
#        ARCHS="x86_64" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

ARCHS="${ARCHS:-x86_64 arm64}"
BUNDLE=build/IsletAudio.driver

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(-arch "$a"); done

clang -bundle -O2 "${ARCH_FLAGS[@]}" \
    -mmacosx-version-min=13.0 \
    -std=c11 -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wno-sign-conversion \
    -fvisibility=hidden \
    -framework CoreAudio -framework CoreFoundation \
    -o "$BUNDLE/Contents/MacOS/IsletAudio" \
    IsletAudio.c

cp Info.plist "$BUNDLE/Contents/Info.plist"
codesign --force --sign - "$BUNDLE"

echo "Built $(pwd)/$BUNDLE ($(lipo -archs "$BUNDLE/Contents/MacOS/IsletAudio"))"
