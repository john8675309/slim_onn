package com.johnhass.sliminstaller;

import android.content.Context;
import android.os.Build;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

/** What the installer can fetch, and the bloat it can remove. */
public final class Catalog {

    private Catalog() {
    }

    /** One installable app. */
    public static final class AppSpec {
        public final String id;
        public final String label;
        public final String packageName;

        /** Direct download, or null when {@link #manifestUrl} supplies it. */
        public String url;

        /** A jtv.json-style manifest that names the current build. */
        public final String manifestUrl;

        /** Expected digest, from the manifest when there is one. */
        public String sha256;

        public String versionName;
        public int minSdk;

        /** Ticked in the UI. */
        public boolean selected = true;

        AppSpec(String id, String label, String packageName, String url, String manifestUrl) {
            this.id = id;
            this.label = label;
            this.packageName = packageName;
            this.url = url;
            this.manifestUrl = manifestUrl;
        }

        public String fileName() {
            return id + ".apk";
        }

        public String display() {
            return versionName == null ? label : label + " " + versionName;
        }
    }

    /**
     * Emby ships a build per ABI. Read the device's own list rather than
     * guessing: it is ordered by preference, so the first entry we have a build
     * for is the right one.
     */
    public static String embyAbi() {
        for (String abi : Build.SUPPORTED_ABIS) {
            if ("arm64-v8a".equals(abi) || "x86_64".equals(abi)) {
                return "arm64-v8a";
            }
            if ("armeabi-v7a".equals(abi) || "x86".equals(abi)) {
                return "armeabi-v7a";
            }
        }
        return "armeabi-v7a";
    }

    /** The package whose presence unlocks the privileged operations. */
    public static final String SHIZUKU_PACKAGE = "moe.shizuku.privileged.api";

    public static List<AppSpec> apps() {
        List<AppSpec> list = new ArrayList<>();

        // Listed first because it is what unlocks the debloat. Installing it is
        // the one privileged-adjacent thing this app can bootstrap on its own:
        // a prompted install needs no special rights. Starting it afterwards
        // still has to be done from Wireless Debugging.
        AppSpec shizuku = new AppSpec("shizuku", "Shizuku", SHIZUKU_PACKAGE,
                "https://github.com/RikkaApps/Shizuku/releases/download/v13.6.0/"
                        + "shizuku-v13.6.0.r1086.2650830c-release.apk",
                null);
        // Pinned release asset, so pin the digest with it.
        shizuku.sha256 = "6e273ab0e991c4e79bc8b1bbb9b9dd739ccac1a8712a541a214078886b7b790f";
        shizuku.versionName = "13.6.0";
        list.add(shizuku);

        list.add(new AppSpec("flauncher", "FLauncher", "me.efesser.flauncher",
                "https://github.com/john8675309/flauncher/releases/download/v0.1.1/flauncher-0.1.1.apk",
                null));

        list.add(new AppSpec("emby", "Emby", "com.mb.android",
                "https://github.com/MediaBrowser/Emby.Releases/raw/master/android/"
                        + "emby-android-google-" + embyAbi() + "-release.apk",
                null));

        // Resolved through the manifest, so this always picks up the current
        // release and gets a digest to check it against.
        list.add(new AppSpec("jtv", "JTV", "com.jtv.jtv",
                null,
                "https://johnhass.com/jtv.json"));

        list.add(new AppSpec("smarters", "IPTV Smarters", null,
                "https://www.johnhass.com/s.apk", null));

        list.add(new AppSpec("tivimate", "Tivimate", null,
                "https://files.tivimate.com/tivimate.apk", null));

        list.add(new AppSpec("tvbuttonmapper", "TV Button Mapper", "com.johnhass.tvbuttonmapper",
                "https://github.com/john8675309/tvbuttonmapper/releases/download/v0.1.0/"
                        + "tvbuttonmapper-v0.1.0-debug.apk",
                null));

        // FLauncher and the button mapper on by default; the rest is opt-in.
        // Shizuku is handled by the caller, which can see whether it is already
        // installed.
        for (AppSpec a : list) {
            a.selected = "flauncher".equals(a.id) || "tvbuttonmapper".equals(a.id);
        }
        return list;
    }

    /**
     * The debloat list, published rather than compiled in so that this app,
     * slim.sh and slim-device.sh all work from one source.
     *
     * <p>Falls back to the copy bundled in assets when the published manifest
     * cannot be reached, and reports which one it used -- an empty list and a
     * clean device produce identical output otherwise.
     */
    public static final class Debloat {
        public final List<String> bloat = new ArrayList<>();
        public final List<String> disable = new ArrayList<>();
        public String launcherReplacement;
        public String source;

        public boolean isEmpty() {
            return bloat.isEmpty() && disable.isEmpty();
        }
    }

    public static final String MANIFEST_URL =
            "https://raw.githubusercontent.com/john8675309/slim_onn/main/slim.json";

    public static Debloat loadDebloat(Context context) {
        Debloat d = new Debloat();
        JSONObject json = null;
        try {
            json = Net.getJson(MANIFEST_URL);
            d.source = MANIFEST_URL;
        } catch (Exception remote) {
            try (InputStream in = context.getAssets().open("slim.json")) {
                ByteArrayOutputStream buf = new ByteArrayOutputStream();
                byte[] chunk = new byte[4096];
                int n;
                while ((n = in.read(chunk)) > 0) {
                    buf.write(chunk, 0, n);
                }
                json = new JSONObject(buf.toString("UTF-8"));
                d.source = "bundled copy (" + remote + ")";
            } catch (Exception bundled) {
                d.source = "unavailable: " + bundled;
            }
        }
        if (json == null) {
            return d;
        }
        copyArray(json.optJSONArray("bloat"), d.bloat);
        copyArray(json.optJSONArray("disable"), d.disable);
        d.launcherReplacement = json.optString("launcherReplacement", null);
        return d;
    }

    private static void copyArray(JSONArray array, List<String> into) {
        if (array == null) {
            return;
        }
        for (int i = 0; i < array.length(); i++) {
            String value = array.optString(i, null);
            if (value != null && !value.isEmpty()) {
                into.add(value);
            }
        }
    }
}
