#!/bin/bash
#
# PC side of the on-device installer.
#
# Android has no curl, wget or TLS, so the device cannot fetch APKs itself.
# This script does the downloading here, pushes the payload plus slim-device.sh
# to the TV, and then runs that script on the device.
#
# After this has run once the payload stays in /data/local/tmp/slim, so the
# device script can be re-run without downloading anything again:
#
#   adb shell sh /data/local/tmp/slim/slim-device.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PAYLOAD="$SCRIPT_DIR/slim-payload"
REMOTE="/data/local/tmp/slim"

# Every adb call goes through here, so the target is always pinned and no call
# can eat this script's stdin (a bare `adb shell` drains it, which starves the
# prompts further down).
TARGET=""
ADB() {
    if [ -n "$TARGET" ]; then
        adb -s "$TARGET" "$@" < /dev/null
    else
        adb "$@" < /dev/null
    fi
}

check_adb() {
    if ! command -v adb &> /dev/null; then
        echo -e "${RED}Error: ADB is not installed. Please install it first.${NC}"
        exit 1
    fi
}

# Pick exactly one device and stick to it. Plain `adb shell` just uses whatever
# single device happens to be attached, so an emulator running alongside the TV
# is enough to silently debloat the wrong one.
connect_adb() {
    local online count

    # Honour the standard adb variable, or SLIM_SERIAL, when the target is
    # already known.
    if [ -n "$ANDROID_SERIAL" ]; then
        TARGET="$ANDROID_SERIAL"
    elif [ -n "$SLIM_SERIAL" ]; then
        TARGET="$SLIM_SERIAL"
    fi

    if [ -z "$TARGET" ]; then
        online=$(adb devices < /dev/null | sed '1d' | awk '$2 == "device" { print $1 }')
        count=$(printf '%s\n' "$online" | grep -c . )

        if [ "$count" -eq 0 ]; then
            echo "No device attached."
            echo "Enter the IP address of your Android TV (e.g., 192.168.1.100):"
            read -r IP
            echo "Connecting to $IP:5555..."
            adb connect "$IP:5555" < /dev/null
            echo "Approve the ADB connection on your TV, then press Enter."
            read -r
            adb connect "$IP:5555" < /dev/null
            TARGET="$IP:5555"
        elif [ "$count" -eq 1 ]; then
            TARGET="$online"
        else
            echo "More than one device is attached:"
            printf '%s\n' "$online" | nl -w3 -s') '
            printf "Which one? (number): "
            # An empty or non-numeric answer would make `sed -n "${pick}p"`
            # print every line, so validate before using it.
            if ! read -r pick || ! printf '%s' "$pick" | grep -qE '^[0-9]+$' \
               || [ "$pick" -lt 1 ] || [ "$pick" -gt "$count" ]; then
                echo
                echo -e "${RED}No valid selection.${NC}"
                echo "Set SLIM_SERIAL=<serial> to choose one explicitly, e.g.:"
                printf '%s\n' "$online" | sed 's/^/  SLIM_SERIAL=/;s/$/ .\/slim-push.sh/'
                exit 1
            fi
            TARGET=$(printf '%s\n' "$online" | sed -n "${pick}p")
        fi
    fi

    if [ -z "$TARGET" ] || ! adb -s "$TARGET" get-state > /dev/null 2>&1 < /dev/null; then
        echo -e "${RED}Could not reach a device (target: ${TARGET:-none}).${NC}"
        echo "Set SLIM_SERIAL=<serial> to choose one explicitly."
        exit 1
    fi

    local model
    model=$(ADB shell getprop ro.product.model | tr -d '\r')
    echo -e "${GREEN}Target: $TARGET${NC} ($model)"
}

ask_yes_no() {
    local yn
    while true; do
        printf "%s (y/n): " "$1"
        # A bare `read` returns non-zero at EOF and leaves yn empty, which would
        # otherwise fall through to the retry branch and spin forever.
        if ! read -r yn; then
            echo
            echo -e "${YELLOW}(no input available, assuming no)${NC}"
            return 1
        fi
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

# Read one top-level field out of a JSON document. Uses jq when available and
# falls back to grep/sed so this still works without it.
json_field() {
    if command -v jq &> /dev/null; then
        printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty'
    else
        printf '%s' "$1" | tr -d '\n' \
            | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+)" \
            | sed "s/^\"$2\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"\$//"
    fi
}

# fetch <url> <output-name> [expected-sha256]
fetch() {
    local url="$1" out="$2" want="$3"
    echo "  downloading $out..."
    if ! wget -q "$url" -O "$PAYLOAD/$out"; then
        echo -e "  ${RED}download failed: $out${NC}"
        rm -f "$PAYLOAD/$out"
        return 1
    fi
    if [ -n "$want" ] && command -v sha256sum &> /dev/null; then
        local got
        got=$(sha256sum "$PAYLOAD/$out" | cut -d' ' -f1)
        if [ "$got" != "$want" ]; then
            echo -e "  ${RED}checksum mismatch on $out, discarding${NC}"
            rm -f "$PAYLOAD/$out"
            return 1
        fi
    fi
    return 0
}

check_adb
connect_adb

rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"

echo
echo "Building the payload..."

# FLauncher, always included -- the device script refuses to disable the stock
# launcher unless this one is present.
fetch https://github.com/john8675309/flauncher/releases/download/v0.1.1/flauncher-0.1.1.apk flauncher.apk

# TV Button Mapper goes along with any IPTV app.
WANT_BUTTONMAPPER=0

