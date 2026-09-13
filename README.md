# Slim Up the ONN stick

Debloats an Android TV / Google TV device over ADB, installs a replacement
launcher and your IPTV app of choice.

There are two ways to run it.

## 1. Everything from the PC

```sh
./slim.sh
```

Prompts for the TV's IP, then does all the work from your PC with `adb install`.

## 2. Run it on the device itself

Android ships no `curl`, no `wget`, and no TLS libraries, so **the device cannot
download anything by itself**. The work is split in two: the PC downloads, the
device installs.

```sh
./slim-push.sh
```

This downloads the APKs into `slim-payload/`, pushes them plus `slim-device.sh`
to `/data/local/tmp/slim`, and runs the device script over ADB.

Once the payload is on the device, everything else is local to it. Re-running
costs no downloads:

```sh
adb shell sh /data/local/tmp/slim/slim-device.sh
```

Useful after a factory reset, or to re-apply the debloat without pulling a few
hundred MB again. To have it open the account-removal screen at the end:

```sh
adb shell "SLIM_OPEN_ACCOUNTS=1 sh /data/local/tmp/slim/slim-device.sh"
```

### What the device script does

* Uninstalls the bloat list for user 0 (with `-k`, so `pm install-existing
  <pkg>` puts one back).
* Installs every `.apk` sitting next to it, verifying each against the
  `sha256sums` sidecar written by `slim-push.sh`.
* Disables the stock launcher — but **only** once FLauncher is confirmed
  installed, since disabling it otherwise leaves the TV with no home screen.
* Lists signed-in accounts, and optionally opens the removal screen.

It is written for mksh, the Android system shell. Note that mksh's `read` has
no `-p` flag there (it means "read from coprocess"), so prompts use `printf`.

## 3. No PC at all

Possible, but it hinges on one thing: **the debloat commands need shell uid
(2000)**. A terminal app runs as its own app uid and is refused —
`pm disable-user` throws `SecurityException: Attempt to change component
state`, and an app uid cannot even write to `/data/local/tmp`. Installing APKs
alone doesn't need this (unknown-sources sideloading covers that); removing the
preinstalled apps does.

To get a shell-uid session on the device itself, use **Shizuku** (`rish`) or
**LADB**. Both pair against the device's own Wireless Debugging over loopback,
which is what replaces the PC. Requires Android 11+; this repo has been
exercised on Android 16 / SDK 36.

Then:

1. Enable Developer options → Wireless debugging.
2. Sideload Shizuku or LADB, and start it via wireless-debugging pairing.
3. Download the APKs plus `slim-device.sh` with any downloader app — they land
   in `/sdcard/Download`.
4. From the shell-uid terminal: `sh /sdcard/Download/slim-device.sh`

The script detects that it is running from shared storage and stages the APKs
through `/data/local/tmp` automatically, because `pm install` runs inside
system_server, which SELinux forbids from reading the `/sdcard` fuse mount
("Error: Can't open file"). `/sdcard` is also mounted noexec, so invoke it as
`sh script.sh` rather than `./script.sh`.

Note the device still has no `curl`, `wget`, or TLS, so the downloading has to
be done by an app — the script cannot fetch anything itself.

## The debloat list

`slim.json` is the single source of truth for what gets removed. `slim.sh`,
`slim-device.sh` and the Slim Installer app all read it, so the list is edited
in exactly one place.

```json
{
  "launcherReplacement": "me.efesser.flauncher",
  "bloat": ["com.netflix.ninja", "..."],
  "disable": ["com.google.android.apps.tv.launcherx", "..."]
}
```

It is served from this repo:

```
https://raw.githubusercontent.com/john8675309/slim_onn/main/slim.json
```

so editing `slim.json` and pushing is all it takes to change the list
everywhere — no web hosting needed. Point `SLIM_MANIFEST_URL` at somewhere else
to override it.

How each consumer gets it:

| | Source | Fallback |
|---|---|---|
| `slim.sh` | fetches the URL | `slim.json` beside the script |
| `slim-device.sh` | `slim.json` in the payload | none — the device has no TLS |
| Installer app | fetches the URL | copy bundled in the APK's assets |

`slim-push.sh` puts the manifest in the payload, since the device cannot fetch
it. If the list is ever missing or empty, every consumer says so and skips the
debloat rather than reporting a quiet "0 removed" — a silent empty list is
indistinguishable from an already-clean device.

## Choosing the device

Both scripts pin a single device for the whole run and print which one before
touching it. A plain `adb shell` just uses whatever device happens to be
attached, so an emulator running alongside the TV is enough to debloat the
wrong one.

With one device attached it is used automatically. With several, you get a
numbered list — or skip the prompt:

```sh
SLIM_SERIAL=emulator-5554 ./slim-push.sh
```

`ANDROID_SERIAL` works too. To re-run the device script by hand, pass `-s`:

```sh
adb -s emulator-5554 shell sh /data/local/tmp/slim/slim-device.sh
```

## Notes

* **Removing a Google account cannot be scripted.** `AccountManager` only lets
  the account's own authenticator or the user remove one, and ADB runs as uid
  2000 with no root. The scripts open the accounts screen; you finish with the
  remote.
* **JTV** is resolved through `https://johnhass.com/jtv.json`, so the installer
  always picks up the current release and verifies its `sha256`.
* **Emby** ships per-ABI builds; the ABI is read off the device with
  `getprop ro.product.cpu.abilist`.
