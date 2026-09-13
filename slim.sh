#!/bin/bash

# Script to configure Android TV/Google TV via ADB
# Requires ADB installed and device on the same network

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if ADB is installed
check_adb() {
    if ! command -v adb &> /dev/null; then
        echo -e "${RED}Error: ADB is not installed. Please install it first.${NC}"
        exit 1
    fi
}

# Every adb call goes through here, so the target device is pinned for the whole
# run and no call can eat this script's stdin (a bare `adb shell` drains it).
TARGET=""
ADB() {
    if [ -n "$TARGET" ]; then
        adb -s "$TARGET" "$@" < /dev/null
    else
        adb "$@" < /dev/null
    fi
}

# Function to connect to the device.
# Pins one device for the run: plain `adb shell` uses whatever single device is
# attached, so an emulator running alongside the TV is enough to debloat the
# wrong one. Set SLIM_SERIAL (or ANDROID_SERIAL) to skip the prompt.
connect_adb() {
    local online count model

    if [ -n "$ANDROID_SERIAL" ]; then
        TARGET="$ANDROID_SERIAL"
    elif [ -n "$SLIM_SERIAL" ]; then
        TARGET="$SLIM_SERIAL"
    fi

    if [ -z "$TARGET" ]; then
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
                printf '%s\n' "$online" | sed 's/^/  SLIM_SERIAL=/;s/$/ .\/slim.sh/'
                exit 1
            fi
            TARGET=$(printf '%s\n' "$online" | sed -n "${pick}p")
        else
            echo "Enter the IP address of your Android TV (e.g., 192.168.1.100):"
            read -r IP
            echo "Connecting to $IP:5555..."
            adb connect "$IP:5555" < /dev/null
            echo "Please approve the ADB connection on your TV screen, then press Enter to continue."
            read -r
            echo "Reconnecting to confirm..."
            adb connect "$IP:5555" < /dev/null
            TARGET="$IP:5555"
        fi
    fi

    if [ -z "$TARGET" ] || ! adb -s "$TARGET" get-state > /dev/null 2>&1 < /dev/null; then
        echo -e "${RED}Failed to connect to ${TARGET:-a device}. Check the IP or TV approval.${NC}"
        exit 1
    fi
    model=$(ADB shell getprop ro.product.model | tr -d '\r')
    echo -e "${GREEN}Target: $TARGET${NC} ($model)"
}

# Function to ask yes/no questions
ask_yes_no() {
    local yn
    while true; do
        printf "%s (y/n): " "$1"
        # A bare `read` returns non-zero at EOF and leaves yn empty, which would
        # otherwise fall through to the retry branch and spin forever.
        if ! read -r yn; then
            echo
            return 1
        fi
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

# Read one top-level field out of a JSON document.
# Uses jq when it's available and falls back to grep/sed so the script still
# runs on machines without it. Handles both "string" and numeric values.
json_field() {
    if command -v jq &> /dev/null; then
        printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty'
    else
        printf '%s' "$1" | tr -d '\n' \
            | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+)" \
            | sed "s/^\"$2\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"\$//"
    fi
}

# Read a flat array of strings out of a JSON document, one per line.
json_array() {
    if command -v jq &> /dev/null; then
        printf '%s' "$1" | jq -r --arg k "$2" '.[$k][]? // empty'
    else
        local body
        body=$(printf '%s' "$1" | tr -d '\n' \
            | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\[[^]]*\]")
        [ -z "$body" ] && return 0
        printf '%s' "$body" \
            | sed 's/^[^[]*\[//; s/\]$//' \
            | tr ',' '\n' \
            | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' \
            | grep -v '^[[:space:]]*$'
    fi
}

# The debloat list is published rather than hardcoded, so slim.sh,
# slim-device.sh and the installer app all work from one source. Falls back to
# the copy in the repo when the published one cannot be reached.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MANIFEST_URL="${SLIM_MANIFEST_URL:-https://raw.githubusercontent.com/john8675309/slim_onn/main/slim.json}"
MANIFEST=$(wget -qO- "$MANIFEST_URL" 2>/dev/null)
if [ -z "$MANIFEST" ] && [ -f "$SCRIPT_DIR/slim.json" ]; then
    MANIFEST=$(cat "$SCRIPT_DIR/slim.json")
    echo -e "${YELLOW}Manifest unreachable, using $SCRIPT_DIR/slim.json${NC}"
