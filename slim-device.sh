#!/system/bin/sh
#
# Runs ON the Android TV, not on your PC.
#
# Android ships no curl, no wget, and no TLS libraries, so this script cannot
# download anything. The APKs have to be pushed next to it -- use slim-push.sh
# on your PC, which downloads them and pushes this script along with them.
#
# Once the payload is on the device this script is self-contained and can be
# re-run at any time (after a factory reset, say) without a PC re-downloading
# a few hundred MB.
#
# Written for mksh, the Android system shell. Note that mksh's `read` has no
# -p flag (it means "read from coprocess" there), so prompts use printf.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DIR=$(dirname "$0")
FAILED=0

# Read one scalar field out of a JSON document.
json_field() {
    printf '%s' "$1" | tr -d '\n' \
        | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+)" \
        | sed "s/^\"$2\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"\$//"
}

# Read a flat array of strings out of a JSON document, one per line.
# No jq on Android, so this is done with grep/sed; anchoring on the key means a
# missing key yields nothing rather than garbage.
json_array() {
    body=$(printf '%s' "$1" | tr -d '\n' \
        | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\[[^]]*\]")
    [ -z "$body" ] && return 0
    printf '%s' "$body" \
        | sed 's/^[^[]*\[//; s/\]$//' \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' \
        | grep -v '^[[:space:]]*$'
}

# The debloat list lives in slim.json, pushed alongside this script. The device
# cannot fetch it -- Android has no curl, wget or TLS -- so it has to arrive as
# part of the payload.
MANIFEST_FILE="$DIR/slim.json"
BLOAT=""
DISABLE=""
LAUNCHER_REPLACEMENT=""
if [ -f "$MANIFEST_FILE" ]; then
    MANIFEST=$(cat "$MANIFEST_FILE")
    BLOAT=$(json_array "$MANIFEST" bloat)
    DISABLE=$(json_array "$MANIFEST" disable)
    LAUNCHER_REPLACEMENT=$(json_field "$MANIFEST" launcherReplacement)
fi

is_installed() {
    pm path "$1" > /dev/null 2>&1
}

# ---------------------------------------------------------------- debloat ---
echo "Removing preinstalled apps..."
# An empty list and a clean device look identical in the output, so say plainly
# that nothing was even attempted rather than reporting a cheerful zero.
if [ -z "$BLOAT" ]; then
    if [ -f "$MANIFEST_FILE" ]; then
        echo -e "  ${RED}slim.json has no usable 'bloat' list, nothing attempted${NC}"
    else
        echo -e "  ${RED}no slim.json next to this script, nothing attempted${NC}"
        echo -e "  ${RED}expected: $MANIFEST_FILE${NC}"
    fi
    FAILED=$((FAILED + 1))
fi
removed=0
skipped=0
for pkg in $BLOAT; do
    if ! is_installed "$pkg"; then
        skipped=$((skipped + 1))
        continue
    fi
    if pm uninstall -k --user 0 "$pkg" > /dev/null 2>&1; then
        echo -e "  ${GREEN}removed${NC}  $pkg"
        removed=$((removed + 1))
    else
        echo -e "  ${RED}failed${NC}   $pkg"
        FAILED=$((FAILED + 1))
    fi
done
echo "  ($removed removed, $skipped were not present)"
echo

# ---------------------------------------------------------------- installs ---
# Install every APK sitting next to this script. Keeping the payload directory
# as the source of truth means no app list has to be kept in sync here.
echo "Installing apps from the payload..."

# pm install runs inside system_server, which SELinux forbids from reading
# /sdcard (it is a fuse mount). Anything outside /data/local/tmp therefore has
# to be staged there first -- this is what lets the script also work when the
# APKs were downloaded on the device itself, into /sdcard/Download.
STAGE=""
case "$DIR" in
    /data/local/tmp*) ;;
    *)
        STAGE="/data/local/tmp/slim-stage"
        if ! mkdir -p "$STAGE" 2> /dev/null; then
            echo -e "  ${RED}cannot write $STAGE -- are you running as shell (uid 2000)?${NC}"
            echo -e "  ${RED}current uid: $(id -u). pm install cannot read $DIR directly.${NC}"
            STAGE=""
        else
            echo "  (staging via $STAGE, since $DIR is not installable directly)"
        fi
        ;;
