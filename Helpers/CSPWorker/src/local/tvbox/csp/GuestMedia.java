package local.tvbox.csp;

import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Local media returned by playerContent, reachable only through authenticated, opaque tickets. */
final class GuestMedia {
    static final String TICKET = "_tvboxGuestMedia";
    private static final String PREFIX = "/guest-media/";
    private static final long IDLE_MS = 2 * 60 * 60 * 1000;
    private static final Set<String> REQUEST_HEADERS_TO_SKIP = new HashSet<>(Arrays.asList(
            "host", "connection", "proxy-authorization", "transfer-encoding", "content-length", "range", "if-range", "accept-encoding"));
    private static final List<String> RESPONSE_HEADERS = Arrays.asList(
            "Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified", "Content-Encoding");
    private final Map<String, Stream> streams = new LinkedHashMap<>(16, 0.75f, true);

    private static final class Stream {
        final URL url;
        final Map<String, String> headers;
        long lastUse = android.os.SystemClock.elapsedRealtime();

        Stream(URL url, Map<String, String> headers) { this.url = url; this.headers = headers; }
    }

    void register(JSONObject result, JSONObject siteHeaders) throws Exception {
        result.remove(TICKET);
        URL url = target(result.optString("url"));
        if (url == null || (url.getPath().equals("/proxy") && url.getQuery() != null)) return;
        JSONObject providerHeaders = result.optJSONObject("header");
        if (providerHeaders == null && result.opt("header") instanceof String) {
            try { providerHeaders = new JSONObject(result.optString("header")); } catch (Exception ignored) { }
        }
        Map<String, String> headers = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
        addHeaders(headers, siteHeaders);
        addHeaders(headers, providerHeaders);
        result.put(TICKET, register(new Stream(url, headers)));
    }

    private synchronized String register(Stream stream) {
        long now = android.os.SystemClock.elapsedRealtime();
        streams.values().removeIf(value -> now - value.lastUse > IDLE_MS);
        if (streams.size() >= 256) streams.remove(streams.keySet().iterator().next());
        String ticket = UUID.randomUUID().toString().replace("-", "");
        streams.put(ticket, stream);
        return ticket;
    }

    private synchronized Stream stream(String ticket) {
        Stream value = streams.get(ticket);
        if (value == null) return null;
        long now = android.os.SystemClock.elapsedRealtime();
        if (now - value.lastUse > IDLE_MS) { streams.remove(ticket); return null; }
        value.lastUse = now;
        return value;
    }

    private static void addHeaders(Map<String, String> merged, JSONObject fields) {
        if (fields == null) return;
        for (Iterator<String> keys = fields.keys(); keys.hasNext();) {
            String key = keys.next();
            Object value = fields.opt(key);
            if (value instanceof String && key.matches("[!#$%&'*+.^_`|~0-9A-Za-z-]{1,100}") &&
                    !REQUEST_HEADERS_TO_SKIP.contains(key.toLowerCase(Locale.ROOT)) && safe((String)value)) {
                merged.put(key, (String)value);
            }
        }
    }

    private static boolean safe(String value) {
        return value != null && value.length() <= 8192 && value.indexOf('\r') < 0 && value.indexOf('\n') < 0;
    }

    static URL target(String raw) {
        if (raw.length() > 16384) return null;
        try {
            URI uri = new URI(raw.trim());
            if (!"http".equalsIgnoreCase(uri.getScheme()) || uri.getRawUserInfo() != null || uri.getRawFragment() != null) return null;
            int port = uri.getPort();
            if (port < 1024 || port > 65535 || port == 18793 || port == 9978 || port == 19988) return null;
            String host = uri.getHost();
            if ("localhost".equalsIgnoreCase(host) || "0.0.0.0".equals(host)) host = "127.0.0.1";
            if (!Arrays.asList("127.0.0.1", "[::1]", "192.168.127.2").contains(host)) return null;
            String path = uri.getRawPath();
            return new URL("http", host, port, (path.isEmpty() ? "/" : path) +
                    (uri.getRawQuery() == null ? "" : "?" + uri.getRawQuery()));
        } catch (URISyntaxException | MalformedURLException invalid) { return null; }
    }

    private static boolean sameOrigin(URL a, URL b) { return a.getHost().equals(b.getHost()) && a.getPort() == b.getPort(); }

