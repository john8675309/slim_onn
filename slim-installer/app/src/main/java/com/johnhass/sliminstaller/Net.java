package com.johnhass.sliminstaller;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;

/**
 * Downloads, with a digest check.
 *
 * <p>This is the piece the shell scripts cannot have: Android ships no curl, no
 * wget and no TLS libraries, so a script on the device can never fetch its own
 * payload. An app gets HTTPS for free.
 */
public final class Net {

    /** Redirect limit, so a misconfigured host cannot loop forever. */
    private static final int MAX_REDIRECTS = 5;

    public interface Progress {
        void onProgress(long done, long total);
    }

    private Net() {
    }

    public static JSONObject getJson(String url) throws Exception {
        HttpURLConnection conn = open(url);
        try (InputStream in = conn.getInputStream()) {
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int n;
            while ((n = in.read(chunk)) > 0) {
                buf.write(chunk, 0, n);
            }
            return new JSONObject(buf.toString("UTF-8"));
        } finally {
            conn.disconnect();
        }
    }

    /**
     * Fetches to {@code dest} and returns the SHA-256 of what arrived. The
     * digest is computed while streaming, so the file is never read twice.
     */
    public static String download(String url, File dest, Progress progress) throws Exception {
        HttpURLConnection conn = open(url);
        try {
            long total = conn.getContentLengthLong();
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            long done = 0;
            try (InputStream in = conn.getInputStream();
                 OutputStream out = new FileOutputStream(dest)) {
                byte[] chunk = new byte[64 * 1024];
                int n;
                while ((n = in.read(chunk)) > 0) {
                    out.write(chunk, 0, n);
                    digest.update(chunk, 0, n);
                    done += n;
                    if (progress != null) {
                        progress.onProgress(done, total);
                    }
                }
            }
            return hex(digest.digest());
        } finally {
            conn.disconnect();
        }
    }

    /**
     * Opens a URL, following redirects by hand.
     *
     * <p>HttpURLConnection refuses to follow a redirect that crosses protocols,
     * and both GitHub release assets and the raw.githubusercontent hop do
     * exactly that, so the automatic handling is not enough on its own.
     */
    private static HttpURLConnection open(String url) throws IOException {
        String current = url;
        for (int i = 0; i < MAX_REDIRECTS; i++) {
            HttpURLConnection conn = (HttpURLConnection) new URL(current).openConnection();
            conn.setConnectTimeout(20000);
            conn.setReadTimeout(60000);
            conn.setInstanceFollowRedirects(false);
            conn.setRequestProperty("User-Agent", "slim-installer");
            int code = conn.getResponseCode();
            if (code == HttpURLConnection.HTTP_MOVED_PERM
                    || code == HttpURLConnection.HTTP_MOVED_TEMP
                    || code == HttpURLConnection.HTTP_SEE_OTHER
                    || code == 307
                    || code == 308) {
                String next = conn.getHeaderField("Location");
                conn.disconnect();
                if (next == null) {
                    throw new IOException("redirect with no Location from " + current);
                }
                current = new URL(new URL(current), next).toString();
                continue;
            }
            if (code / 100 != 2) {
                conn.disconnect();
                throw new IOException("HTTP " + code + " for " + current);
            }
            return conn;
        }
        throw new IOException("too many redirects for " + url);
    }

    private static String hex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(Character.forDigit((b >> 4) & 0xf, 16));
            sb.append(Character.forDigit(b & 0xf, 16));
        }
        return sb.toString();
    }
}
