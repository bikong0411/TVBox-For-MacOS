#!/usr/bin/env python3
"""Real HTTP receiver fixture for the legacy URL AirPlay production transport."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json,plistlib,platform,subprocess,sys,threading,time,urllib.request,urllib.parse
root=Path(__file__).resolve().parent.parent
state=dict(ready=False,rate=0,position=0,duration=30,plays=0,stops=0,reads=0,denied=0,redirect_leaks=0,events=[])
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*_):pass
    def reply(self,data=b'',mime='application/x-apple-binary-plist',code=200,headers=None):
        if isinstance(data,str):data=data.encode()
        self.send_response(code);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(data)))
        for k,v in (headers or {}).items():self.send_header(k,v)
        self.end_headers()
        try:self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError):pass
    def do_GET(self):
        path=urllib.parse.urlparse(self.path).path
        if path=='/state':return self.reply(json.dumps(state),'application/json')
        if path=='/playback-info':return self.reply(plistlib.dumps({'readyToPlay':state['ready'],'rate':state['rate'],'position':state['position'],'duration':state['duration']},fmt=plistlib.FMT_BINARY))
        if path=='/source.mp4':
            if self.headers.get('X-AirPlay-Fixture')!='preserved':return self.reply(code=403)
            data=(root/'.build/test.mp4').read_bytes();lo=0;hi=len(data)-1;span=self.headers.get('Range','')
            if span.startswith('bytes='):
                a,b=span[6:].split('-',1);lo=int(a or 0);hi=min(int(b) if b else hi,hi)
                return self.reply(data[lo:hi+1],'video/mp4',206,{'Content-Range':f'bytes {lo}-{hi}/{len(data)}','Accept-Ranges':'bytes'})
            return self.reply(data,'video/mp4')
        if path=='/leak':state['redirect_leaks']+=1;return self.reply()
        return self.reply(code=404)
    def do_POST(self):
        path=urllib.parse.urlparse(self.path);query=urllib.parse.parse_qs(path.query)
        body=self.rfile.read(int(self.headers.get('Content-Length',0)))
        if path.path=='/leak':state['redirect_leaks']+=1;return self.reply()
        if path.path=='/play':
            if self.server.mode=='deny':state['denied']+=1;return self.reply(code=401)
            if self.server.mode=='redirect':return self.reply(code=302,headers={'Location':self.server.base+'/leak'})
            try:
                values=plistlib.loads(body)
                assert self.headers.get('User-Agent')=='MediaControl/1.0'
                assert values['Start-Position']==0 and values['X-Apple-Session-ID']
                req=urllib.request.Request(values['Content-Location'],headers={'Range':'bytes=0-63'})
                with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req,timeout=5) as r:assert len(r.read())==64
            except Exception:return self.reply(code=500)
            state['reads']+=1;state['events'].append('play-accepted')
            if self.server.mode=='slow':time.sleep(0.8)
            state.update(ready=True,rate=1,position=0);state['plays']+=1;state['events'].append('play-completed')
            return self.reply()
        if path.path=='/rate':state['rate']=float(query['value'][0]);return self.reply()
        if path.path=='/scrub':state['position']=float(query['position'][0]);return self.reply()
        if path.path=='/stop':state.update(ready=False,rate=0);state['stops']+=1;state['events'].append('stop');return self.reply()
        return self.reply(code=404)

arch=sys.argv[1] if len(sys.argv)>1 else platform.machine()
if arch not in ('arm64','x86_64'):raise SystemExit('Expected arm64 or x86_64')
build=root/f'.build/{arch}-apple-macosx/release';frameworks=root/'dist/Release/TVBox.app/Contents/Frameworks'
folder=root/f'.build/airplay-video-check-{arch}/Contents/MacOS';folder.mkdir(parents=True,exist_ok=True)
if not (folder.parent/'Frameworks').exists():(folder.parent/'Frameworks').symlink_to(frameworks,target_is_directory=True)
sources=sorted(p for p in (root/'Sources/TVBoxMac').glob('*.swift') if p.name!='TVBoxMacApp.swift')
objects=list((build/'TVBoxCore.build').glob('*.o'))+list((build/'MPVBridge.build').glob('*.o'))
binary=folder/'check-airplay-video'
subprocess.run(['swiftc','-O','-parse-as-library','-target',f'{arch}-apple-macosx13.0','-I',str(build/'Modules'),'-Xcc','-fmodule-map-file='+str(build/'MPVBridge.build/module.modulemap'),'-I',str(root/'Sources/MPVBridge/include'),'-F',str(frameworks),'-framework','VLCKit','-framework','Sparkle',*map(str,sources),str(root/'scripts/check-airplay-video.swift'),*map(str,objects),'-o',str(binary)],check=True)
if '--real-device' in sys.argv:
    subprocess.run(['/opt/homebrew/bin/ffmpeg','-loglevel','error','-i',str(root/'.build/test.mp4'),'-t','20','-an','-c:v','copy','-movflags','+faststart','-y',str(root/'.build/airplay-controller-test.mp4')],check=True)
    subprocess.run(['arch',f'-{arch}',str(binary),'--real-device'],cwd=root,check=True,timeout=100)
    raise SystemExit(0)
servers=[]
for mode in ['normal','deny','redirect','slow']:
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);server.mode=mode;server.base=f'http://127.0.0.1:{server.server_port}'
    threading.Thread(target=server.serve_forever,daemon=True).start();servers.append(server)
try:
    subprocess.run(['arch',f'-{arch}',str(binary),*[s.base for s in servers]],cwd=root,check=True,timeout=100)
    assert state['plays']>=2 and state['stops']>=2 and state['reads']>=2 and state['denied']==1 and state['redirect_leaks']==0,state
    assert state['events'][-1]=='stop' and not state['ready'],state
    print('PASS: real HTTP binary-plist Play, Range fetch, rate/scrub/stop, auth and redirect refusal; late Play is stopped',arch)
finally:
    for server in servers:server.shutdown();server.server_close()
