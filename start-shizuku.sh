#!/bin/bash
#
# Starts the Shizuku server over ADB.
#
# This is the simple path, and it needs no Wireless Debugging pairing at all:
# `adb shell` already runs as shell (uid 2000), which is the only thing
# starting the server requires. Pairing is what Shizuku falls back to when
# there is no PC -- it uses its bundled adb client to reach the device from
# itself. With a PC attached, just run the starter.
#
# The server does not survive a reboot, so re-run this after one.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SHIZUKU_PACKAGE="moe.shizuku.privileged.api"

TARGET=""
ADB() {
    if [ -n "$TARGET" ]; then
        adb -s "$TARGET" "$@" < /dev/null
    else
        adb "$@" < /dev/null
    fi
}

if ! command -v adb &> /dev/null; then
    echo -e "${RED}Error: ADB is not installed.${NC}"
    exit 1
fi

# Pin one device, exactly as the other scripts do: a plain `adb shell` uses
# whatever single device happens to be attached.
if [ -n "$ANDROID_SERIAL" ]; then
    TARGET="$ANDROID_SERIAL"
elif [ -n "$SLIM_SERIAL" ]; then
    TARGET="$SLIM_SERIAL"
else
    online=$(adb devices < /dev/null | sed '1d' | awk '$2 == "device" { print $1 }')
    count=$(printf '%s\n' "$online" | grep -c .)
    if [ "$count" -eq 1 ]; then
        TARGET="$online"
    elif [ "$count" -gt 1 ]; then
        echo "More than one device is attached:"
        printf '%s\n' "$online" | nl -w3 -s') '
        printf "Which one? (number): "
        if ! read -r pick || ! printf '%s' "$pick" | grep -qE '^[0-9]+$' \
           || [ "$pick" -lt 1 ] || [ "$pick" -gt "$count" ]; then
            echo
            echo -e "${RED}No valid selection.${NC}"
            printf '%s\n' "$online" | sed 's/^/  SLIM_SERIAL=/;s/$/ .\/start-shizuku.sh/'
            exit 1
        fi
        TARGET=$(printf '%s\n' "$online" | sed -n "${pick}p")
    else
        echo -e "${RED}No device attached.${NC}"
        exit 1
    fi
fi

if ! adb -s "$TARGET" get-state > /dev/null 2>&1 < /dev/null; then
    echo -e "${RED}Could not reach $TARGET.${NC}"
    exit 1
fi
echo -e "${GREEN}Target: $TARGET${NC} ($(ADB shell getprop ro.product.model | tr -d '\r'))"

if ! ADB shell pm path "$SHIZUKU_PACKAGE" 2>/dev/null | grep -q package:; then
    echo -e "${RED}Shizuku is not installed on this device.${NC}"
    echo "Install it first, e.g. with the Slim Installer app, or:"
    echo "  adb -s $TARGET install shizuku.apk"
    exit 1
fi

if ADB shell 'ps -A' 2>/dev/null | grep -q shizuku_server; then
    echo -e "${YELLOW}Already running.${NC}"
    exit 0
fi

# The starter lives in the APK's native library directory. Its path contains a
# per-install hash, and /data/app is not listable by shell, so derive it from
# `pm path` rather than globbing for it.
echo "Starting the Shizuku server..."
ADB shell 'd=$(pm path '"$SHIZUKU_PACKAGE"' | sed "s/package://; s|/base.apk||"); for f in "$d"/lib/*/libshizuku.so; do exec "$f"; done'

sleep 2
if ADB shell 'ps -A' 2>/dev/null | grep -q shizuku_server; then
    echo -e "${GREEN}Shizuku is running as shell.${NC}"
    echo "In the app, press Re-check Shizuku (or just return to it)."
else
    echo -e "${RED}The server did not come up. See the starter output above.${NC}"
    exit 1
fi