esac

found_apk=0
for apk in "$DIR"/*.apk; do
    [ -e "$apk" ] || continue
    found_apk=1
    name=$(basename "$apk")

    # slim-push.sh writes a checksum sidecar; verify when it is there.
    if [ -f "$DIR/sha256sums" ]; then
        want=$(grep " $name\$" "$DIR/sha256sums" | cut -d' ' -f1)
        if [ -n "$want" ]; then
            got=$(sha256sum "$apk" | cut -d' ' -f1)
            if [ "$want" != "$got" ]; then
                echo -e "  ${RED}corrupt${NC}  $name (checksum mismatch, not installing)"
                FAILED=$((FAILED + 1))
                continue
            fi
        fi
    fi

    src="$apk"
    if [ -n "$STAGE" ]; then
        if ! cp "$apk" "$STAGE/$name" 2> /dev/null; then
            echo -e "  ${RED}failed${NC}    $name (could not stage it)"
            FAILED=$((FAILED + 1))
            continue
        fi
        src="$STAGE/$name"
    fi

    if pm install -r "$src" > /dev/null 2>&1; then
        echo -e "  ${GREEN}installed${NC} $name"
    else
        echo -e "  ${RED}failed${NC}    $name"
        FAILED=$((FAILED + 1))
    fi
    [ -n "$STAGE" ] && rm -f "$STAGE/$name"
done
[ -n "$STAGE" ] && rmdir "$STAGE" 2> /dev/null
[ "$found_apk" -eq 0 ] && echo -e "  ${YELLOW}no APKs in $DIR, nothing to install${NC}"
echo

# ------------------------------------------------------------ final tweaks ---
# Disabling the stock launcher with nothing to replace it leaves the TV with no
# home screen, so confirm the replacement landed first.
echo "Applying final tweaks..."
if [ -z "$LAUNCHER_REPLACEMENT" ]; then
    echo -e "  ${RED}no launcherReplacement in slim.json, leaving the launcher alone${NC}"
elif is_installed "$LAUNCHER_REPLACEMENT"; then
    for pkg in $DISABLE; do
        if ! is_installed "$pkg"; then
            continue
        fi
        if pm disable-user --user 0 "$pkg" > /dev/null 2>&1; then
            echo -e "  ${GREEN}disabled${NC} $pkg"
        else
            echo -e "  ${RED}failed${NC}   $pkg"
            FAILED=$((FAILED + 1))
        fi
    done
else
    echo -e "  ${YELLOW}skipped: $LAUNCHER_REPLACEMENT is not installed${NC}"
    echo -e "  ${YELLOW}disabling the stock launcher now would leave no home screen${NC}"
fi
echo

# ---------------------------------------------------------------- accounts ---
# An account can only be removed by its authenticator or by the user, so the
# best a shell script can do is open the screen and let the remote finish it.
ACCOUNTS=$(dumpsys account 2>/dev/null | grep -o 'name=[^,]*, type=[^}]*' | sed 's/name=/  /; s/, type=/ (/; s/$/)/')
if [ -n "$ACCOUNTS" ]; then
    echo "Signed-in accounts:"
    echo "$ACCOUNTS"
    if [ "$SLIM_OPEN_ACCOUNTS" = "1" ]; then
        echo "Opening the accounts screen -- remove it with the remote."
        am start -a android.settings.SYNC_SETTINGS > /dev/null 2>&1 \
            || am start -n com.android.tv.settings/com.google.android.tv.settings.AccountActivity > /dev/null 2>&1
    else
        echo "  (re-run with SLIM_OPEN_ACCOUNTS=1 to open the removal screen)"
    fi
else
    echo -e "${GREEN}No accounts signed in.${NC}"
fi
echo

# ----------------------------------------------------------------- summary ---
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}Done with no errors. Reboot to apply everything.${NC}"
else
    echo -e "${YELLOW}Done, but $FAILED step(s) failed. See above.${NC}"
fi
exit "$FAILED"