fi
BLOAT=$(json_array "$MANIFEST" bloat)
DISABLE=$(json_array "$MANIFEST" disable)
LAUNCHER_REPLACEMENT=$(json_field "$MANIFEST" launcherReplacement)

# Check for ADB
check_adb

# Get IP and connect
connect_adb

# Disable and uninstall system apps
echo "Disabling and uninstalling unwanted apps..."
if [ -z "$BLOAT" ]; then
    # An empty list and a clean device look identical in the output, so say
    # plainly that nothing was attempted rather than reporting a quiet success.
    echo -e "${RED}No debloat list available, skipping. Check $MANIFEST_URL${NC}"
else
    for pkg in $BLOAT; do
        if ADB shell pm uninstall -k --user 0 "$pkg" 2>&1 | grep -q Success; then
            echo -e "  ${GREEN}removed${NC} $pkg"
        fi
    done
fi

# Download and install FLauncher
echo "Installing FLauncher..."
wget -q https://github.com/john8675309/flauncher/releases/download/v0.1.1/flauncher-0.1.1.apk -O flauncher.apk
ADB install flauncher.apk && echo -e "${GREEN}FLauncher installed${NC}" || echo -e "${RED}FLauncher installation failed${NC}"

# Optional Emby installation -- Emby ships per-ABI builds, so match the device
if ask_yes_no "Do you want to install Emby?"; then
    EMBY_BASE="https://github.com/MediaBrowser/Emby.Releases/raw/master/android"
    ABILIST=$(ADB shell getprop ro.product.cpu.abilist | tr -d '\r')
    case "$ABILIST" in
        *arm64-v8a*) EMBY_ABI="arm64-v8a" ;;
        *)           EMBY_ABI="armeabi-v7a" ;;
    esac
    echo "Installing Emby ($EMBY_ABI)..."
    wget -q "$EMBY_BASE/emby-android-google-$EMBY_ABI-release.apk" -O Emby.apk
    ADB install Emby.apk && echo -e "${GREEN}Emby installed${NC}" || echo -e "${RED}Emby installation failed${NC}"
fi

# IPTV app selection
echo "Choose an IPTV app to install:"
echo "1) IPTV Smarters"
echo "2) Tivimate"
echo "3) JTV"
echo "4) None"
read -p "Enter your choice (1-4): " iptv_choice
IPTV_INSTALLED=false
case $iptv_choice in
    1)
        echo "Installing IPTV Smarters..."
        wget -q https://www.johnhass.com/s.apk -O sm.apk
        ADB install sm.apk && echo -e "${GREEN}IPTV Smarters installed${NC}" || echo -e "${RED}IPTV Smarters installation failed${NC}"
        IPTV_INSTALLED=true
        ;;
    2)
        echo "Installing Tivimate..."
        wget -q https://files.tivimate.com/tivimate.apk
        ADB install tivimate.apk && echo -e "${GREEN}Tivimate installed${NC}" || echo -e "${RED}Tivimate installation failed${NC}"
        IPTV_INSTALLED=true
        ;;
    3)
        # JTV publishes a manifest so the installer always picks up the latest build
        echo "Checking for the latest JTV..."
        JTV_MANIFEST=$(wget -qO- https://johnhass.com/jtv.json)
        JTV_URL=$(json_field "$JTV_MANIFEST" apkUrl)
        JTV_VERSION=$(json_field "$JTV_MANIFEST" versionName)
        JTV_SHA=$(json_field "$JTV_MANIFEST" sha256)
        JTV_MINSDK=$(json_field "$JTV_MANIFEST" minSdk)

        if [ -z "$JTV_URL" ]; then
            echo -e "${RED}Could not read the JTV manifest, skipping JTV${NC}"
        else
            DEVICE_SDK=$(ADB shell getprop ro.build.version.sdk | tr -d '\r')
            if [ -n "$JTV_MINSDK" ] && [ -n "$DEVICE_SDK" ] && [ "$DEVICE_SDK" -lt "$JTV_MINSDK" ]; then
                echo -e "${RED}JTV $JTV_VERSION needs Android SDK $JTV_MINSDK, this device is SDK $DEVICE_SDK. Skipping.${NC}"
            else
                echo "Installing JTV $JTV_VERSION..."
                wget -q "$JTV_URL" -O jtv.apk

                # The manifest ships a checksum, so use it
                if [ -n "$JTV_SHA" ] && command -v sha256sum &> /dev/null; then
                    ACTUAL_SHA=$(sha256sum jtv.apk | cut -d' ' -f1)
                    if [ "$ACTUAL_SHA" != "$JTV_SHA" ]; then
                        echo -e "${RED}JTV checksum mismatch, refusing to install${NC}"
                        echo "  expected: $JTV_SHA"
                        echo "  actual:   $ACTUAL_SHA"
                        rm -f jtv.apk
                        JTV_URL=""
                    fi
                fi

                if [ -n "$JTV_URL" ]; then
                    ADB install jtv.apk && echo -e "${GREEN}JTV $JTV_VERSION installed${NC}" || echo -e "${RED}JTV installation failed${NC}"
                    IPTV_INSTALLED=true
                fi
            fi
        fi
        ;;

    4)
        echo "Skipping IPTV app installation."
        ;;
    *)
        echo "Invalid choice, skipping IPTV installation."
        ;;
