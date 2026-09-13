# Slim Installer

An on-device installer for the same payload `slim-device.sh` handles, as an
Android TV app. Solves the one thing a shell script on Android cannot do:
Android ships no `curl`, no `wget`, and no TLS libraries, so a script can never
fetch its own payload. An app gets HTTPS for free.

## What it can and cannot do

| | Unprivileged | With Shizuku |
|---|---|---|
| Download APKs, verify sha256 | yes | yes |
| Install | one confirmation dialog each | silent |
| Remove preinstalled apps | **no** | yes |
| Disable stock launcher | **no** | yes |

The debloat gap is not a missing feature, it is the platform. Those operations
need `DELETE_PACKAGES` and `CHANGE_COMPONENT_ENABLED_STATE`, both declared
`signature|privileged`, so only platform-signed or `/system/priv-app` code can
hold them. **Building the app as a debug build changes nothing here** —
`DEBUGGABLE` only lets adb `run-as` the app or attach a debugger. An ordinary
app uid gets `SecurityException: Attempt to change component state` and cannot
even write to `/data/local/tmp`.

So the app borrows a shell-uid process from [Shizuku], which is started from the
device's own Wireless Debugging — no PC. Without it the app still downloads and
installs; it just prompts per app and leaves the bloat alone.

[Shizuku]: https://shizuku.rikka.app/

## Build

```sh
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Needs a `local.properties` with `sdk.dir=/path/to/Android/Sdk` (not committed).

## Using it

1. Launch **Slim Installer** from the TV home screen.
2. *Allow installs from this app* — grants the unknown-sources appop, needed
   for prompted installs.
3. Tick the apps and press *Download and install selected*.
4. *Remove preinstalled apps* handles the debloat, Shizuku only.

**Shizuku is in the catalog**, pinned to v13.6.0 with its sha256, and is ticked
by default when it is not already installed. A prompted install needs no
privilege, so the app can bootstrap its own enabler: install Shizuku from here,
press *Open Shizuku*, start it from Wireless Debugging, and come back — the app
re-checks on its own. Installing it is not the same as running it, and the app
says so once the install lands.

*Open Shizuku* matters more than it looks on a TV: Shizuku declares only a
plain `CATEGORY_LAUNCHER` entry and no `LEANBACK_LAUNCHER` one, so it never
appears on an Android TV home screen. Without this button there is no obvious
way to reach it after installing it.

### The app cannot start the Shizuku server

Worth stating plainly, because the buttons might imply otherwise. Starting the
server means running a process as shell (uid 2000) — the exact thing the app
has no way to do. Shizuku starts it itself, using the `libadb.so` it bundles to
act as an ADB client against this device's own Wireless Debugging over
loopback. Nor can the app switch Wireless Debugging on: that needs
`WRITE_SECURE_SETTINGS`, which is `signature|privileged`. It can only *read*
the setting, which it does, to tell you whether it is already on.

Shizuku exposes no deep link for starting either — `MainActivity` is its only
exported entry point — so the pairing flow has to happen in Shizuku's own UI.

What the app does instead is remove the navigation pain, which on a TV remote
is most of the difficulty:

1. **Wireless debugging settings** — jumps straight to Developer options, and
   the log says whether Wireless Debugging is currently on or off.
2. **Open Shizuku** — the app is otherwise unreachable on a TV. Do Pairing,
   then Start, there.
3. Come back; the app re-checks on resume and reconnects on its own.

JTV is resolved through `https://johnhass.com/jtv.json` — the same contract the
shell scripts use — so it always picks up the current release and verifies the
published `sha256`. Emby is chosen per ABI from `Build.SUPPORTED_ABIS`.

## Notes on the implementation

* **Both install paths stream the APK rather than passing a path.** This is not
  a style choice. `pm install <path>` runs inside system_server, which SELinux
  forbids from reading the `/sdcard` fuse mount, and which cannot read this
  app's private directory either. Streaming into a `PackageInstaller` session,
  or into `pm install -S <size> -`, sidesteps it entirely — which is why this
  app never needs the `/data/local/tmp` staging that `slim-device.sh` does.
* **Redirects are followed by hand** in `Net`. `HttpURLConnection` will not
  follow a redirect that crosses protocols, and GitHub release assets do
  exactly that.
* **`Shizuku.newProcess` is called reflectively.** It is outside the library's
  supported surface, so reflection keeps a signature change from breaking the
  build; `isAvailable()` just reports false instead.
* The launcher is only disabled once FLauncher is confirmed installed, matching
  `slim-device.sh`. Disabling it otherwise leaves the TV with no home screen.
* **`QUERY_ALL_PACKAGES` is load-bearing, not boilerplate.** Package visibility
  filtering on Android 11+ hides every package the app does not name, so
  `getPackageInfo` reports the entire bloat list as "absent" and the debloat
  quietly does nothing while claiming success. `isInstalled()` additionally
  prefers `pm path` through the shell when Shizuku is connected, since that
  view is authoritative.
* **`moe.shizuku.manager.permission.API_V23` must be declared** or
  `Shizuku.requestPermission()` is refused with no dialog and no error.
* The `PackageInstaller` result `PendingIntent` targets the receiver by
  explicit component. A manifest receiver with no `<intent-filter>` never
  matches an implicit broadcast, even one narrowed with `setPackage()`, and the
  result — including the `STATUS_PENDING_USER_ACTION` that carries the
  confirmation dialog — is silently dropped.
* The bloat list is **not** compiled in. `Catalog.loadDebloat()` fetches
  `slim.json` from the repo and falls back to the copy in `assets/`, so this
  app, `slim.sh` and `slim-device.sh` all work from one source. The app logs
  which copy it used — a silently empty list would be indistinguishable from an
  already-clean device.

## Verified on

Android 16 (SDK 36) emulator, Shizuku 13.6.0, both modes exercised end to end:
manifest resolution, sha256-checked downloads, prompted install, silent install
through `pm install -S <size> -`, and `pm disable-user` via the shell-uid
process.
