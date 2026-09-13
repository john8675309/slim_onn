package com.johnhass.sliminstaller;

import android.content.pm.PackageManager;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Method;

import rikka.shizuku.Shizuku;

/**
 * Runs commands through Shizuku, which hosts a process running as shell (uid
 * 2000) after being started from the device's own Wireless Debugging.
 *
 * <p>{@code Shizuku.newProcess} is not part of the library's supported surface,
 * so it is called reflectively -- that keeps a signature change in the Shizuku
 * API from breaking the build, and lets {@link #isAvailable()} simply report
 * false if the method ever disappears.
 */
public final class ShizukuOps implements PrivilegedOps {

    private static final int SHIZUKU_PERMISSION_REQUEST = 4242;

    @Override
    public String name() {
        return "Shizuku";
    }

    @Override
    public boolean isAvailable() {
        try {
            // pingBinder() throws if the Shizuku classes are present but the
            // service was never started.
            if (!Shizuku.pingBinder()) {
                return false;
            }
            return newProcessMethod() != null;
        } catch (Throwable t) {
            return false;
        }
    }

    @Override
    public boolean ensurePermission() {
        try {
            if (Shizuku.isPreV11()) {
                return false;
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                return true;
            }
            if (Shizuku.shouldShowRequestPermissionRationale()) {
                return false;
            }
            // Asynchronous: the user answers in Shizuku's own dialog, so this
            // returns false now and the next run picks up the granted state.
            Shizuku.requestPermission(SHIZUKU_PERMISSION_REQUEST);
            return false;
        } catch (Throwable t) {
            return false;
        }
    }

    @Override
    public Result exec(String... command) throws Exception {
        Handle handle = start(command);
        handle.stdin().close();
        String out = readAll(handle.stdout());
        String err = readAll(handle.stderr());
        int code = handle.waitFor();
        String combined = (out + (err.isEmpty() ? "" : "\n" + err)).trim();
        return new Result(code, combined);
    }

    @Override
    public Handle start(String... command) throws Exception {
        Method newProcess = newProcessMethod();
        if (newProcess == null) {
            throw new IllegalStateException("Shizuku.newProcess is unavailable");
        }
        newProcess.setAccessible(true);
        final Object process = newProcess.invoke(null, command, null, null);
        if (process == null) {
            throw new IllegalStateException("Shizuku returned no process");
        }
        final Class<?> cls = process.getClass();
        return new Handle() {
            @Override
            public OutputStream stdin() {
                return (OutputStream) call(cls, process, "getOutputStream");
            }

            @Override
            public InputStream stdout() {
                return (InputStream) call(cls, process, "getInputStream");
            }

            @Override
            public InputStream stderr() {
                return (InputStream) call(cls, process, "getErrorStream");
            }

            @Override
            public int waitFor() {
                Object v = call(cls, process, "waitFor");
                return v instanceof Integer ? (Integer) v : -1;
            }
        };
    }

    private static Object call(Class<?> cls, Object target, String method) {
        try {
            Method m = cls.getMethod(method);
            m.setAccessible(true);
            return m.invoke(target);
        } catch (Exception e) {
            throw new RuntimeException("Shizuku process." + method + " failed", e);
        }
    }

    private static Method newProcessMethod() {
        try {
            Method m = Shizuku.class.getDeclaredMethod(
                    "newProcess", String[].class, String[].class, String.class);
            m.setAccessible(true);
            return m;
        } catch (Throwable t) {
            return null;
        }
    }

    private static String readAll(InputStream in) throws Exception {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        int n;
        while ((n = in.read(chunk)) > 0) {
            buf.write(chunk, 0, n);
        }
        return buf.toString("UTF-8");
    }
}
