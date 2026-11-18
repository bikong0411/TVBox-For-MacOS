#!/usr/bin/env python3
"""Prepare isolated, signed update apps and serve only synthetic public files.

The manual case exercises the real Sparkle install/relaunch UI. The automatic
case waits for downloaded-on-quit state; quitting it should install build 2.
"""
from pathlib import Path
import argparse,hashlib,http.server,json,os,plistlib,shutil,socket,subprocess,tempfile,threading,time,urllib.parse,uuid
import xml.etree.ElementTree as ET
root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--mode',choices=['manual','automatic','ready-install','no-update','tampered-feed','tampered-archive','delta','delta-fallback'],default='manual');args=parser.parse_args()
delta_test = args.mode in ['delta', 'delta-fallback']
install_on_quit = delta_test or args.mode == 'automatic'
delta_path = None
downloads = []
case=Path(tempfile.mkdtemp(prefix='tvbox-update-validation-'));case.chmod(0o700)
public=case/'public';public.mkdir();caseid=uuid.uuid4().hex[:12]
bundleid='local.tvboxmac.validation.update.'+caseid
framework=next((root/'Vendor/Sparkle.xcframework').glob('*/Sparkle.framework'))
build=root/'.build/arm64-apple-macosx/release'
binary=case/'update-validation'
subprocess.run(['swiftc','-O','-parse-as-library','-target','arm64-apple-macos13.0','-module-cache-path',str(root/'.build/update-validation-cache'),'-I',str(build/'Modules'),'-F',str(framework.parent),'-framework','Sparkle','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',str(root/'Sources/TVBoxMac/Localization.swift'),str(root/'Sources/TVBoxMac/AppUpdateController.swift'),str(root/'scripts/check-app-update.swift'),*map(str,sorted((build/'TVBoxCore.build').glob('*.o'))),'-o',str(binary)],check=True)
keytool=root/'.build/update-key-tool'
subprocess.run(['swiftc','-O','-parse-as-library','-module-cache-path',str(root/'.build/update-key-cache'),str(root/'scripts/update-key.swift'),'-o',str(keytool)],check=True)
private=case/'test-key.txt';key=subprocess.check_output([str(keytool),'generate',str(private)],text=True).strip()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):self.serve(False)
    def do_HEAD(self):self.serve(True)
    def serve(self,head):
        path=urllib.parse.urlsplit(self.path).path
        if path not in ['/appcast.xml','/Validation-2.zip',delta_path]:
            self.send_error(404);return
        if not head and path != '/appcast.xml': downloads.append(path)
        if args.mode == 'delta-fallback' and path == delta_path:
            self.send_error(404);return
        file=public/path[1:]
        if not file.exists():self.send_error(404);return
        data=file.read_bytes();self.send_response(200);self.send_header('Content-Type','application/xml' if path.endswith('.xml') else 'application/zip');self.send_header('Content-Length',str(len(data)));self.end_headers()
        if not head:
            try:self.wfile.write(data)
            except (ConnectionResetError,BrokenPipeError):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
