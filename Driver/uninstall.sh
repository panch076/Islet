#!/bin/bash
# Removes the Islet Audio HAL plug-in and restarts coreaudiod. Run with sudo.
set -euo pipefail

DST=/Library/Audio/Plug-Ins/HAL/IsletAudio.driver

if [[ $EUID -ne 0 ]]; then
    echo "error: run with sudo: sudo $0" >&2
    exit 1
fi

if [[ -d "$DST" ]]; then
    rm -rf "$DST"
    echo "Removed $DST."
else
    echo "$DST is not installed."
fi

launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod
echo "Restarted coreaudiod."
