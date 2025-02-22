#!/bin/bash

# Script to configure Android TV/Google TV via ADB
# Requires ADB installed and device on the same network

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Function to check if ADB is installed
check_adb() {
    if ! command -v adb &> /dev/null; then
        echo -e "${RED}Error: ADB is not installed. Please install it first.${NC}"
        exit 1
    fi
}

# Function to connect to the device
connect_adb() {
    echo "Enter the IP address of your Android TV (e.g., 192.168.1.100):"
    read -r IP
    echo "Connecting to $IP:5555..."
    adb connect "$IP:5555"
    echo "Please approve the ADB connection on your TV screen, then press Enter to continue."
    read -r
    echo "Reconnecting to confirm..."
    adb connect "$IP:5555"
    if adb devices | grep -q "$IP:5555"; then
        echo -e "${GREEN}Successfully connected to $IP:5555${NC}"
    else
        echo -e "${RED}Failed to connect. Check the IP or TV approval.${NC}"
        exit 1
    fi
}

# Function to ask yes/no questions
ask_yes_no() {
    while true; do
        read -p "$1 (y/n): " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

# Check for ADB
check_adb

# Get IP and connect
connect_adb

# Disable and uninstall system apps
echo "Disabling and uninstalling unwanted apps..."
adb shell pm uninstall -k --user 0 com.netflix.ninja
adb shell pm uninstall -k --user 0 com.google.android.youtube.tvunplugged
adb shell pm uninstall -k --user 0 com.google.android.youtube.tvmusic
adb shell pm uninstall -k --user 0 com.google.android.youtube.tv
adb shell pm uninstall -k --user 0 com.amazon.amazonvideo.livingroom
adb shell pm uninstall -k --user 0 com.disney.disneyplus
adb shell pm uninstall -k --user 0 com.hulu.livingroomplus
adb shell pm uninstall -k --user 0 com.tubitv
adb shell pm uninstall -k --user 0 com.apple.atve.androidtv.appletv
adb shell pm uninstall -k --user 0 com.cbs.app.TvApplication
adb shell pm uninstall -k --user 0 com.cbs.ott
adb shell pm uninstall -k --user 0 com.espn.androidtv.TvApplication
adb shell pm uninstall -k --user 0 com.espn.score_center
adb shell pm uninstall -k --user 0 com.wbd.stream
adb shell pm uninstall -k --user 0 com.google.android.play.games
adb shell pm uninstall -k --user 0 com.google.android.videos

# Download and install FLauncher
echo "Installing FLauncher..."
wget -q https://gitlab.com/flauncher/flauncher/-/releases/0.18.0/downloads/flauncher-0.18.0.apk
adb install flauncher-0.18.0.apk && echo -e "${GREEN}FLauncher installed${NC}" || echo -e "${RED}FLauncher installation failed${NC}"

# Optional Emby installation
if ask_yes_no "Do you want to install Emby?"; then
    echo "Installing Emby..."
    wget -q EMBY_HERE -O Emby.apk
    adb install Emby.apk && echo -e "${GREEN}Emby installed${NC}" || echo -e "${RED}Emby installation failed${NC}"
fi

# IPTV app selection
echo "Choose an IPTV app to install:"
echo "1) IPTV Smarters"
echo "2) Tivimate"
echo "3) None"
read -p "Enter your choice (1-3): " iptv_choice
case $iptv_choice in
    1)
        echo "Installing IPTV Smarters..."
        wget -q SMARTERS_HERE
        adb install sm.apk && echo -e "${GREEN}IPTV Smarters installed${NC}" || echo -e "${RED}IPTV Smarters installation failed${NC}"
        ;;
    2)
        echo "Installing Tivimate..."
        wget -q https://files.tivimate.com/tivimate.apk
        adb install tivimate.apk && echo -e "${GREEN}Tivimate installed${NC}" || echo -e "${RED}Tivimate installation failed${NC}"
        ;;
    3)
        echo "Skipping IPTV app installation."
        ;;
    *)
        echo "Invalid choice, skipping IPTV installation."
        ;;
esac

# Sign out Google account (requires email input)
echo "Enter the Google account email to sign out (leave blank to skip):"
read -r EMAIL
if [ -n "$EMAIL" ]; then
    echo "Signing out $EMAIL..."
    adb shell am broadcast -a android.intent.action.MASTER_CLEAR_ACCOUNT -n com.android.settings/.SettingsReceiver --es account "$EMAIL"
fi

# Final disables
echo "Applying final tweaks..."
adb shell pm disable-user --user 0 com.google.android.apps.tv.launcherx
adb shell pm disable-user --user 0 com.google.android.tungsten.setupwraith

# Clean up downloaded files
echo "Cleaning up..."
rm -f flauncher-0.18.0.apk Emby.apk sm.apk tivimate.apk

echo -e "${GREEN}Script completed! Reboot your TV to apply changes.${NC}"
echo "Run 'adb reboot' if you want to reboot now."
