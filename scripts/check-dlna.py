#!/usr/bin/env python3
"""Real HTTP/SOAP receiver fixture; no television or saved user sources required."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import html, json, platform, socket, subprocess, sys, threading, urllib.request
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
state = dict(mode="STOPPED", position=0, volume=37, muted=False, uri="", reads=0, stops=0)
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, data, mime="text/xml", code=200, extra=None):
        data = data.encode() if isinstance(data, str) else data
        self.send_response(code); self.send_header("Content-Type", mime); self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(data)
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        path = self.path.split("?")[0]
        base = f"http://127.0.0.1:{self.server.server_port}"
        if path == "/device.xml":
            services = "".join(f"<service><serviceType>urn:schemas-upnp-org:service:{s}:1</serviceType><controlURL>/{s}</controlURL><SCPDURL>/actions.xml</SCPDURL></service>" for s in ["AVTransport", "RenderingControl"])
            return self.reply(f"<root><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>测试 DLNA 电视</friendlyName><UDN>uuid:fixture</UDN><serviceList>{services}</serviceList></device></root>")
        if path == "/actions.xml":
            actions = ["Play", "Pause", "Stop", "Seek", "SetAVTransportURI", "GetTransportInfo", "GetPositionInfo", "GetVolume", "SetVolume", "GetMute", "SetMute"]
            return self.reply("<scpd><actionList>" + "".join(f"<action><name>{s}</name></action>" for s in actions) + "</actionList></scpd>")
        if path == "/state": return self.reply(json.dumps(state), "application/json")
        if path == "/extensionless":
            if self.headers.get("X-Cast-Fixture") != "secret": return self.reply("missing auth", code=403)
            return self.reply("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n", "application/vnd.apple.mpegurl")
        if path == "/segment.ts":
            return self.reply(b"fixture-segment", "video/mp2t", 200 if self.headers.get("X-Cast-Fixture") == "secret" else 403)
        if path == "/redirect": return self.reply(b"", code=302, extra={"Location": self.server.other + "/credentials"})
        if path == "/credentials": return self.reply(self.headers.get("X-Cast-Fixture", "stripped"), "text/plain")
        if path == "/test.mp4":
            data = (root / ".build/test.mp4").read_bytes()
            span = self.headers.get("Range")
            if span:
                left, right = span.removeprefix("bytes=").split("-"); a = int(left); b = min(len(data)-1, int(right) if right else len(data)-1)
                return self.reply(data[a:b+1], "video/mp4", 206, {"Content-Range": f"bytes {a}-{b}/{len(data)}"})
            return self.reply(data, "video/mp4")
        return self.reply("not found", code=404)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path not in ["/AVTransport", "/RenderingControl"]: return self.reply("not found", code=404)
        action = self.headers.get("SOAPAction", "").strip('"').split("#")[-1]
        tree = ET.fromstring(body)
        args = {e.tag.split("}")[-1]: e.text or "" for e in tree.iter()}
        out = {}
        if action == "SetAVTransportURI": state.update(uri=args["CurrentURI"], mode="STOPPED", position=0)
        elif action == "Play":
            try:
                req = urllib.request.Request(state["uri"], headers={"Range": "bytes=0-63"})
                with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=5) as reply:
                    if len(reply.read()) != 64: raise ValueError("range failed")
                state["reads"] += 1; state["mode"] = "PLAYING"
            except Exception: return self.reply("<Envelope><UPnPError><errorCode>714</errorCode></UPnPError></Envelope>", code=500)
        elif action == "Pause": state["mode"] = "PAUSED_PLAYBACK"
        elif action == "Stop": state["mode"] = "STOPPED"; state["stops"] += 1
        elif action == "Seek":
            h,m,s = map(float, args["Target"].split(":")); state["position"] = int(h*3600+m*60+s)
        elif action == "GetTransportInfo": out = {"CurrentTransportState": state["mode"], "CurrentTransportStatus": "OK"}
        elif action == "GetPositionInfo": out = {"RelTime": f"00:00:{state['position']:02}", "TrackDuration": "00:00:30"}
        elif action == "GetVolume": out = {"CurrentVolume": state["volume"]}
        elif action == "SetVolume": state["volume"] = int(args["DesiredVolume"])
        elif action == "GetMute": out = {"CurrentMute": int(state["muted"])}
        elif action == "SetMute": state["muted"] = args["DesiredMute"] == "1"
        data = "".join(f"<{k}>{html.escape(str(v))}</{k}>" for k,v in out.items())
        self.reply(f'<s:Envelope xmlns:s="urn:soap"><s:Body><u:{action}Response xmlns:u="urn:av">{data}</u:{action}Response></s:Body></s:Envelope>')

if "--serve" in sys.argv:
    # Optional desktop fixture. Advertise this computer as a test receiver on
    # the active LAN and serve only generated test media / mock SOAP state.
    route = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    route.connect(("239.255.255.250",1900)); ip = route.getsockname()[0]; route.close()
    server = ThreadingHTTPServer(("0.0.0.0",18792),Handler); server.other = f"http://{ip}:18792"
    udp = socket.socket(socket.AF_INET,socket.SOCK_DGRAM,socket.IPPROTO_UDP)
    udp.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); udp.bind(("",1900))
    udp.setsockopt(socket.IPPROTO_IP,socket.IP_ADD_MEMBERSHIP,socket.inet_aton("239.255.255.250")+socket.inet_aton(ip))
    def respond():
        while True:
            data, sender = udp.recvfrom(16384)
            if data.startswith(b"M-SEARCH "):
                udp.sendto(f"HTTP/1.1 200 OK\r\nLOCATION: http://{ip}:18792/device.xml\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:fixture\r\n\r\n".encode(),sender)
    threading.Thread(target=respond,daemon=True).start()
    print("Local mock television listening (generated media only)",flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: udp.close(); server.server_close()
    raise SystemExit(0)

architecture = sys.argv[1] if len(sys.argv) > 1 else platform.machine()
if architecture not in ("arm64", "x86_64"): raise SystemExit("Expected arm64 or x86_64")
build = root / f".build/{architecture}-apple-macosx/release"
frameworks = root / "dist/Release/TVBox.app/Contents/Frameworks"
folder = root / f".build/dlna-check-{architecture}/Contents/MacOS"; folder.mkdir(parents=True, exist_ok=True)
if not (folder.parent / "Frameworks").exists(): (folder.parent / "Frameworks").symlink_to(frameworks, target_is_directory=True)
binary = folder / "check-dlna"
sources = sorted(p for p in (root / "Sources/TVBoxMac").glob("*.swift") if p.name != "TVBoxMacApp.swift")
subprocess.run(["swiftc", "-O", "-parse-as-library", "-Xcc", "-fmodule-map-file="+str(build/"MPVBridge.build/module.modulemap"), "-I", str(root/"Sources/MPVBridge/include"), "-target", f"{architecture}-apple-macosx13.0", "-I", str(build / "Modules"), "-F", str(frameworks), "-framework", "VLCKit", "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", str(frameworks), *map(str,sources), str(root/"scripts/check-dlna.swift"), *map(str,(build/"TVBoxCore.build").glob("*.o")), *map(str,(build/"MPVBridge.build").glob("*.o")), "-o",str(binary)], check=True)
servers = [ThreadingHTTPServer(("127.0.0.1", 0), Handler) for _ in range(2)]
for a,b in [(0,1),(1,0)]: servers[a].other = f"http://127.0.0.1:{servers[b].server_port}"
for server in servers: threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    subprocess.run(["arch",f"-{architecture}",str(binary),f"http://127.0.0.1:{servers[0].server_port}"], cwd=root,check=True,timeout=90)
    assert state["reads"] > 0 and state["stops"] > 0, state
    print("PASS: television fetched relay bytes and received Stop; isolated HTTP fixture", architecture)
finally:
    for server in servers: server.shutdown(); server.server_close()