echo
if ask_yes_no "Do you want to install Emby?"; then
    # Emby ships per-ABI builds, so match the device.
    ABILIST=$(ADB shell getprop ro.product.cpu.abilist | tr -d '\r')
    case "$ABILIST" in
        *arm64-v8a*) EMBY_ABI="arm64-v8a" ;;
        *)           EMBY_ABI="armeabi-v7a" ;;
    esac
    echo "  device ABI: $EMBY_ABI"
    fetch "https://github.com/MediaBrowser/Emby.Releases/raw/master/android/emby-android-google-$EMBY_ABI-release.apk" Emby.apk
fi

echo
echo "Choose an IPTV app to install:"
echo "1) IPTV Smarters"
echo "2) Tivimate"
echo "3) JTV"
echo "4) None"
read -p "Enter your choice (1-4): " iptv_choice || iptv_choice=4
case $iptv_choice in
    1)
        fetch https://www.johnhass.com/s.apk sm.apk && WANT_BUTTONMAPPER=1
        ;;
    2)
        fetch https://files.tivimate.com/tivimate.apk tivimate.apk && WANT_BUTTONMAPPER=1
        ;;
    3)
        # JTV publishes a manifest so the installer always picks up the latest build.
        echo "  checking for the latest JTV..."
        JTV_MANIFEST=$(wget -qO- https://johnhass.com/jtv.json)
        JTV_URL=$(json_field "$JTV_MANIFEST" apkUrl)
        JTV_VERSION=$(json_field "$JTV_MANIFEST" versionName)
        JTV_SHA=$(json_field "$JTV_MANIFEST" sha256)
        JTV_MINSDK=$(json_field "$JTV_MANIFEST" minSdk)
        DEVICE_SDK=$(ADB shell getprop ro.build.version.sdk | tr -d '\r')

        if [ -z "$JTV_URL" ]; then
            echo -e "  ${RED}could not read the JTV manifest, skipping JTV${NC}"
        elif [ -n "$JTV_MINSDK" ] && [ -n "$DEVICE_SDK" ] && [ "$DEVICE_SDK" -lt "$JTV_MINSDK" ]; then
            echo -e "  ${RED}JTV $JTV_VERSION needs SDK $JTV_MINSDK, device is SDK $DEVICE_SDK. Skipping.${NC}"
        else
            echo "  JTV $JTV_VERSION"
            fetch "$JTV_URL" jtv.apk "$JTV_SHA" && WANT_BUTTONMAPPER=1
        fi
        ;;
    4)
        echo "  skipping IPTV app"
        ;;
    *)
        echo "  invalid choice, skipping IPTV app"
        ;;
esac

if [ "$WANT_BUTTONMAPPER" -eq 1 ]; then
    fetch https://github.com/john8675309/tvbuttonmapper/releases/download/v0.1.0/tvbuttonmapper-v0.1.0-debug.apk tvbuttonmapper.apk
fi

# The debloat list travels with the payload: the device cannot fetch it itself,
# so take the published copy when reachable and fall back to the one in the repo.
MANIFEST_URL="${SLIM_MANIFEST_URL:-https://raw.githubusercontent.com/john8675309/slim_onn/main/slim.json}"
echo
echo "Adding the debloat manifest..."
if wget -q "$MANIFEST_URL" -O "$PAYLOAD/slim.json" && [ -s "$PAYLOAD/slim.json" ]; then
    echo "  from $MANIFEST_URL"
elif [ -f "$SCRIPT_DIR/slim.json" ]; then
    cp "$SCRIPT_DIR/slim.json" "$PAYLOAD/slim.json"
    echo -e "  ${YELLOW}published copy unreachable, using $SCRIPT_DIR/slim.json${NC}"
else
    rm -f "$PAYLOAD/slim.json"
    echo -e "  ${RED}no slim.json available -- the device will skip the debloat${NC}"
fi

# Checksum sidecar so the device can detect a truncated push.
( cd "$PAYLOAD" && sha256sum *.apk > sha256sums 2>/dev/null )

echo
echo "Payload:"
ls -1sh "$PAYLOAD"/*.apk 2>/dev/null | sed 's/^/  /'

echo
echo "Pushing to $REMOTE..."
ADB shell "rm -rf $REMOTE; mkdir -p $REMOTE"
ADB push "$PAYLOAD/." "$REMOTE/" > /dev/null || {
    echo -e "${RED}Push failed.${NC}"
    exit 1
}
ADB push "$SCRIPT_DIR/slim-device.sh" "$REMOTE/slim-device.sh" > /dev/null || {
    echo -e "${RED}Could not push slim-device.sh.${NC}"
    exit 1
}
echo -e "${GREEN}Payload pushed.${NC}"

echo
OPEN_ACCOUNTS=0
if ask_yes_no "Open the account-removal screen on the TV at the end?"; then
    OPEN_ACCOUNTS=1
fi

echo
echo "---- running on the device ----"
ADB shell "SLIM_OPEN_ACCOUNTS=$OPEN_ACCOUNTS sh $REMOTE/slim-device.sh"
STATUS=$?
echo "---- device finished ----"
echo

if [ "$OPEN_ACCOUNTS" -eq 1 ]; then
    echo "If an account was listed, remove it on the TV with the remote."
fi
echo "To re-run later without downloading again:"
echo "  adb shell sh $REMOTE/slim-device.sh"
echo "Run 'adb reboot' to apply everything."
exit "$STATUS"
