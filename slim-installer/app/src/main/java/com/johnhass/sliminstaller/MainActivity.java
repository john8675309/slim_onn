package com.johnhass.sliminstaller;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONObject;

import java.io.File;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity implements InstallResultReceiver.Listener {

    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());

    private TextView status;
    private TextView log;
    private ScrollView logScroll;
    private LinearLayout appList;

    private List<Catalog.AppSpec> apps;
    private PrivilegedOps ops;
    private Installer installer;

    /** Last known privileged state, so the quiet re-check can spot a change. */
    private Boolean lastAvailable;
    private boolean resumedOnce;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        status = findViewById(R.id.status);
        log = findViewById(R.id.log);
        logScroll = findViewById(R.id.logScroll);
        appList = findViewById(R.id.appList);

        installer = new Installer(this);
        InstallResultReceiver.listener = this;

        apps = Catalog.apps();

        // Offer Shizuku by default only when it is missing -- it is what
        // unlocks the debloat, and a prompted install of it needs no privilege,
        // so this is the one bootstrap the app can perform for itself.
        for (Catalog.AppSpec app : apps) {
            if (Catalog.SHIZUKU_PACKAGE.equals(app.packageName)) {
                app.selected = !isInstalled(Catalog.SHIZUKU_PACKAGE);
            }
        }

        for (final Catalog.AppSpec app : apps) {
            CheckBox box = new CheckBox(this);
            box.setText(app.display());
            box.setChecked(app.selected);
            box.setFocusable(true);
            box.setOnCheckedChangeListener((v, checked) -> app.selected = checked);
            app.selected = box.isChecked();
            box.setTag(app.id);
            appList.addView(box);
        }

        ((Button) findViewById(R.id.installButton))
                .setOnClickListener(v -> worker.execute(this::doInstall));
        ((Button) findViewById(R.id.debloatButton))
                .setOnClickListener(v -> worker.execute(this::doDebloat));
        ((Button) findViewById(R.id.wirelessDebugButton))
                .setOnClickListener(v -> openWirelessDebugging());
        ((Button) findViewById(R.id.openShizukuButton))
                .setOnClickListener(v -> openShizuku());
        ((Button) findViewById(R.id.recheckButton))
                .setOnClickListener(v -> worker.execute(this::refreshPrivilege));
        ((Button) findViewById(R.id.unknownSourcesButton))
                .setOnClickListener(v -> openUnknownSources());

        append("Slim Installer");
        append("ABI: " + Build.SUPPORTED_ABIS[0] + "  SDK: " + Build.VERSION.SDK_INT);
        append("Emby build for this device: " + Catalog.embyAbi());
        append("");
        worker.execute(this::refreshPrivilege);
        worker.execute(this::resolveManifests);
    }

    @Override
    protected void onResume() {
        super.onResume();
        // onCreate already kicks off the first check; from then on, coming back
        // to the app usually means the user just started Shizuku, so re-check
        // without making them press the button.
        if (!resumedOnce) {
            resumedOnce = true;
            return;
        }
        worker.execute(() -> refreshPrivilege(false));
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (InstallResultReceiver.listener == this) {
            InstallResultReceiver.listener = null;
        }
        worker.shutdownNow();
    }

    // ------------------------------------------------------------ privilege --

    private void refreshPrivilege() {
        refreshPrivilege(true);
    }

    /**
     * Re-reads whether a privileged backend is usable.
     *
     * @param verbose when false, only reports if the answer changed -- the
     *                automatic check on resume would otherwise repeat the same
     *                paragraph every time the user comes back to the app
     */
    private void refreshPrivilege(boolean verbose) {
        PrivilegedOps candidate = new ShizukuOps();
        boolean available = candidate.isAvailable() && candidate.ensurePermission();
        ops = available ? candidate : null;

        boolean changed = lastAvailable == null || lastAvailable != available;
        lastAvailable = available;
        if (!verbose && !changed) {
            return;
        }

        if (available) {
            setStatus("Shizuku connected: silent install + debloat");
            append("[shizuku] connected, running as shell");
            try {
                PrivilegedOps.Result id = candidate.exec("id", "-u");
                append("[shizuku] uid=" + id.output.trim());
            } catch (Exception e) {
                append("[shizuku] uid check failed: " + e);
            }
        } else if (candidate.isAvailable()) {
            setStatus("Shizuku found: not authorised yet");
            append("[shizuku] present but not authorised - grant it, then re-check");
        } else {
            setStatus("No Shizuku: installs prompt, no debloat");
            append("[shizuku] not running");
            append("  Debloat needs DELETE_PACKAGES and");
            append("  CHANGE_COMPONENT_ENABLED_STATE, both signature|privileged,");
            append("  so no sideloaded app can hold them.");
            append("");
            // Be explicit that this app cannot do the starting. Starting the
            // server means running a process as shell, which is the very thing
            // it lacks; Shizuku does it itself with its bundled adb client,
            // paired against this device's own Wireless Debugging.
            append("  This app cannot start Shizuku for you: starting it means");
            append("  running a process as shell, which is exactly what it has");
            append("  no way to do. Two things can, though:");
            append("");
            append("  With a PC: adb shell already runs as shell, so no pairing");
            append("  is needed. Run start-shizuku.sh from the slim_onn repo,");
            append("  or the starter directly over adb.");
            append("");
            append("  Without a PC: Shizuku reaches the device from itself, and");
            append("  that is the only case needing Wireless Debugging.");
            append("   1. Wireless debugging settings -> turn it on"
                    + (wirelessDebuggingOn() ? "  (already on)" : "  (currently off)"));
            append("   2. Open Shizuku -> Pairing, then Start");
            append("");
            append("  Either way, come back here; it reconnects on its own.");
        }
        append("");
    }

    // ------------------------------------------------------------- manifests --

    /** Fills in anything described by a manifest rather than a fixed URL. */
    private void resolveManifests() {
        for (Catalog.AppSpec app : apps) {
            if (app.manifestUrl == null) {
                continue;
            }
            try {
                append("[manifest] " + app.label + " <- " + app.manifestUrl);
                JSONObject json = Net.getJson(app.manifestUrl);
                app.url = json.optString("apkUrl", null);
                app.sha256 = json.optString("sha256", null);
                app.versionName = json.optString("versionName", null);
                app.minSdk = json.optInt("minSdk", 0);

                if (app.url == null) {
                    append("[manifest] " + app.label + ": no apkUrl, skipping");
                    continue;
                }
                append("[manifest] " + app.label + " " + app.versionName
                        + " (minSdk " + app.minSdk + ")");
                if (app.minSdk > Build.VERSION.SDK_INT) {
                    append("[manifest] " + app.label + " needs SDK " + app.minSdk
                            + ", device is " + Build.VERSION.SDK_INT);
                    app.selected = false;
                }
                ui.post(this::relabel);
            } catch (Exception e) {
                append("[manifest] " + app.label + " failed: " + e);
            }
        }
        append("");
    }

    private void relabel() {
        for (int i = 0; i < appList.getChildCount(); i++) {
            View child = appList.getChildAt(i);
            if (!(child instanceof CheckBox)) {
                continue;
            }
            for (Catalog.AppSpec app : apps) {
                if (app.id.equals(child.getTag())) {
                    ((CheckBox) child).setText(app.display());
                    ((CheckBox) child).setChecked(app.selected);
                }
            }
        }
    }

    // --------------------------------------------------------------- install --

    private void doInstall() {
        File dir = new File(getFilesDir(), "apk");
        if (!dir.exists() && !dir.mkdirs()) {
            append("[error] cannot create " + dir);
            return;
        }

        boolean any = false;
        for (Catalog.AppSpec app : apps) {
            if (!app.selected) {
                continue;
            }
            any = true;
            if (app.url == null) {
                append("[skip] " + app.label + ": no download URL");
                continue;
            }

            File dest = new File(dir, app.fileName());
            try {
                append("[get] " + app.label);
                final long[] lastPct = {-1};
                String digest = Net.download(app.url, dest, (done, total) -> {
                    if (total <= 0) {
                        return;
                    }
                    long pct = done * 100 / total;
                    if (pct != lastPct[0] && pct % 25 == 0) {
                        lastPct[0] = pct;
                        append("  " + pct + "%  (" + (done / 1024 / 1024) + " MB)");
                    }
                });

                if (app.sha256 != null && !app.sha256.equalsIgnoreCase(digest)) {
                    append("[bad] " + app.label + " checksum mismatch, discarding");
                    append("  expected " + app.sha256);
                    append("  actual   " + digest);
                    dest.delete();
                    continue;
                }
                if (app.sha256 != null) {
                    append("  sha256 ok");
                }

                install(app, dest);
            } catch (Exception e) {
                append("[fail] " + app.label + ": " + e);
            } finally {
                // The APKs are large; do not leave them filling internal storage.
                if (ops != null) {
                    dest.delete();
                }
            }
        }
        if (!any) {
            append("[install] nothing selected");
        }

        append("");
    }

    /**
     * Installing Shizuku is not the same as having it running, and the
     * difference is invisible from the log otherwise.
     *
     * <p>Called once an install has actually finished. Checking right after the
     * session is committed would be too early: a prompted install has not
     * happened yet at that point, so the package would still look absent.
     */
    private void noteShizukuNeedsStarting(String label) {
        if (ops != null) {
            return;
        }
        for (Catalog.AppSpec app : apps) {
            if (app.label.equals(label)
                    && Catalog.SHIZUKU_PACKAGE.equals(app.packageName)) {
                append("");
                append("[next] Shizuku is installed but not running.");
                append("  Open it, start it from Wireless Debugging,");
                append("  then press Re-check Shizuku here to unlock the debloat.");
                return;
            }
        }
    }

    private void install(Catalog.AppSpec app, File apk) throws Exception {
        if (ops != null) {
            String error = installer.installPrivileged(ops, apk, app.packageName);
            if (error == null) {
                append("[ok] " + app.label + " installed");
                noteShizukuNeedsStarting(app.label);
            } else {
                append("[fail] " + app.label + ": " + error);
            }
        } else {
            append("[prompt] " + app.label + " - confirm on screen");
            installer.installWithPrompt(apk, app.label);
        }
    }

    @Override
    public void onInstallResult(String label, boolean success, String message) {
        append(success ? "[ok] " + label + " installed"
                : "[fail] " + label + ": " + message);
        if (success) {
            noteShizukuNeedsStarting(label);
        }
    }

    // --------------------------------------------------------------- debloat --

    private void doDebloat() {
        if (ops == null) {
            append("[debloat] unavailable without Shizuku");
            append("  An app uid gets SecurityException for pm disable-user,");
            append("  and cannot write /data/local/tmp either.");
            append("");
            return;
        }

        Catalog.Debloat plan = Catalog.loadDebloat(this);
        append("[debloat] list from " + plan.source);
        if (plan.isEmpty()) {
            // An empty list and a clean device look identical in the output, so
            // say plainly that nothing was attempted.
            append("[debloat] no list available, nothing attempted");
            append("");
            return;
        }

        int removed = 0;
        int absent = 0;
        int failed = 0;
        for (String pkg : plan.bloat) {
            try {
                if (!isInstalled(pkg)) {
                    absent++;
                    continue;
                }
                PrivilegedOps.Result r = ops.exec("pm", "uninstall", "-k", "--user", "0", pkg);
                if (r.ok() && r.output.contains("Success")) {
                    append("[gone] " + pkg);
                    removed++;
                } else {
                    append("[fail] " + pkg + ": " + r);
                    failed++;
                }
            } catch (Exception e) {
                append("[fail] " + pkg + ": " + e);
                failed++;
            }
        }
        append("[debloat] " + removed + " removed, " + absent + " absent, " + failed + " failed");

        // Disabling the stock launcher with nothing to replace it leaves the TV
        // with no home screen, so confirm the replacement is there first.
        if (plan.launcherReplacement == null || plan.launcherReplacement.isEmpty()) {
            append("[skip] no launcherReplacement in the manifest");
            append("");
            return;
        }
        if (!isInstalled(plan.launcherReplacement)) {
            append("[skip] launcher still enabled: " + plan.launcherReplacement
                    + " is not installed");
            append("");
            return;
        }
        for (String pkg : plan.disable) {
            try {
                if (!isInstalled(pkg)) {
                    continue;
                }
                PrivilegedOps.Result r = ops.exec("pm", "disable-user", "--user", "0", pkg);
                append(r.ok() ? "[off] " + pkg : "[fail] " + pkg + ": " + r);
            } catch (Exception e) {
                append("[fail] " + pkg + ": " + e);
            }
        }
        append("");
    }

    /**
     * Whether a package is installed for this user.
     *
     * <p>Asks the shell when one is available, because that view is
     * authoritative. PackageManager is subject to package visibility filtering
     * on Android 11+, and getting a false "not installed" here would quietly
     * skip the whole debloat.
     */
    private boolean isInstalled(String pkg) {
        if (pkg == null) {
            return false;
        }
        if (ops != null) {
            try {
                PrivilegedOps.Result r = ops.exec("pm", "path", pkg);
                return r.ok() && r.output.contains("package:");
            } catch (Exception e) {
                // Fall through to PackageManager.
            }
        }
        try {
            getPackageManager().getPackageInfo(pkg, 0);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    // ------------------------------------------------------------------- ui --

    /**
     * Launches the Shizuku app.
     *
     * <p>Worth a button of its own: Shizuku declares only a plain
     * CATEGORY_LAUNCHER entry and no LEANBACK_LAUNCHER one, so it never appears
     * on an Android TV home screen. Without this there is no obvious way to
     * reach it on a TV after installing it.
     */
    private void openShizuku() {
        if (!isInstalled(Catalog.SHIZUKU_PACKAGE)) {
            append("[shizuku] not installed - tick it above and install it first");
            return;
        }
        Intent intent = getPackageManager().getLaunchIntentForPackage(Catalog.SHIZUKU_PACKAGE);
        if (intent == null) {
            // No launcher entry resolved, so address the activity directly.
            intent = new Intent(Intent.ACTION_MAIN)
                    .setClassName(Catalog.SHIZUKU_PACKAGE, "moe.shizuku.manager.MainActivity");
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(intent);
            append("[shizuku] opened - start it, then come back");
        } catch (Exception e) {
            append("[shizuku] could not open it: " + e);
        }
    }

    /**
     * Whether Wireless Debugging is switched on.
     *
     * <p>Readable by any app; only writing it is restricted, so the app can
     * report the state but cannot change it.
     */
    private boolean wirelessDebuggingOn() {
        try {
            return Settings.Global.getInt(getContentResolver(), "adb_wifi_enabled", 0) == 1;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Jumps to Developer options, where Wireless Debugging lives.
     *
     * <p>The app cannot switch it on itself -- WRITE_SECURE_SETTINGS is
     * signature|privileged -- and finding this screen with a remote is
     * genuinely tedious, so the least it can do is go straight there.
     */
    private void openWirelessDebugging() {
        try {
            startActivity(new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            append("[adb] Developer options opened - turn on Wireless debugging");
        } catch (Exception e) {
            append("[adb] no developer options screen on this device: " + e);
            append("  Settings > System > About > tap Build several times first.");
        }
    }

    private void openUnknownSources() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            append("[info] not needed below Android 8");
            return;
        }
        if (getPackageManager().canRequestPackageInstalls()) {
            append("[info] this app may already install packages");
        }
        try {
            startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + getPackageName()))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (Exception e) {
            // Plenty of TV builds ship no such screen.
            append("[info] no unknown-sources screen on this device: " + e);
        }
    }

    private void setStatus(final String text) {
        ui.post(() -> status.setText(text));
    }

    private void append(final String line) {
        ui.post(() -> {
            log.append(line);
            log.append("\n");
            logScroll.post(() -> logScroll.fullScroll(View.FOCUS_DOWN));
        });
    }
}
