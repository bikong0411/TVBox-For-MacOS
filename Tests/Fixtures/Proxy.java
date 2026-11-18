package com.github.catvod.spider;

import java.io.*;
import java.net.*;
import java.util.*;

/** Synthetic standard callback; never packaged into the application runtime. */
public final class Proxy {
    public static Object[] proxy(Map<String,String> parameters) throws Exception {
        String mode=parameters.get("mode");
        if ("playlist".equals(mode)) {
            String body="#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-KEY:METHOD=AES-128,URI=\"http://127.0.0.1:-1/proxy?mode=key\"\n#EXTINF:1,\nhttp://127.0.0.1:-1/proxy?mode=segment\n#EXT-X-ENDLIST\n";
            return new Object[]{200,"text/plain",new ByteArrayInputStream(body.getBytes("UTF-8"))};
        }
        if ("key".equals(mode)) return new Object[]{200,"application/octet-stream",new ByteArrayInputStream(new byte[16])};
        if ("segment".equals(mode)) {
            byte[] data="0123456789ABCDEF".getBytes("UTF-8");
            if (parameters.containsKey("range")) {
                HashMap<String,String> headers=new HashMap<>();headers.put("Content-Range","bytes 2-5/16");headers.put("Content-Length","4");headers.put("Accept-Ranges","bytes");
                return new Object[]{206,"video/mp2t",new ByteArrayInputStream(Arrays.copyOfRange(data,2,6)),headers};
            }
            return new Object[]{200,"video/mp2t",new ByteArrayInputStream(data)};
        }
        if ("media".equals(mode)) {
            HttpURLConnection connection=(HttpURLConnection)new URL(parameters.get("url")).openConnection();
            connection.setConnectTimeout(10000);connection.setReadTimeout(15000);
            connection.setRequestProperty("User-Agent","TVBoxCSPFixture");connection.setRequestProperty("Referer","https://fixture.invalid/");
            if (parameters.containsKey("range")) connection.setRequestProperty("Range",parameters.get("range"));
            int status=connection.getResponseCode();HashMap<String,String> headers=new HashMap<>();
            for (String key:Arrays.asList("Content-Length","Content-Range","Accept-Ranges")) if (connection.getHeaderField(key)!=null) headers.put(key,connection.getHeaderField(key));
            return new Object[]{status,connection.getContentType(),connection.getInputStream(),headers};
        }
        return null;
    }
}
