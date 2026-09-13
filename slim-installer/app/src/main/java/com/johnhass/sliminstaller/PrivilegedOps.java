package com.johnhass.sliminstaller;

import java.io.InputStream;
import java.io.OutputStream;

/**
 * A way to run commands as shell (uid 2000).
 *
 * <p>This is the whole reason the app needs a back door. Removing preinstalled
 * apps needs {@code DELETE_PACKAGES} and {@code CHANGE_COMPONENT_ENABLED_STATE},
 * both declared {@code signature|privileged} by the platform, so a sideloaded
 * APK can never hold them no matter how it is built -- a debug build grants
 * nothing extra here. The only route for an ordinary app is to borrow a
 * shell-uid process from something like Shizuku.
 *
 * <p>When nothing is available the app still works; it just falls back to
 * prompting the user for each install and cannot debloat.
 */
public interface PrivilegedOps {

    /** Human-readable name of the backend, for the log. */
    String name();

    /** True when commands can actually be run right now. */
    boolean isAvailable();

    /**
     * Asks the backend for permission if it needs it.
     *
     * @return true when permission is already held or was granted
     */
    boolean ensurePermission();

    /** Runs a command to completion and returns its exit code and output. */
    Result exec(String... command) throws Exception;

    /**
     * Starts a command and hands back its streams, so a caller can pipe an APK
     * into {@code pm install -S <size> -} without ever giving the platform a
     * file path it is not allowed to read.
     */
    Handle start(String... command) throws Exception;

    /** Result of a finished command. */
    final class Result {
        public final int exitCode;
        public final String output;

        public Result(int exitCode, String output) {
            this.exitCode = exitCode;
            this.output = output;
        }

        public boolean ok() {
            return exitCode == 0;
        }

        @Override
        public String toString() {
            return "exit=" + exitCode + (output.isEmpty() ? "" : " " + output.trim());
        }
    }

    /** A running command. */
    interface Handle {
        OutputStream stdin();

        InputStream stdout();

        InputStream stderr();

        int waitFor() throws InterruptedException;
    }
}