esac

# Install TV Button Mapper alongside the selected TV app
if [ "$IPTV_INSTALLED" = true ]; then
    echo "Installing TV Button Mapper..."
    wget -q https://github.com/john8675309/tvbuttonmapper/releases/download/v0.1.0/tvbuttonmapper-v0.1.0-debug.apk -O tvbuttonmapper.apk
    ADB install tvbuttonmapper.apk && echo -e "${GREEN}TV Button Mapper installed${NC}" || echo -e "${RED}TV Button Mapper installation failed${NC}"
fi

# Remove Google account.
# There is no unrooted ADB command that can delete an account -- AccountManager
# only lets the authenticator or the user remove it. So open the accounts screen
# and have the user do it with the remote, then verify it actually went away.
list_accounts() {
    ADB shell dumpsys account 2>/dev/null | grep -o 'name=[^,]*, type=[^}]*' | sed 's/name=/  /; s/, type=/ (/; s/$/)/'
}

echo "Checking for signed-in accounts..."
ACCOUNTS=$(list_accounts)
if [ -z "$ACCOUNTS" ]; then
    echo -e "${GREEN}No accounts signed in, nothing to remove.${NC}"
elif ask_yes_no "Found:
$ACCOUNTS
Do you want to remove an account?"; then
    echo "Opening the accounts screen on your TV..."
    ADB shell am start -a android.settings.SYNC_SETTINGS > /dev/null 2>&1 \
        || ADB shell am start -n com.android.tv.settings/com.google.android.tv.settings.AccountActivity > /dev/null 2>&1
    echo "On the TV, pick the account and choose 'Remove account'."
    echo "Press Enter here when you're done."
    read -r
    REMAINING=$(list_accounts)
    if [ -z "$REMAINING" ]; then
        echo -e "${GREEN}Account removed.${NC}"
    else
        echo -e "${RED}Still signed in:${NC}"
        echo "$REMAINING"
    fi
fi

# Final disables
echo "Applying final tweaks..."
if [ -z "$LAUNCHER_REPLACEMENT" ]; then
    echo -e "${RED}No launcherReplacement in the manifest, leaving the launcher alone${NC}"
elif ADB shell pm path "$LAUNCHER_REPLACEMENT" 2>/dev/null | grep -q package:; then
    for pkg in $DISABLE; do
        ADB shell pm disable-user --user 0 "$pkg" > /dev/null 2>&1 \
            && echo -e "  ${GREEN}disabled${NC} $pkg"
    done
else
    # Disabling the stock launcher with nothing to replace it leaves the TV
    # with no home screen.
    echo -e "${YELLOW}Skipped: $LAUNCHER_REPLACEMENT is not installed${NC}"
fi

# Clean up downloaded files
echo "Cleaning up..."
rm -f flauncher.apk Emby.apk sm.apk tivimate.apk jtv.apk tvbuttonmapper.apk

echo -e "${GREEN}Script completed! Reboot your TV to apply changes.${NC}"
echo "Run 'adb reboot' if you want to reboot now."
