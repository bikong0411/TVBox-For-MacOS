#!/usr/bin/env python3
"""Validate both native archives, then generate signed Sparkle feeds on macOS."""
from pathlib import Path
import argparse,base64,hashlib,os,plistlib,re,shutil,subprocess,tempfile,zipfile

project=Path(__file__).resolve().parent.parent
PACKAGES={'Intel':'TVBox-macOS-Intel.zip','AppleSilicon':'TVBox-macOS-AppleSilicon.zip'}
def validate_artifacts(folder,repository,tag,public_key):
    if repository.rsplit('/',1)[-1] in ['.','..'] or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}',repository):raise ValueError('Invalid release repository')
    if not re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)',tag):raise ValueError('Only stable vMAJOR.MINOR.PATCH releases can be updates')
    try:assert len(base64.b64decode(public_key,validate=True))==32
    except Exception:raise ValueError('Invalid update public key')
    versions=set()
    for arch,name in PACKAGES.items():
        archive=folder/name
        checksum=(folder/(Path(name).stem+'.sha256')).read_text().split()
        if len(checksum)!=2 or checksum[1].lstrip('*')!=name:raise ValueError('Invalid package checksum metadata')
        digest=hashlib.sha256()
        with archive.open('rb') as stream:
            for block in iter(lambda:stream.read(1024*1024),b''):digest.update(block)
        if digest.hexdigest()!=checksum[0].lower():raise ValueError('Release package checksum mismatch')
        with zipfile.ZipFile(archive) as source:info=plistlib.loads(source.read('TVBox.app/Contents/Info.plist'))
        if info.get('CFBundleIdentifier')!='local.tvboxmac' or info.get('CFBundleShortVersionString')!=tag[1:]:raise ValueError('Unexpected application or release version')
        if info.get('SUPublicEDKey')!=public_key or info.get('TVBoxUpdateRepository')!=repository:raise ValueError('Update key or repository differs between source and package')
        expected=f'https://github.com/{repository}/releases/latest/download/appcast-{arch}.xml'
        if info.get('SUFeedURL')!=expected or not info.get('SURequireSignedFeed') or not info.get('SUVerifyUpdateBeforeExtraction'):raise ValueError('Package does not enforce signed updates')
        versions.add((info['CFBundleShortVersionString'],info['CFBundleVersion']))
    if len(versions)!=1:raise ValueError('Native packages must have the same version and build')
    return next(iter(versions))

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--artifacts',type=Path,required=True);parser.add_argument('--repository',required=True);parser.add_argument('--tag',required=True);parser.add_argument('--key-file',type=Path);args=parser.parse_args()
    info=plistlib.loads((project/'Resources/Info.plist').read_bytes())
    validate_artifacts(args.artifacts,args.repository,args.tag,info['SUPublicEDKey'])
    secret=args.key_file.read_bytes() if args.key_file else os.environ.get('SPARKLE_PRIVATE_KEY','').strip().encode()
    if not secret:raise SystemExit('Set the SPARKLE_PRIVATE_KEY Actions secret before publishing updates')
    environment=dict(os.environ);environment.pop('SPARKLE_PRIVATE_KEY',None)
    tool=project/'.build/update-key-tool';tool.parent.mkdir(exist_ok=True)
    subprocess.run(['swiftc','-O','-parse-as-library','-module-cache-path',str(project/'.build/update-key-cache'),str(project/'scripts/update-key.swift'),'-o',str(tool)],check=True,env=environment)
    result=subprocess.run([str(tool),'public'],input=secret,capture_output=True,env=environment,check=True)
    if result.stdout.decode().strip()!=info['SUPublicEDKey']:raise SystemExit('Signing secret does not match the public key embedded in the app')
    generator=project/'Vendor/SparkleDistribution/bin/generate_appcast'
    if not generator.is_file():subprocess.run(['python3',str(project/'scripts/prepare-sparkle.py')],check=True,env=environment)
    for arch,name in PACKAGES.items():
        with tempfile.TemporaryDirectory(prefix='tvbox-appcast-') as temporary:
            folder=Path(temporary)
            try:os.link(args.artifacts/name,folder/name)
            except OSError:shutil.copy2(args.artifacts/name,folder/name)
            (folder/(Path(name).stem+'.txt')).write_text(f'TVBox {args.tag[1:]}\n改进与修复详见版本记录。\n')
            output=folder/'appcast.xml'
            subprocess.run([str(generator),'--ed-key-file','-','--download-url-prefix',f'https://github.com/{args.repository}/releases/download/{args.tag}/','--link',f'https://github.com/{args.repository}/releases','--embed-release-notes','--maximum-deltas','0','--maximum-versions','1','-o',str(output),str(folder)],input=secret,check=True,env=environment)
            verifier=generator.with_name('sign_update')
            subprocess.run([str(verifier),'--verify','--ed-key-file','-',str(output)],input=secret,check=True,env=environment)
            shutil.copy2(output,args.artifacts/f'appcast-{arch}.xml')
    print('Created and verified signed Intel / Apple Silicon update feeds')

if __name__=='__main__':main()
