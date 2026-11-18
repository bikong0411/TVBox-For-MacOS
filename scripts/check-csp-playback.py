#!/usr/bin/env python3
"""Exercise CSP resolution and real embedded playback using synthetic media/data."""
from pathlib import Path
import argparse, functools, http.server, os, platform, plistlib, shutil, socket, subprocess, threading, uuid,urllib.request

root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser()
parser.add_argument('--tools-dir',type=Path,default=root/'.build/csp-runtime/tools')
parser.add_argument('--build-only',action='store_true')
parser.add_argument('--run-only',action='store_true')
args=parser.parse_args()
architecture=platform.machine();build=root/f'.build/{architecture}-apple-macosx/release'
frameworks=root/'dist/Release/TVBox.app/Contents/Frameworks'
if not (build/'Modules/TVBoxCore.swiftmodule').exists():raise SystemExit('Build the release application first')
if not args.run_only:subprocess.run(['python3',str(root/'scripts/build-csp-fixture.py'),'--tools-dir',str(args.tools_dir)],check=True)
bundle=root/'.build/csp-playback-check.app';contents=bundle/'Contents';folder=contents/'MacOS';folder.mkdir(parents=True,exist_ok=True)
resources=contents/'Resources';resources.mkdir(exist_ok=True)
for path,target in [(contents/'Frameworks',frameworks),(resources/'CSPRuntime',root/'Vendor/CSPRuntime')]:
    if not path.exists():path.symlink_to(target,target_is_directory=True)
with (contents/'Info.plist').open('wb') as stream:plistlib.dump({'CFBundleIdentifier':'local.tvboxmac.csp-playback-check','CFBundleExecutable':'check-csp','CFBundlePackageType':'APPL','LSUIElement':True,'NSAppTransportSecurity':{'NSAllowsArbitraryLoads':True}},stream)
sources=sorted(p for p in (root/'Sources/TVBoxMac').glob('*.swift') if p.name!='TVBoxMacApp.swift')
objects=sorted((build/'TVBoxCore.build').glob('*.o'))+sorted((build/'MPVBridge.build').glob('*.o'))
binary=folder/'check-csp'
if not args.run_only:subprocess.run(['swiftc','-O','-module-cache-path',str(root/'.build/csp-playback-module-cache'),'-parse-as-library','-Xcc','-fmodule-map-file='+str(build/'MPVBridge.build/module.modulemap'),'-I',str(root/'Sources/MPVBridge/include'),'-target',architecture+'-apple-macosx13.0','-I',str(build/'Modules'),'-F',str(frameworks),'-framework','VLCKit','-framework','Sparkle','-Xlinker','-rpath','-Xlinker',str(frameworks),*map(str,sources),str(root/'scripts/check-csp-playback.swift'),*map(str,objects),'-o',str(binary)],check=True)
if args.build_only:raise SystemExit(0)
ffmpeg=shutil.which('ffmpeg')
if not ffmpeg:raise SystemExit('Test-only dependency missing: ffmpeg (lavfi + H.264)')
media=root/'.build/csp-playback-test.mp4'
subprocess.run([ffmpeg,'-v','error','-y','-f','lavfi','-i','testsrc2=size=320x180:rate=24','-t','30','-an','-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p','-movflags','+faststart',str(media)],check=True)
address=''
for interface in ['en0','en1']:
    result=subprocess.run(['/usr/sbin/ipconfig','getifaddr',interface],capture_output=True,text=True)
    if result.returncode==0:address=result.stdout.strip();break
if not address:raise SystemExit('Test requires an active local network interface')
if address.startswith('127.'):raise SystemExit('Test requires an active local network interface')
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_HEAD(self):self.serve(False)
    def do_GET(self):self.serve(True)
    def serve(self,body):
        self.server.requests+=1
        if self.path!='/test.mp4' or self.headers.get('User-Agent')!='TVBoxCSPFixture' or self.headers.get('Referer')!='https://fixture.invalid/':
            self.server.rejected+=1
            self.send_error(403);return
        data=media.read_bytes();start=0;end=len(data)-1
        value=self.headers.get('Range')
        if value:
            try:
                first,last=value.removeprefix('bytes=').split('-',1);start=int(first);end=min(int(last) if last else end,end)
                if start<0 or start>end:raise ValueError()
            except ValueError:self.send_error(416);return
        self.send_response(206 if value else 200);self.send_header('Content-Type','video/mp4');self.send_header('Accept-Ranges','bytes')
        self.send_header('Content-Length',str(end-start+1))
        if value:self.send_header('Content-Range',f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        if body:
            try:self.wfile.write(data[start:end+1])
            except (BrokenPipeError,ConnectionResetError):pass
server=http.server.ThreadingHTTPServer((address,0),Handler)
server.requests=0;server.rejected=0
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
environment=dict(os.environ,CSP_FIXTURE=str(root/'.build/csp-fixture/fixture.jar'),CSP_TEST_MEDIA=f'http://{address}:{server.server_port}/test.mp4')
for name in list(environment):
    if name.lower() in ['http_proxy','https_proxy','all_proxy']:environment.pop(name)
request=urllib.request.Request(environment['CSP_TEST_MEDIA'],headers={'User-Agent':'TVBoxCSPFixture','Referer':'https://fixture.invalid/'})
with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request,timeout=3) as response:
    assert response.status==200 and response.read(8)[4:]==b'ftyp','Synthetic media server is not reachable'
print('Verified synthetic HTTP media origin',flush=True)
try:subprocess.run([str(binary),'--ui-test','--ui-test-suite','local.tvboxmac.csp-check.'+uuid.uuid4().hex],env=environment,cwd=root,check=True,timeout=180)
finally:
    server.shutdown();server.server_close()
    print('Synthetic media requests:',server.requests,'rejected:',server.rejected,flush=True)
