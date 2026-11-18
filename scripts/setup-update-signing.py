#!/usr/bin/env python3
"""One-time publisher setup; private keys stay outside the source tree."""
from pathlib import Path
import argparse,base64,os,plistlib,re,subprocess
project=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--repository',default='bikong0411/TVBox-For-MacOS');args=parser.parse_args()
if args.repository.rsplit('/',1)[-1] in ['.','..'] or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}',args.repository):raise SystemExit('Invalid repository')
subprocess.run(['python3',str(project/'scripts/prepare-sparkle.py')],check=True)
tool=project/'Vendor/SparkleDistribution/bin/generate_keys';account=args.repository.replace('/','.')
path=project/'Resources/Info.plist';info=plistlib.loads(path.read_bytes())
existing=subprocess.run([str(tool),'--account',account,'-p'],capture_output=True,text=True)
same_repository=info.get('TVBoxUpdateRepository','').casefold()==args.repository.casefold()
if existing.returncode and same_repository and info.get('SUPublicEDKey'):
    raise SystemExit('This repository already has a public key. Import its original private key into the Keychain; do not replace the published key.')
if existing.returncode:subprocess.run([str(tool),'--account',account],check=True,capture_output=True)
public=subprocess.check_output([str(tool),'--account',account,'-p'],text=True).strip()
if len(base64.b64decode(public,validate=True))!=32:raise SystemExit('Invalid signing public key')
if same_repository and info.get('SUPublicEDKey') and info['SUPublicEDKey']!=public:raise SystemExit('Keychain private key does not match the published public key')
info['SUPublicEDKey']=public;info['TVBoxUpdateRepository']=args.repository
info['SUFeedURL']=f'https://github.com/{args.repository}/releases/latest/download/appcast-AppleSilicon.xml'
path.write_bytes(plistlib.dumps(info,sort_keys=False))
folder=Path.home()/'Library/Application Support/TVBoxMac/UpdateSigning'/account;folder.mkdir(parents=True,exist_ok=True,mode=0o700);folder.chmod(0o700)
private=folder/'SPARKLE_PRIVATE_KEY.txt'
if not private.exists():subprocess.run([str(tool),'--account',account,'-x',str(private)],check=True,capture_output=True)
private.chmod(0o600)
print('Public update key configured for',args.repository)
print('Private key backup (not included in application or source):',private)
print('Create repository Actions secret SPARKLE_PRIVATE_KEY using this file; never commit it.')
