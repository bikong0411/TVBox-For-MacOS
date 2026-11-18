#!/usr/bin/env python3
"""Set the release repository and default feed in a built app's Info.plist."""
import argparse,base64,os,plistlib,re
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('plist',type=Path);parser.add_argument('--arch',choices=['arm64','x86_64','universal'],required=True);parser.add_argument('--repository');args=parser.parse_args()
info=plistlib.loads(args.plist.read_bytes())
repository=args.repository or os.environ.get('GITHUB_REPOSITORY') or info.get('TVBoxUpdateRepository','')
if repository.rsplit('/',1)[-1] in ['.','..'] or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}',repository):raise SystemExit('Invalid update repository')
try:assert len(base64.b64decode(info['SUPublicEDKey'],validate=True))==32
except Exception:raise SystemExit('Configure the update signing public key before building')
suffix='Intel' if args.arch=='x86_64' else 'AppleSilicon'
info['TVBoxUpdateRepository']=repository
info['SUFeedURL']=f'https://github.com/{repository}/releases/latest/download/appcast-{suffix}.xml'
for flag in ['SUVerifyUpdateBeforeExtraction','SURequireSignedFeed']:info[flag]=True
args.plist.write_bytes(plistlib.dumps(info,sort_keys=False))
print('Configured signed update feed for',args.arch)
