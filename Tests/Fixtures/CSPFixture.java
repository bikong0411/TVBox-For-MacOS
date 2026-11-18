package com.github.catvod.spider;

import android.content.Context;
import com.github.catvod.crawler.Spider;
import java.util.HashMap;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/** Public, synthetic integration data. Not included in the runtime APK. */
public final class CSPFixture extends Spider {
    private String media;
    public void init(Context context, String extend) { media = extend; }
    private JSONObject video(boolean detail) throws Exception {
        JSONObject item = new JSONObject().put("vod_id", "fixture:video:1").put("vod_name", "CSP 公开演示视频").put("vod_remarks", "接口测试");
        if (detail) item.put("vod_play_from", "测试线路").put("vod_play_url", "第1集$opaque:first$token#第2集$opaque:second");
        return item;
    }
    public String homeContent(boolean filter) throws Exception {
        return new JSONObject().put("class", new JSONArray().put(new JSONObject().put("type_id", "fixture").put("type_name", "演示分类"))).put("list", new JSONArray().put(video(false))).toString();
    }
    public String categoryContent(String category, String page, boolean filter, HashMap<String,String> extend) throws Exception {
        return new JSONObject().put("list", new JSONArray().put(video(false))).put("page", Integer.parseInt(page)).put("pagecount", 1).toString();
    }
    public String searchContent(String query, boolean quick, String page) throws Exception {
        return new JSONObject().put("list", query.contains("演示") ? new JSONArray().put(video(false)) : new JSONArray()).toString();
    }
    public String detailContent(List<String> ids) throws Exception {
        return new JSONObject().put("list", new JSONArray().put(video(true))).toString();
    }
    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception {
        if (!flag.equals("测试线路") || !id.startsWith("opaque:")) throw new IllegalArgumentException();
        if (id.equals("opaque:slow")) Thread.sleep(1000);
        if (id.equals("opaque:proxy")) return new JSONObject().put("parse", 0).put("url", "http://127.0.0.1:-1/proxy?mode=media&url="+java.net.URLEncoder.encode(media,"UTF-8")).toString();
        if (id.equals("opaque:playlist")) return new JSONObject().put("parse", 0).put("url", "http://127.0.0.1:-1/proxy?mode=playlist").toString();
        if (id.equals("opaque:empty")) return "";
        return new JSONObject().put("parse", 0).put("url", media).put("header", new JSONObject().put("User-Agent", "TVBoxCSPFixture")).toString();
    }
}