feed=f'http://127.0.0.1:{server.server_port}/appcast.xml'
def make_app(folder,number):
    app=folder/'UpdateValidation.app';contents=app/'Contents';(contents/'MacOS').mkdir(parents=True)
    (contents/'Frameworks').mkdir();shutil.copytree(framework,contents/'Frameworks/Sparkle.framework',symlinks=True)
    shutil.copy2(binary,contents/'MacOS/UpdateValidation')
    info={'CFBundleIdentifier':bundleid,'CFBundleExecutable':'UpdateValidation','CFBundlePackageType':'APPL','CFBundleName':'TVBox 更新验证','CFBundleDisplayName':'TVBox 更新验证','CFBundleVersion':str(number),'CFBundleShortVersionString':'0.0.'+str(number),'LSMinimumSystemVersion':'13.0','NSPrincipalClass':'NSApplication','NSAppTransportSecurity':{'NSAllowsArbitraryLoads':True},'TVBoxUpdateRepository':'example/TVBox','SUPublicEDKey':key,'SUFeedURL':feed,'SUEnableAutomaticChecks':args.mode!='manual','SUAutomaticallyUpdate':args.mode!='manual','SUAllowsAutomaticUpdates':True,'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,'ValidationDirectory':str(case),'ValidationMode':args.mode,'ValidationFeedURL':feed}
    if delta_test: info['ValidationMode'] = 'automatic'
    (contents/'Info.plist').write_bytes(plistlib.dumps(info));subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    return app
old=make_app(case/'old',2 if args.mode=='no-update' else 1);new=make_app(case/'new',2)
subprocess.run(['ditto','-c','-k','--keepParent',str(new),str(public/'Validation-2.zip')],check=True)
generator=root/'Vendor/SparkleDistribution/bin/generate_appcast'
if delta_test:
    subprocess.run(['ditto','-c','-k','--keepParent',str(old),str(public/'Validation-1.zip')],check=True)
subprocess.run([str(generator),'--ed-key-file',str(private),'--download-url-prefix',f'http://127.0.0.1:{server.server_port}/','--maximum-deltas','1' if delta_test else '0','--maximum-versions','1','-o',str(public/'appcast.xml'),str(public)],check=True)
if delta_test:
    sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    enclosure, = ET.parse(public/'appcast.xml').findall(f'./channel/item/{sparkle}deltas/enclosure')
    delta_path = urllib.parse.urlsplit(enclosure.attrib['url']).path
if args.mode=='tampered-feed':
    data=(public/'appcast.xml').read_bytes();(public/'appcast.xml').write_bytes(data.replace(b'0.0.2',b'0.0.3'))
if args.mode=='tampered-archive':
    with (public/'Validation-2.zip').open('ab') as stream:stream.write(b'changed-after-signing')
state={'case':str(case),'app':str(old),'bundle':bundleid,'mode':args.mode,'feed':feed}
(case/'state.json').write_text(json.dumps(state));print('VALIDATION_STATE '+json.dumps(state),flush=True)
threading.Thread(target=server.serve_forever,daemon=True).start()
subprocess.run(['open','-n',str(old)],check=True)
try:
    quit_requested=False
    deadline=time.monotonic()+300
    while time.monotonic()<deadline:
        info=plistlib.loads((old/'Contents/Info.plist').read_bytes())
        if install_on_quit and (case/'ready-1.json').exists() and not quit_requested:
            assert info['CFBundleVersion']=='1','Update installed before ordinary quit'
            assert not (case/'early-termination-1.json').exists(),'Background update tried to interrupt the running application'
            (case/'allow-quit').touch();quit_requested=True
        if args.mode=='no-update':
            if (case/'up-to-date-2.json').exists():print('PASS latest installed version detected; no replacement performed',flush=True);break
            time.sleep(.3);continue
        if args.mode.startswith('tampered') and (case/'failure-1.json').exists():
            assert info['CFBundleVersion']=='1';print('PASS '+args.mode+' rejected; installed app unchanged',flush=True);break
        if info['CFBundleVersion']=='2':
            if install_on_quit:assert quit_requested and (case/'terminate-1.json').exists()
            if delta_test:
                assert delta_path in downloads, 'Sparkle did not request the delta'
                assert ('/Validation-2.zip' in downloads) == (args.mode == 'delta-fallback')
            if args.mode in ['manual','ready-install'] and not (case/'launch-2.json').exists():time.sleep(.2);continue
            if args.mode in ['manual','ready-install']:assert json.loads((case/'launch-2.json').read_text())['sentinel']=='preserved'
            print('PASS real '+args.mode+' update: build 1 replaced by build 2'+('; relaunch and preferences preserved' if args.mode in ['manual','ready-install'] else '; install on quit'),flush=True);break
        time.sleep(.3)
    else:raise RuntimeError('Update validation deadline exceeded')
finally:
    (case/'allow-quit').touch()
    server.shutdown();server.server_close()