    void serve(Socket socket, String method, String path, Map<String, String> request) throws IOException {
        String ticket = path.substring(PREFIX.length());
        Stream media = ticket.matches("[a-f0-9]{32}") ? stream(ticket) : null;
        OutputStream output = socket.getOutputStream();
        if (media == null) { respond(output, 404, Collections.emptyMap()); return; }
        HttpURLConnection upstream = null;
        boolean started = false;
        try {
            URL address = media.url;
            int status;
            for (int redirects = 0; ; redirects++) {
                upstream = (HttpURLConnection)address.openConnection(Proxy.NO_PROXY);
                upstream.setInstanceFollowRedirects(false);
                upstream.setConnectTimeout(5000);
                upstream.setReadTimeout(20000);
                upstream.setRequestMethod(method);
                for (Map.Entry<String, String> header : media.headers.entrySet()) upstream.setRequestProperty(header.getKey(), header.getValue());
                for (String name : Arrays.asList("range", "if-range")) {
                    String value = request.get(name);
                    if (safe(value)) upstream.setRequestProperty(name, value);
                }
                upstream.setRequestProperty("Accept-Encoding", "identity");
                status = upstream.getResponseCode();
                if (status < 300 || status >= 400) break;
                String location = upstream.getHeaderField("Location");
                URL next = location == null ? null : target(new URL(address, location).toExternalForm());
                if (redirects >= 3 || next == null || !sameOrigin(media.url, next)) throw new IOException("Invalid media redirect");
                upstream.disconnect();
                address = next;
            }
            Map<String, String> headers = new LinkedHashMap<>();
            for (String name : RESPONSE_HEADERS) {
                String value = upstream.getHeaderField(name);
                if (safe(value)) headers.put(name, value);
            }
            if (method.equals("HEAD") || status >= 400 || status == 204) {
                if (!method.equals("HEAD")) headers.remove("Content-Length");
                respond(output, status, headers);
                return;
            }
            try (InputStream input = upstream.getInputStream()) {
                String mime = headers.getOrDefault("Content-Type", "").toLowerCase(Locale.ROOT);
                if (mime.contains("mpegurl") || address.getPath().toLowerCase(Locale.ROOT).endsWith(".m3u8")) {
                    // Never resolve a guest playlist's child addresses on the Mac itself.
                    byte[] body = playlist(input, address, media.headers);
                    headers.clear();
                    headers.put("Content-Type", "application/vnd.apple.mpegurl");
                    headers.put("Content-Length", Integer.toString(body.length));
                    started = true;
                    respond(output, 200, headers);
                    output.write(body);
                } else {
                    started = true;
                    respond(output, status, headers);
                    byte[] buffer = new byte[64 * 1024];
                    for (int count; (count = input.read(buffer)) != -1;) output.write(buffer, 0, count);
                }
                output.flush();
            }
        } catch (IOException | IllegalArgumentException failure) {
            if (!started) respond(output, 502, Collections.emptyMap());
        } finally {
            if (upstream != null) upstream.disconnect();
        }
    }

    private byte[] playlist(InputStream input, URL address, Map<String, String> headers) throws IOException {
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        byte[] buffer = new byte[16384];
        for (int count; (count = input.read(buffer)) != -1;) {
            if (body.size() + count > 2 * 1024 * 1024) throw new IOException("Media playlist is too large");
            body.write(buffer, 0, count);
        }
        StringBuilder rewritten = new StringBuilder();
        java.util.regex.Pattern uri = java.util.regex.Pattern.compile("(?i)\\bURI=\"([^\"]+)\"");
        Map<String, String> children = new HashMap<>();
        for (String row : new String(body.toByteArray(), StandardCharsets.UTF_8).split("\\r?\\n")) {
            String line = row.trim();
            if (!line.isEmpty() && !line.startsWith("#")) line = child(address, line, headers, children);
            else if (line.startsWith("#")) {
                java.util.regex.Matcher match = uri.matcher(line);
                StringBuffer attributes = new StringBuffer();
                while (match.find()) match.appendReplacement(attributes, java.util.regex.Matcher.quoteReplacement(
                        "URI=\"" + child(address, match.group(1), headers, children) + "\""));
                match.appendTail(attributes);
                line = attributes.toString();
            }
            rewritten.append(line).append('\n');
        }
        return rewritten.toString().getBytes(StandardCharsets.UTF_8);
    }

    private String child(URL parent, String raw, Map<String, String> headers, Map<String, String> children) throws IOException {
        URL address = target(new URL(parent, raw).toExternalForm());
        if (address == null || !sameOrigin(parent, address)) throw new IOException("Media playlist left its guest service");
        String key = address.toExternalForm();
        String cached = children.get(key);
        if (cached != null) return cached;
        if (children.size() >= 200) throw new IOException("Media playlist has too many segments");
        String path = PREFIX + register(new Stream(address, headers));
        children.put(key, path);
        return path;
    }

    private static void respond(OutputStream output, int status, Map<String, String> headers) throws IOException {
        StringBuilder response = new StringBuilder("HTTP/1.1 ").append(status).append(" Response\r\nConnection: close\r\nCache-Control: no-store\r\n");
        for (Map.Entry<String, String> header : headers.entrySet()) response.append(header.getKey()).append(": ").append(header.getValue()).append("\r\n");
        output.write(response.append("\r\n").toString().getBytes(StandardCharsets.ISO_8859_1));
    }
}
