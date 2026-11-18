package com.github.catvod.crawler;

import android.content.Context;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Binary interface used by CatVod Java spiders; execution stays in Android. */
public class Spider {
    /** Standard Spider networking ABI; use Android's configured system resolver. */
    public static okhttp3.Dns safeDns() { return okhttp3.Dns.SYSTEM; }
    public String siteKey = "";
    protected Context context;
    public void init(Context context) throws Exception { this.context = context; }
    public void init(Context context, String extend) throws Exception { init(context); }
    public String homeContent(boolean filter) throws Exception { return "{\"class\":[],\"list\":[]}"; }
    public String homeVideoContent() throws Exception { return "{\"list\":[]}"; }
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception { return "{\"list\":[]}"; }
    public String detailContent(List<String> ids) throws Exception { return "{\"list\":[]}"; }
    public String searchContent(String key, boolean quick) throws Exception { return "{\"list\":[]}"; }
    public String searchContent(String key, boolean quick, String pg) throws Exception { return searchContent(key, quick); }
    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception { return "{}"; }
    public Object[] proxyLocal(Map<String, String> parameters) throws Exception { return null; }
    public String action(String action) throws Exception { return ""; }
    public boolean manualVideoCheck() { return false; }
    public boolean isVideoFormat(String url) { return false; }
    public void destroy() { }
}
