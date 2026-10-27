#!/bin/bash
# Installs the Islet Audio HAL plug-in and restarts coreaudiod. Run with sudo.
set -euo pipefail
cd "$(dirname "$0")"

SRC=build/IsletAudio.driver
DST=/Library/Audio/Plug-Ins/HAL/IsletAudio.driver

if [[ $EUID -ne 0 ]]; then
    echo "error: run with sudo: sudo $0" >&2
    exit 1
fi
if [[ ! -d "$SRC" ]]; then
    echo "error: $SRC not found; run ./build.sh first" >&2
    exit 1
fi

mkdir -p /Library/Audio/Plug-Ins/HAL
rm -rf "$DST"
cp -R "$SRC" "$DST"
chown -R root:wheel "$DST"
chmod -R go-w "$DST"

launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod
echo "Installed $DST and restarted coreaudiod."
