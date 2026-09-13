package com.johnhass.sliminstaller;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.os.Build;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Installs an APK, by whichever route is actually open.
 *
 * <p>Both routes stream the bytes rather than handing over a path. That is not
 * a style choice: {@code pm install <path>} runs inside system_server, which
 * SELinux forbids from reading the {@code /sdcard} fuse mount, and it cannot
 * read this app's private directory either. Streaming sidesteps the whole
 * problem -- which is also why the APKs never need staging in
 * {@code /data/local/tmp} the way the shell script has to.
 */
public final class Installer {

    /** Matches InstallResultReceiver's filter. */
    static final String ACTION_RESULT = "com.johnhass.sliminstaller.INSTALL_RESULT";

    private final Context context;

    public Installer(Context context) {
        this.context = context.getApplicationContext();
    }

    /**
     * Silent install through a shell-uid process.
     *
     * <p>Pipes the APK into {@code pm install -S <size> -}, so no file path is
     * ever exposed to the platform.
     */
    public String installPrivileged(PrivilegedOps ops, File apk, String packageName)
            throws Exception {
        long size = apk.length();
        PrivilegedOps.Handle handle = ops.start(
                "pm", "install", "-r", "-t", "-S", String.valueOf(size));

        Exception pipeFailure = null;
        try (OutputStream out = handle.stdin(); InputStream in = new FileInputStream(apk)) {
            byte[] chunk = new byte[64 * 1024];
            int n;
            while ((n = in.read(chunk)) > 0) {
                out.write(chunk, 0, n);
            }
            out.flush();
        } catch (Exception e) {
            // Report what pm said rather than this stream error: when pm rejects
            // the session it closes the pipe, and the broken-pipe exception is
            // far less informative than the reason on stderr.
            pipeFailure = e;
        }

        String out = readAll(handle.stdout());
        String err = readAll(handle.stderr());
        int code = handle.waitFor();
        String message = (out + " " + err).trim();

        if (code == 0 && message.contains("Success")) {
            return null;
        }
        if (message.isEmpty() && pipeFailure != null) {
            message = pipeFailure.toString();
        }
        return message.isEmpty() ? "pm exited " + code : message;
    }

    /**
     * Install via PackageInstaller, which shows a confirmation the user has to
     * accept. This is all an unprivileged app can do, and it needs the
     * "install unknown apps" toggle for this app.
     */
    public void installWithPrompt(File apk, String label) throws Exception {
        PackageInstaller installer = context.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params =
                new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            params.setInstallLocation(android.content.pm.PackageInfo.INSTALL_LOCATION_AUTO);
        }

        int sessionId = installer.createSession(params);
        try (PackageInstaller.Session session = installer.openSession(sessionId)) {
            try (OutputStream out = session.openWrite(apk.getName(), 0, apk.length());
                 InputStream in = new FileInputStream(apk)) {
                byte[] chunk = new byte[64 * 1024];
                int n;
                while ((n = in.read(chunk)) > 0) {
                    out.write(chunk, 0, n);
                }
                session.fsync(out);
            }

            // Explicit component on purpose. A manifest-declared receiver with
            // no <intent-filter> never matches an implicit broadcast, even one
            // narrowed with setPackage(), so addressing the class directly is
            // what actually gets the result delivered.
            Intent intent = new Intent(context, InstallResultReceiver.class)
                    .setAction(ACTION_RESULT)
                    .putExtra(InstallResultReceiver.EXTRA_LABEL, label);
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                flags |= PendingIntent.FLAG_MUTABLE;
            }
            PendingIntent pending =
                    PendingIntent.getBroadcast(context, sessionId, intent, flags);
            session.commit(pending.getIntentSender());
        }
    }

    private static String readAll(InputStream in) throws Exception {
        StringBuilder sb = new StringBuilder();
        byte[] chunk = new byte[8192];
        int n;
        while ((n = in.read(chunk)) > 0) {
            sb.append(new String(chunk, 0, n, "UTF-8"));
        }
        return sb.toString();
    }
}
