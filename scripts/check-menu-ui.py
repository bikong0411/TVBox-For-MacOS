#!/usr/bin/env python3
"""Launch the production UI with isolated content and an explicit test language."""
from pathlib import Path
import argparse, json, plistlib, shutil, subprocess, tempfile, uuid

parser=argparse.ArgumentParser()
parser.add_argument('language', choices=['en','zh-Hans'])
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
source=root/'dist/Release/TVBox.app/Contents'
case=Path(tempfile.mkdtemp(prefix='tvbox-menu-validation-'))
app=case/'TVBoxMenuTest.app';contents=app/'Contents'
(contents/'MacOS').mkdir(parents=True)
shutil.copy2(source/'MacOS/TVBoxMac',contents/'MacOS/TVBoxMac')
shutil.copytree(source/'Frameworks',contents/'Frameworks',symlinks=True)
for language in ['en','zh-Hans']:
    shutil.copytree(source/'Resources'/(language+'.lproj'),contents/'Resources'/(language+'.lproj'))
identifier='local.tvboxmac.validation.menus.'+uuid.uuid4().hex
info=plistlib.loads((source/'Info.plist').read_bytes())
info.update(CFBundleIdentifier=identifier,CFBundleName='TVBox Menu Test',CFBundleDisplayName='TVBox Menu Test')
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
subprocess.run(['defaults','write',identifier,'AppleLanguages','-array',args.language],check=True)
process=subprocess.Popen([str(contents/'MacOS/TVBoxMac'),'--ui-test','--ui-test-suite',identifier+'.content','-AppleLanguages','('+args.language+')'],stdout=(case/'stdout.log').open('w'),stderr=(case/'stderr.log').open('w'))
print(json.dumps({'app':str(app),'bundle':identifier,'pid':process.pid,'language':args.language}),flush=True)
process.wait()
