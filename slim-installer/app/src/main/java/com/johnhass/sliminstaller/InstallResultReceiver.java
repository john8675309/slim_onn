package com.johnhass.sliminstaller;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;

/**
 * Receives PackageInstaller session results.
 *
 * <p>A prompted install first comes back as {@link
 * PackageInstaller#STATUS_PENDING_USER_ACTION}, carrying the confirmation
 * dialog to launch. That is the per-app click an unprivileged installer cannot
 * avoid.
 */
public final class InstallResultReceiver extends BroadcastReceiver {

    static final String EXTRA_LABEL = "label";

    /** Set by MainActivity so results can be written into its log. */
    static volatile Listener listener;

    interface Listener {
        void onInstallResult(String label, boolean success, String message);
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1);
        String label = intent.getStringExtra(EXTRA_LABEL);
        if (label == null) {
            label = "app";
        }

        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            Intent confirm = intent.getParcelableExtra(Intent.EXTRA_INTENT);
            if (confirm != null) {
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(confirm);
            }
            return;
        }

        Listener l = listener;
        if (l == null) {
            return;
        }
        if (status == PackageInstaller.STATUS_SUCCESS) {
            l.onInstallResult(label, true, null);
        } else {
            String message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);
            l.onInstallResult(label, false, message == null ? "status " + status : message);
        }
    }
}
