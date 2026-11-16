#!/usr/bin/env python3
"""仅用于本地开发验证，不向外部提供影视采集内容。"""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs
import json
import argparse
import ssl
import time
from datetime import datetime, timedelta, timezone

ROOT = Path(__file__).resolve().parent.parent

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        request = urlparse(self.path)
        query = parse_qs(request.query)
        address = f"http://127.0.0.1:{self.server.server_port}"
        if request.path in ("/edit-live-a.m3u", "/edit-live-b.m3u"):
            if self.headers.get("X-Source-Edit") != "fixture-preserved":
                self.send_error(403); return
            return self.send_bytes(f'#EXTM3U\n#EXTINF:-1 group-title="修改验证",测试频道\n{address}/test.mp4\n'.encode(), "audio/x-mpegurl")
        if request.path == "/edit-slow.json":
            time.sleep(0.6)
            return self.send_json({"name": "慢响应", "sites": [{"key": "slow-edit", "name": "新接口", "type": 1, "api": address + "/api"}]})
        if request.path == "/grouping.m3u":
            names = ["湖南卫视", "CCTV1 综合", "CHC高清电影", "金鹰卡通", "广东体育", "CCTV1 高清", "凤凰资讯", "浙江卫视", "CCTV5+ 体育", "CCTV13 新闻", "家庭影院", "少儿动画", "高清足球", "新闻直播", "Discovery探索", "经典音乐", "CETV1", "健康生活", "NHK World", "上海都市", "自定义频道"]
            rows = ["#EXTM3U"]
            for i, name in enumerate(names):
                rows.extend([f'#EXTINF:-1 group-title="原始线路 {i % 3 + 1}",{name}', address + f"/test.mp4?group-channel={i}"])
            return self.send_bytes(("\n".join(rows) + "\n").encode(), "audio/x-mpegurl")
        if request.path == "/overlay.m3u":
            rows = [f'#EXTM3U x-tvg-url="{address}/overlay-guide.xml"']
            for i in range(1, 1001):
                rows.extend([f'#EXTINF:-1 tvg-id="c{i}" group-title="{"央视" if i < 20 else "地方频道"}" catchup="default" catchup-days="5" catchup-source="{address}/test.mp4?start={{utc}}&duration={{duration}}",{"CCTV" + str(i) if i < 20 else "测试频道 " + str(i)}', address + f"/test.mp4?channel={i}"])
            return self.send_bytes(("\n".join(rows) + "\n").encode(), "audio/x-mpegurl")
        if request.path == "/overlay-guide.xml":
            if query.get("slow") == ["1"]: time.sleep(0.8)
            zone = timezone(timedelta(hours=8)); today = datetime.now(zone).replace(hour=0, minute=0, second=0, microsecond=0)
            rows = ['<?xml version="1.0" encoding="UTF-8"?><tv>']
            for channel in range(1, 4):
                rows.append(f'<channel id="c{channel}"><display-name>CCTV{channel}</display-name></channel>')
                for offset in range(-3, 3):
                    for hour in range(24):
                        start = today + timedelta(days=offset, hours=hour); end = start + timedelta(hours=1)
                        title = ["新闻直播间", "人文纪录片", "电视剧场", "环球视线"][hour % 4]
                        rows.append(f'<programme channel="c{channel}" start="{start:%Y%m%d%H%M%S %z}" stop="{end:%Y%m%d%H%M%S %z}"><title>{title} · 频道{channel}</title><desc>仅用于本机验证的节目单，回看播放本地测试片段。</desc></programme>')
            return self.send_bytes(("".join(rows) + "</tv>").encode(), "application/xml")
        if request.path == "/overlay-epg":
            return self.send_json({"channel_name": query.get("ch", ["CCTV1"])[0], "date": query.get("date", [datetime.now().strftime("%Y-%m-%d")])[0], "epg_data": [
                {"title": "早间新闻", "start": "08:00", "end": "09:00"}, {"title": "晚间新闻", "start": "19:00", "end": "19:30"}]})
        if request.path == "/live-sort-config.json":
            return self.send_json({"name": "直播源排序验证", "lives": [
                {"name": "慢速直播", "url": address + "/probe-sort-slow.m3u"},
                {"name": "快速直播", "url": address + "/probe-sort-fast.m3u"},
                {"name": "失败直播", "url": address + "/probe-forbidden"}
            ]})
        if request.path in ("/probe-sort-slow.m3u", "/probe-sort-fast.m3u", "/probe-sort-unchecked.m3u"):
            time.sleep(0.18 if request.path == "/probe-sort-slow.m3u" else 0.02)
            return self.send_bytes(f'#EXTM3U\n#EXTINF:-1,排序验证频道\n{address}/test.mp4\n'.encode(), "audio/x-mpegurl")
        if request.path == "/probe-config.json":
            return self.send_json({"name": "网络探测验证", "sites": [
                {"key": "ok", "name": "正常地址", "type": 1, "api": address + "/probe-ok?token=private-test", "header": {"Authorization": "Bearer fixture-only"}},
                {"key": "duplicate", "name": "相同地址去重", "type": 1, "api": address + "/probe-ok?token=private-test", "header": {"Authorization": "Bearer fixture-only"}},
                {"key": "fallback", "name": "HEAD 不支持回退", "type": 1, "api": address + "/probe-head-unsupported"},
                {"key": "forbidden", "name": "拒绝访问", "type": 1, "api": address + "/probe-forbidden"},
                {"key": "missing", "name": "失效地址", "type": 1, "api": address + "/probe-missing"},
                {"key": "slow", "name": "超时地址", "type": 1, "api": address + "/probe-slow"},
                {"key": "redirect", "name": "重定向地址", "type": 1, "api": address + "/probe-redirect"},
                {"key": "headers-only", "name": "大响应提前结束", "type": 1, "api": address + "/probe-headers-only"},
                {"key": "csp", "name": "跳过爬虫", "type": 3, "api": "csp_Fixture"}
            ], "lives": [{"name": "直播订阅验证", "url": address + "/probe-live.m3u"}],
               "urls": [{"name": "子配置验证", "url": address + "/probe-child.json"}]})
        if request.path == "/probe-redirect":
            self.send_response(302); self.send_header("Location", address + "/probe-ok"); self.end_headers(); return
        if request.path == "/probe-headers-only":
            if self.command == "HEAD":
                self.send_response(405); self.end_headers(); return
            self.send_response(200); self.send_header("Content-Type", "application/octet-stream"); self.send_header("Content-Length", "999999999"); self.end_headers()
            # CFNetwork may inspect a small prefix before reporting response headers.
            self.wfile.write(b"x" * 1024); self.wfile.flush()
            time.sleep(20)
            return
        if request.path == "/probe-forbidden":
            self.send_error(403); return
        if request.path == "/probe-missing":
            self.send_error(404); return
        if request.path == "/probe-slow":
            time.sleep(20)
            return self.send_json({"list": []})
        if request.path == "/probe-head-unsupported" and self.command == "HEAD":
            self.send_response(405); self.send_header("Allow", "GET"); self.end_headers(); return
        if request.path == "/probe-live.m3u":
            return self.send_bytes(f'#EXTM3U\n#EXTINF:-1,不会探测此频道\n{address}/must-not-probe-channel.m3u8\n'.encode(), "audio/x-mpegurl")
        if request.path == "/probe-child.json":
            return self.send_json({"sites": []})
        if request.path in ("/probe-ok", "/probe-head-unsupported"):
            return self.send_json({"class": [], "list": []})
        if request.path == "/live-failover.m3u":
            entries = [
                ("备用线路自动切换", "/invalid-live.flv"),
                ("备用线路自动切换", "/missing.mp4"),
                ("备用线路自动切换", "/test.mp4"),
                ("全部失效验证", "/invalid-live.flv"),
                ("全部失效验证", "/missing.mp4"),
                ("慢线路超时验证", "/slow.mp4"),
                ("慢线路超时验证", "/test.mp4?timeout-fallback=1"),
            ]
            text = "#EXTM3U\n" + "".join(f'#EXTINF:-1 group-title="自动换线测试",{name}\n{address}{path}$LR•3•IPV4『线路{index + 1}』\n' for index, (name, path) in enumerate(entries))
            return self.send_bytes(text.encode(), "audio/x-mpegurl")
        if request.path == "/invalid-live.flv":
            return self.send_bytes(b"<!doctype html><html><body>Not a video stream</body></html>", "text/html")
        if request.path == "/slow.mp4":
            time.sleep(22)
            return self.send_bytes(b"not a video", "text/plain")
        if request.path == "/live-stress.m3u":
            lines = ["#EXTM3U"]
            for channel in range(1000):
                for route in range(6):
                    lines += [f'#EXTINF:-1 group-title="测试分组 {channel % 5}",压力频道 {channel:04d}',
                              f"{address}/test.mp4?channel={channel}&route={route}"]
            return self.send_bytes(("\n".join(lines) + "\n").encode(), "audio/x-mpegurl")
        if request.path in ("/config-a.json", "/config-b.json"):
            label = "A" if request.path == "/config-a.json" else "B"
            return self.send_json({"name": "点播源 " + label, "sites": [
                {"key": "same-cms-key", "name": "主接口 " + label, "type": 1, "api": address + "/api?source=" + label},
                {"key": "backup", "name": "备用接口 " + label, "type": 1, "api": address + "/api?source=" + label + "-backup"}
            ], "lives": [{"name": "附带直播 " + label, "url": "./live-" + label.lower() + ".m3u"}]})
        if request.path in ("/live-a.m3u", "/live-b.m3u"):
            label = "A" if request.path == "/live-a.m3u" else "B"
            text = f'#EXTM3U\n#EXTINF:-1 group-title="分组 {label}",测试频道 {label}\n{address}/test.mp4\n'
            if label == "B":
                text += f'#EXTINF:-1 group-title="分组 B",测试频道 B2\n{address}/test.mp4?channel=2\n'
            return self.send_bytes(text.encode(), "audio/x-mpegurl")
        if request.path == "/config.json":
            return self.send_json({"name": "本地功能验证", "sites": [
                {"key": "fixture-json", "name": "本地 JSON 测试", "type": 1, "api": address + "/api", "searchable": 1},
                {"key": "fixture-xml", "name": "本地 XML 测试", "type": 0, "api": address + "/xml", "searchable": 1},
                {"key": "fixture-csp", "name": "不兼容源提示测试", "type": 3, "api": "csp_Demo"}
            ], "lives": [{"name": "本地直播测试", "url": "./live.m3u"}]})
        if request.path == "/live.m3u":
            return self.send_bytes(f'#EXTM3U\n#EXTINF:-1 group-title="测试分组",本地测试频道\n{address}/test.mp4\n'.encode(), "audio/x-mpegurl")
        if request.path == "/api":
            if query.get("ac") == ["list"]:
                return self.send_json({"class": [{"type_id": "1", "type_name": "测试电影"}, {"type_id": "2", "type_name": "测试剧集"}], "list": []})
            title = "原生播放器测试"
            if "source" in query:
                title = query["source"][0] + " · " + title
            if "wd" in query and query["wd"][0] not in title:
                return self.send_json({"list": [], "page": 1, "pagecount": 1})
            return self.send_json({"page": query.get("pg", [1])[0], "pagecount": 2,
                "list": [{"vod_id": query.get("ids", ["local-1"])[0], "vod_name": title, "vod_year": "2026", "vod_area": "本机生成", "vod_remarks": "本地测试片", "vod_content": "<p>由 FFmpeg 生成的测试画面，用于验证解码、选集、收藏和断点续播。</p>", "vod_play_from": "线路一$$$线路二", "vod_play_url": f"第一集${address}/test.mp4#第二集${address}/test.mp4?episode=2$$$备用${address}/test.mp4"}]})
        if request.path == "/xml":
            if query.get("ac") == ["list"]:
                content = '<rss><class><ty id="1">XML 分类</ty></class><list page="1" pagecount="1"/></rss>'
            else:
                content = f'<rss><list page="1" pagecount="1"><video><id>xml-1</id><name>XML 播放测试</name><year>2026</year><dl><dd flag="mp4"><![CDATA[正片${address}/test.mp4]]></dd></dl><des><![CDATA[<p>XML CDATA 测试</p>]]></des></video></list></rss>'
            return self.send_bytes(content.encode(), "application/xml")
        if request.path == "/test.mp4":
            if query.get("require-vlc-headers") == ["1"] and (self.headers.get("User-Agent") != "TVBox-VLC-Fixture" or self.headers.get("Referer") != "https://fixture.invalid/"):
                self.send_error(403); return
            if query.get("require-retry-header") == ["1"] and self.headers.get("X-Retry-Fixture") != "preserved":
                self.send_error(403); return
            clip = ROOT / ".build" / "test.mp4"
            if clip.exists():
                return self.send_bytes(clip.read_bytes(), "video/mp4")
        self.send_error(404)

    def do_HEAD(self):
        self.do_GET()

    def send_json(self, value):
        self.send_bytes(json.dumps(value, ensure_ascii=False).encode(), "application/json")

    def send_bytes(self, value, content_type):
        total = len(value)
        start, end = 0, total - 1
        partial = content_type == "video/mp4" and self.headers.get("Range", "").startswith("bytes=")
        if partial:
            requested = self.headers["Range"][6:].split("-", 1)
            start = int(requested[0] or "0")
            end = min(int(requested[1]) if requested[1] else end, end)
            if start > end or start >= total:
                self.send_error(416)
                return
            value = value[start:end + 1]
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(value)))
        if content_type == "video/mp4":
            self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
        self.end_headers()
        if self.command == "HEAD":
            return
        try:
            self.wfile.write(value)
        except (BrokenPipeError, ConnectionResetError):
            pass

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18791)
    parser.add_argument("--tls-cert")
    parser.add_argument("--tls-key")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    scheme = "http"
    if args.tls_cert and args.tls_key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.tls_cert, args.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    print(f"测试配置：{scheme}://127.0.0.1:{args.port}/config.json", flush=True)
    server.serve_forever()
