package local.tvbox.csp;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.widget.TextView;
import dalvik.system.DexClassLoader;
import org.json.JSONObject;
import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;

/** A private, authenticated RPC worker. All third-party bytecode runs in the VM. */
public final class WorkerActivity extends Activity {
    private static final int LIMIT = 24 * 1024 * 1024;
    private final Map<String, Object> spiders = new LinkedHashMap<>();
    private String componentHash = "";
    private volatile String token;
    private ClassLoader loader;
    private ServerSocket server;
    private HandlerThread calls;
    private Handler handler;
    private final ExecutorService connections = new ThreadPoolExecutor(2, 8, 30, TimeUnit.SECONDS, new ArrayBlockingQueue<Runnable>(16), new ThreadPoolExecutor.AbortPolicy());

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView text = new TextView(this);
        text.setText("TVBox 爬虫运行组件\n\n此窗口只负责接口调用，视频在 Mac 的 TVBox 内播放。");
        text.setTextSize(18); text.setPadding(28, 40, 28, 28); setContentView(text);
        token = bootToken(getIntent());
        int port = getIntent().getIntExtra("port", 18793);
        if (token == null || token.length() < 32 || port < 1024 || port > 65535) { finish(); return; }
        calls = new HandlerThread("CSP calls"); calls.start(); handler = new Handler(calls.getLooper());
        new Thread(() -> {
            try {
                server = new ServerSocket(port, 8, InetAddress.getByName("0.0.0.0"));
                while (!server.isClosed()) {
                    final Socket socket = server.accept();
                    try { connections.execute(() -> serve(socket)); }
                    catch (RejectedExecutionException ignored) { socket.close(); }
                }
            } catch (IOException ignored) { }
        }, "CSP HTTP").start();
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        String next = bootToken(intent);
        if (next != null && next.matches("[a-f0-9]{64}")) {
            setIntent(intent); token = next;
        }
    }
    private static String bootToken(Intent intent) {
        try {
            String value = property("ro.boot.tvbox_csp_token");
            if (value.matches("[a-f0-9]{64}")) return value;
        } catch (Exception unavailable) { }
        return intent.getStringExtra("token");
    }
    private static String property(String name) {
        try { return (String)Class.forName("android.os.SystemProperties").getMethod("get", String.class).invoke(null, name); }
        catch (Exception unavailable) { return ""; }
    }

    private static String line(InputStream input) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        for (int i=0; i<8192; i++) {
            int c = input.read(); if (c < 0) throw new EOFException();
            if (c == 10) return new String(bytes.toByteArray(), "UTF-8").replace("\r", "");
            bytes.write(c);
        }
        throw new IOException("HEADER_LIMIT");
    }
    private void serve(Socket socket) {
        try (Socket owned = socket) {
            socket.setSoTimeout(45000);
            InputStream input = new BufferedInputStream(socket.getInputStream());
            String[] request = line(input).split(" ");
            if (request.length != 3) return;
            Map<String, String> headers = new HashMap<>(); int total = 0;
            for (;;) {
                String row = line(input); total += row.length(); if (total > 16384) return;
                if (row.isEmpty()) break; int colon = row.indexOf(':');
                if (colon > 0) headers.put(row.substring(0, colon).toLowerCase(Locale.ROOT), row.substring(colon+1).trim());
            }
            String auth = headers.get("authorization");
            if (auth == null || !MessageDigest.isEqual(auth.getBytes("UTF-8"), ("Bearer " + token).getBytes("UTF-8"))) {
                reply(socket, 401, new JSONObject().put("error", "AUTH_REQUIRED")); return;
            }
            if (request[0].equals("GET") && request[1].equals("/health")) {
                reply(socket, 200, new JSONObject().put("protocol", 1).put("runtime", "android-art").put("bootCompleted", property("sys.boot_completed").equals("1")).put("abi", android.os.Build.SUPPORTED_ABIS[0])); return;
            }
            if ((request[0].equals("GET") || request[0].equals("HEAD")) && request[1].startsWith("/media/")) {
                serveMedia(socket, request[0], request[1], headers); return;
            }
            if (!request[0].equals("POST") || !request[1].equals("/rpc") || headers.containsKey("transfer-encoding")) {
                reply(socket, 400, new JSONObject().put("error", "BAD_REQUEST")); return;
            }
            int length = Integer.parseInt(headers.getOrDefault("content-length", "-1"));
            if (length < 0 || length > LIMIT) { reply(socket, 413, new JSONObject().put("error", "BODY_LIMIT")); return; }
            byte[] body = new byte[length]; int offset = 0;
            while (offset < length) { int n = input.read(body, offset, length-offset); if (n < 0) throw new EOFException(); offset += n; }
            JSONObject payload = new JSONObject(new String(body, "UTF-8"));
            FutureTask<JSONObject> operation = new FutureTask<>(() -> invoke(payload)); handler.post(operation);
            int seconds = Math.min(180, Math.max(1, payload.optInt("timeout", 40)));
            try { reply(socket, 200, operation.get(seconds, TimeUnit.SECONDS)); }
            catch (TimeoutException timeout) {
                operation.cancel(false);
                reply(socket, 504, new JSONObject().put("error", "SPIDER_TIMEOUT"));
                // A blocked native call cannot safely be interrupted. Reset
                // this private worker; no Mac process or other app is killed.
                android.os.Process.killProcess(android.os.Process.myPid());
            }
        } catch (Throwable ignored) { }
    }

    private JSONObject invoke(JSONObject request) {
        try {
            if (request.getInt("protocol") != 1) return error("PROTOCOL_UNSUPPORTED");
            String command = request.getString("command");
            if (command.equals("load")) return load(request);
            Object spider = spiders.get(request.getString("session"));
            if (spider == null) return error("SESSION_MISSING");
            JSONObject args = request.optJSONObject("args"); if (args == null) args = new JSONObject();
            Object result;
            switch (command) {
                case "home": result = call(spider, "homeContent", false); break;
                case "homeVideo": result = call(spider, "homeVideoContent"); break;
                case "category": result = call(spider, "categoryContent", args.getString("category"), args.optString("page", "1"), false, new HashMap<String, String>()); break;
                case "detail": result = call(spider, "detailContent", Collections.singletonList(args.getString("id"))); break;
                case "search":
                    // Both original TVBox and paginated CatVod interfaces.
                    try { result = call(spider, "searchContent", args.getString("query"), false, args.optString("page", "1")); }
                    catch (NoSuchMethodException missing) { result = call(spider, "searchContent", args.getString("query"), false); }
                    break;
                case "player": result = call(spider, "playerContent", args.getString("flag"), args.getString("id"), new ArrayList<String>()); break;
                default: return error("COMMAND_UNSUPPORTED");
            }
            String json = String.valueOf(result);
            if (result == null || json.trim().isEmpty() || json.trim().equals("null")) return error("SPIDER_RESULT_EMPTY");
            if (json.getBytes("UTF-8").length > 8 * 1024 * 1024) return error("RESULT_LIMIT");
            return new JSONObject().put("result", new JSONObject(json));
        } catch (Throwable failure) {
            // No plugin-controlled message, response body or URL crosses the
            // error channel. The host maps stable codes to readable Chinese.
            Throwable cause = failure instanceof InvocationTargetException ? ((InvocationTargetException)failure).getTargetException() : failure;
            String code = cause instanceof NoSuchMethodError || cause instanceof NoSuchFieldError ? "SDK_ABI_MISMATCH" : cause instanceof UnsatisfiedLinkError ? "NATIVE_DEPENDENCY_MISSING" :
                    cause instanceof ClassNotFoundException || cause instanceof NoClassDefFoundError ? "CLASS_DEPENDENCY_MISSING" : "SPIDER_CALL_FAILED";
            JSONObject result = error(code);
            try {
                result.put("exception", cause.getClass().getName());
                org.json.JSONArray dependencies = new org.json.JSONArray();
                collectDependencies(cause, dependencies, 0);
                result.put("dependencies", dependencies);
                Throwable dependency = cause;
                for (int i=0; dependency != null && i<6; i++, dependency=dependency.getCause()) {
                    if (!(dependency instanceof NoClassDefFoundError) && !(dependency instanceof ClassNotFoundException)) continue;
                    String message = dependency.getMessage();
                    if (message == null || message.length() > 4096) continue;
                    java.util.regex.Matcher matcher = java.util.regex.Pattern.compile("(?:Failed resolution of: L|Didn't find class .)([A-Za-z0-9_$/\\.]{1,200})").matcher(message);
                    String name = matcher.find() ? matcher.group(1) : message.matches("[A-Za-z0-9_$/\\.]{1,200}") ? message : "";
                    if (!name.isEmpty()) { result.put("dependency", name.replace('/', '.')); break; }
                }
                org.json.JSONArray frames = new org.json.JSONArray();
                for (StackTraceElement frame : cause.getStackTrace()) {
                    if (frames.length() == 6) break;
                    frames.put(frame.getClassName() + "." + frame.getMethodName());
                }
                result.put("frames", frames);
            } catch (Exception ignored) { }
            return result;
        }
    }

    /** Standard CatVod proxy callback. Media bytes never enter the JSON RPC. */
    private void serveMedia(Socket socket, String verb, String target, Map<String, String> headers) throws Exception {
        int question = target.indexOf('?');
        String path = question < 0 ? target : target.substring(0, question);
        String[] parts = path.split("/", -1);
        if (parts.length != 4 || !parts[2].matches("[a-f0-9]{64}") || !parts[3].equals("proxy") || target.length() > 16384) {
            reply(socket, 400, error("BAD_REQUEST")); return;
        }
        final String session = parts[2];
        final HashMap<String, String> parameters = new HashMap<>();
        if (question >= 0) {
            String[] pairs = target.substring(question+1).split("&", -1);
            if (pairs.length > 64) { reply(socket, 400, error("BAD_REQUEST")); return; }
            for (String pair : pairs) {
                String[] value = pair.split("=", 2);
                parameters.put(URLDecoder.decode(value[0], "UTF-8"), value.length == 2 ? URLDecoder.decode(value[1], "UTF-8") : "");
            }
        }
        for (Map.Entry<String, String> header : headers.entrySet()) {
            String key = header.getKey();
            if (!Arrays.asList("authorization", "host", "connection", "content-length", "transfer-encoding").contains(key) && !parameters.containsKey(key)) parameters.put(key, header.getValue());
        }
        FutureTask<Object[]> operation = new FutureTask<>(() -> {
            Object spider = spiders.get(session);
            if (spider == null) return null;
            try {
                Method method = method(loader.loadClass("com.github.catvod.spider.Proxy"), "proxy", new Object[]{parameters});
                if (Modifier.isStatic(method.getModifiers())) return (Object[])method.invoke(null, parameters);
            } catch (ClassNotFoundException | NoSuchMethodException unavailable) { }
            return (Object[])call(spider, "proxyLocal", parameters);
        });
        handler.post(operation);
        Object[] response;
        try { response = operation.get(40, TimeUnit.SECONDS); }
        catch (Exception failed) { operation.cancel(false); reply(socket, 502, error("PROXY_FAILED")); return; }
        if (response == null || response.length < 3 || !(response[0] instanceof Number) || !(response[2] instanceof InputStream)) {
            reply(socket, 502, error("PROXY_UNAVAILABLE")); return;
        }
        int status = ((Number)response[0]).intValue();
        if (status < 200 || status > 599) status = 502;
        String mime = String.valueOf(response[1]);
        if (mime.indexOf('\r') >= 0 || mime.indexOf('\n') >= 0 || mime.length() > 256) mime = "application/octet-stream";
        Map<String, String> outgoing = new LinkedHashMap<>();
        if (response.length > 3 && response[3] instanceof Map) {
            for (Map.Entry<?, ?> entry : ((Map<?, ?>)response[3]).entrySet()) {
                String key = String.valueOf(entry.getKey()), value = String.valueOf(entry.getValue());
                if (key.matches("[!#$%&'*+.^_`|~0-9A-Za-z-]{1,100}") && value.length() < 8192 && value.indexOf('\r') < 0 && value.indexOf('\n') < 0 && !Arrays.asList("transfer-encoding", "connection", "content-type").contains(key.toLowerCase(Locale.ROOT))) outgoing.put(key, value);
            }
        }
        try (BufferedInputStream body = new BufferedInputStream((InputStream)response[2])) {
            byte[] playlist = null;
            body.mark(16); byte[] prefix = new byte[8]; int prefixCount = 0;
            while (prefixCount < prefix.length) { int count = body.read(prefix, prefixCount, prefix.length-prefixCount); if (count < 0) break; prefixCount += count; }
            body.reset();
            if (mime.toLowerCase(Locale.ROOT).contains("mpegurl") || new String(prefix, 0, prefixCount, "UTF-8").startsWith("#EXTM3U")) {
                ByteArrayOutputStream bytes = new ByteArrayOutputStream(); byte[] buffer = new byte[16384]; int count;
                while ((count = body.read(buffer)) != -1) {
                    if (bytes.size()+count > 2*1024*1024) { reply(socket, 502, error("PROXY_PLAYLIST_LIMIT")); return; }
                    bytes.write(buffer, 0, count);
                }
                String text = new String(bytes.toByteArray(), "UTF-8");
                // A plugin may generate an unset Android server port (-1).
                // Keep its proxy callback and parameters; do not unwrap/guess
                // the underlying video URL or discard the plugin's processing.
                text = text.replaceAll("(?i)https?://(?:127\\.0\\.0\\.1|localhost|\\[::1\\]|192\\.168\\.127\\.2)(?::-?\\d+)?/proxy\\?", "/media/"+session+"/proxy?");
                playlist = text.getBytes("UTF-8");
                mime = "application/vnd.apple.mpegurl";
                outgoing.entrySet().removeIf(entry -> entry.getKey().equalsIgnoreCase("content-length"));
                outgoing.put("Content-Length", String.valueOf(playlist.length));
            }
            OutputStream output = socket.getOutputStream();
            StringBuilder head = new StringBuilder("HTTP/1.1 "+status+" Response\r\nContent-Type: "+mime+"\r\nConnection: close\r\nCache-Control: no-store\r\n");
            for (Map.Entry<String, String> entry : outgoing.entrySet()) head.append(entry.getKey()).append(": ").append(entry.getValue()).append("\r\n");
            output.write(head.append("\r\n").toString().getBytes("UTF-8"));
            if (!verb.equals("HEAD")) {
                if (playlist != null) output.write(playlist);
                else { byte[] buffer = new byte[65536]; int count; while ((count = body.read(buffer)) != -1) output.write(buffer, 0, count); }
            }
            output.flush();
        }
    }

    private JSONObject load(JSONObject request) throws Exception {
        String session = request.getString("session"), name = request.getString("class");
        if (!session.matches("[a-f0-9]{64}") || !name.matches("com\\.github\\.catvod\\.spider\\.[A-Za-z_$][A-Za-z0-9_$]{0,159}")) return error("BAD_MODULE");
        if (spiders.containsKey(session)) return new JSONObject().put("loaded", true);
        if (spiders.size() >= 16) return error("SESSION_LIMIT");
        byte[] data = android.util.Base64.decode(request.getString("module"), android.util.Base64.DEFAULT);
        if (data.length < 4 || data.length > 16 * 1024 * 1024 || data[0] != 'P' || data[1] != 'K') return error("BAD_MODULE");
        String hash = hex(MessageDigest.getInstance("SHA-256").digest(data));
        if (!hash.equals(request.getString("sha256"))) return error("MODULE_HASH_MISMATCH");
        // Different modules may define the same classes / static Init object.
        // The host restarts the worker before switching component archives.
        if (!componentHash.isEmpty() && !componentHash.equals(hash)) return error("WORKER_RESTART_REQUIRED");
        File directory = new File(getCodeCacheDir(), hash); directory.mkdirs();
        File archive = new File(directory, "component.jar");
        boolean valid = archive.isFile() && archive.length() == data.length;
        if (valid) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            try (InputStream input = new FileInputStream(archive)) {
                byte[] buffer = new byte[8192]; int count;
                while ((count=input.read(buffer)) != -1) digest.update(buffer, 0, count);
            }
            valid = hex(digest.digest()).equals(hash);
        }
        if (!valid) {
            if (loader != null) return error("WORKER_RESTART_REQUIRED");
            File temporary = new File(directory, "component.pending");
            if (temporary.exists() && !temporary.delete()) return error("BAD_MODULE");
            try (FileOutputStream output = new FileOutputStream(temporary)) { output.write(data); output.getFD().sync(); }
            if (!temporary.setReadOnly()) return error("MODULE_NOT_READONLY");
            if (archive.exists() && !archive.delete()) return error("BAD_MODULE");
            if (!temporary.renameTo(archive)) return error("BAD_MODULE");
        }
        if (loader == null) {
            loader = new DexClassLoader(archive.getAbsolutePath(), directory.getAbsolutePath(), directory.getAbsolutePath(), getClassLoader());
            try { callStatic(loader.loadClass("com.github.catvod.spider.Init"), "init", getApplication()); }
            catch (ClassNotFoundException | NoSuchMethodException noInit) { }
            componentHash = hash;
        }
        Class<?> entry;
        try { entry = loader.loadClass(name); }
        catch (ClassNotFoundException missing) { return error("ENTRY_CLASS_MISSING"); }
        Object spider = entry.getDeclaredConstructor().newInstance();
        try { spider.getClass().getField("siteKey").set(spider, session); } catch (NoSuchFieldException ignored) { }
        call(spider, "init", getApplication(), request.optString("extend", ""));
        spiders.put(session, spider);
        return new JSONObject().put("loaded", true);
    }
    private static Object call(Object target, String name, Object... args) throws Exception { return method(target.getClass(), name, args).invoke(target, args); }
    private static void collectDependencies(Throwable error, org.json.JSONArray out, int depth) {
        if (error == null || depth > 6 || out.length() > 10) return;
        if (error instanceof NoClassDefFoundError || error instanceof ClassNotFoundException) {
            String message = error.getMessage();
            if (message != null && message.length() < 4096) {
                java.util.regex.Matcher matcher = java.util.regex.Pattern.compile("(?:Failed resolution of: L|Didn't find class .|Could not initialize class )([A-Za-z0-9_$/\\.]{1,200})").matcher(message);
                String name = matcher.find() ? matcher.group(1) : message.matches("[A-Za-z0-9_$/\\.]{1,200}") ? message : "";
                if (!name.isEmpty()) out.put(name.replace('/', '.'));
            }
        }
        collectDependencies(error.getCause(), out, depth+1);
        for (Throwable suppressed : error.getSuppressed()) collectDependencies(suppressed, out, depth+1);
    }
    private static Object callStatic(Class<?> type, String name, Object... args) throws Exception { return method(type, name, args).invoke(null, args); }
    private static Method method(Class<?> type, String name, Object[] args) throws NoSuchMethodException {
        for (Method method : type.getMethods()) {
            Class<?>[] parameters = method.getParameterTypes();
            if (!method.getName().equals(name) || parameters.length != args.length) continue;
            boolean valid = true;
            for (int i=0; i<args.length; i++) {
                Class<?> parameter = parameters[i] == boolean.class ? Boolean.class : parameters[i];
                if (args[i] != null && !parameter.isInstance(args[i])) { valid = false; break; }
            }
            if (valid) return method;
        }
        throw new NoSuchMethodException(name);
    }
    private static String hex(byte[] data) { StringBuilder out = new StringBuilder(); for (byte b : data) out.append(String.format(Locale.ROOT, "%02x", b & 255)); return out.toString(); }
    private static JSONObject error(String code) { try { return new JSONObject().put("error", code); } catch (Exception impossible) { throw new IllegalStateException(impossible); } }
    private static void reply(Socket socket, int status, JSONObject value) throws IOException {
        byte[] bytes = value.toString().getBytes("UTF-8");
        OutputStream output = socket.getOutputStream();
        output.write(("HTTP/1.1 " + status + " Reply\r\nContent-Type: application/json\r\nContent-Length: " + bytes.length + "\r\nConnection: close\r\n\r\n").getBytes("US-ASCII"));
        output.write(bytes); output.flush();
    }
    @Override public void onDestroy() {
        try { if (server != null) server.close(); } catch (IOException ignored) { }
        connections.shutdownNow(); if (calls != null) calls.quitSafely(); super.onDestroy();
    }
}
