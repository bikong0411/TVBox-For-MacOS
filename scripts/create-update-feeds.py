#!/usr/bin/env python3
"""Validate both native archives, then generate signed Sparkle feeds on macOS."""
from pathlib import Path
import argparse,base64,hashlib,json,os,plistlib,re,shutil,subprocess,tempfile,zipfile
import xml.etree.ElementTree as ET

project=Path(__file__).resolve().parent.parent
PACKAGES={'Intel':'TVBox-macOS-Intel.zip','AppleSilicon':'TVBox-macOS-AppleSilicon.zip'}
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
STABLE_TAG = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')

def validate_artifacts(folder,repository,tag,public_key):
    if repository.rsplit('/',1)[-1] in ['.','..'] or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}',repository):raise ValueError('Invalid release repository')
    if not STABLE_TAG.fullmatch(tag):raise ValueError('Only stable vMAJOR.MINOR.PATCH releases can be updates')
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

def previous_release(repository, tag, environment):
    def version(value):
        return tuple(map(int, value[1:].split('.')))

    response = subprocess.check_output(
        ['gh', 'release', 'list', '--repo', repository, '--exclude-drafts', '--exclude-pre-releases',
         '--limit', '100', '--json', 'tagName'], env=environment, timeout=30)
    tags = [release['tagName'] for release in json.loads(response)]
    earlier = [value for value in tags if STABLE_TAG.fullmatch(value) and version(value) < version(tag)]
    return max(earlier, key=version, default=None)

def feed_item(feed, url, build=None):
    for item in ET.parse(feed).findall('./channel/item'):
        enclosure = item.find('enclosure')
        if (enclosure is not None and enclosure.get('url') == url
                and (build is None or item.findtext(SPARKLE + 'version') == build)):
            return item, enclosure
    raise ValueError('No matching full package in appcast')

def verify_asset(path, enclosure, command):
    signature = enclosure.get(SPARKLE + 'edSignature')
    if not signature or enclosure.get('length') != str(path.stat().st_size):
        raise ValueError('Update asset signature or size is missing')
    command([str(path), signature])

def download_baseline(folder, repository, tag, arch, name, new_build, public_key, verify, environment):
    folder.mkdir()
    feed = folder / f'appcast-{arch}.xml'
    subprocess.run(['gh', 'release', 'download', tag, '--repo', repository, '--dir', str(folder),
                    '--pattern', name, '--pattern', feed.name], check=True, env=environment, timeout=180)
    verify([str(feed)])
    archive = folder / name
    item, enclosure = feed_item(feed, f'https://github.com/{repository}/releases/download/{tag}/{name}')
    verify_asset(archive, enclosure, verify)
    with zipfile.ZipFile(archive) as zipped:
        info = plistlib.loads(zipped.read('TVBox.app/Contents/Info.plist'))
    build = info.get('CFBundleVersion')
    if (info.get('CFBundleIdentifier') != 'local.tvboxmac' or info.get('CFBundleShortVersionString') != tag[1:]
            or info.get('SUPublicEDKey') != public_key or not isinstance(build, str)
            or build != item.findtext(SPARKLE + 'version') or not build.isascii() or not build.isdecimal()
            or int(build) >= int(new_build)):
        raise ValueError('Previous release does not contain a matching older TVBox build')
    return archive, build

def generate_feed(artifacts, repository, tag, arch, name, build, generator, run_signed, baseline=None):
    prefix = f'https://github.com/{repository}/releases/download/{tag}/'
    with tempfile.TemporaryDirectory(prefix='tvbox-appcast-') as temporary:
        work = Path(temporary)
        folder = work / 'archives'
        folder.mkdir()
        try:
            os.link(artifacts / name, folder / name)
        except OSError:
            shutil.copy2(artifacts / name, folder / name)
        if baseline:
            archive, old_build = baseline
            os.link(archive, folder / f'previous-{name}')
        (folder / (Path(name).stem + '.txt')).write_text(f'TVBox {tag[1:]}\n改进与修复详见版本记录。\n')
        output = folder / 'appcast.xml'
        run_signed(generator, ['--download-url-prefix', prefix, '--link', f'https://github.com/{repository}/releases',
                               '--embed-release-notes', '--maximum-deltas', '1' if baseline else '0',
                               '--maximum-versions', '1', '-o', str(output), str(folder)])
        item, _ = feed_item(output, prefix + name, build)
        if len(ET.parse(output).findall('./channel/item')) != 1:
            raise ValueError('Appcast must only advertise the current release')
        deltas = item.findall(f'{SPARKLE}deltas/enclosure')
        verifier = generator.with_name('sign_update')
        if deltas:
            if not baseline or len(deltas) != 1 or deltas[0].get(SPARKLE + 'deltaFrom') != old_build:
                raise ValueError('Unexpected delta source build')
            enclosure = deltas[0]
            old_url = enclosure.get('url', '')
            filename = old_url.removeprefix(prefix)
            if not re.fullmatch(r'[A-Za-z0-9_.-]+\.delta', filename):
                raise ValueError('Invalid generated delta URL')
            delta = folder / filename
            if delta.stat().st_size >= (artifacts / name).stat().st_size:
                raise ValueError('Generated delta is no smaller than the full package')
            verify_asset(delta, enclosure, lambda args: run_signed(verifier, ['--verify', *args]))
            # Both architectures can have the same bundle and build names. Give
            # each patch a unique asset name before signing the final feed.
            destination = artifacts / Path(name).with_suffix('.delta')
            text = output.read_text()
            old_attribute = f'url="{old_url}"'
            if text.count(old_attribute) != 1:
                raise ValueError('Generated delta URL did not match exactly one asset')
            output.write_text(text.replace(old_attribute, f'url="{prefix}{destination.name}"', 1))
            run_signed(verifier, [str(output)])
        run_signed(verifier, ['--verify', str(output)])
        if deltas:
            shutil.copy2(delta, destination)
            print(f'{arch}: {old_build} → {build}, delta {delta.stat().st_size} bytes / full {(artifacts / name).stat().st_size} bytes')
        shutil.copy2(output, artifacts / f'appcast-{arch}.xml')
        return bool(deltas)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--artifacts',type=Path,required=True);parser.add_argument('--repository',required=True);parser.add_argument('--tag',required=True);parser.add_argument('--key-file',type=Path)
    parser.add_argument('--deltas', action='store_true', help='Try a signed delta from the previous stable GitHub Release')
    args=parser.parse_args()
    info=plistlib.loads((project/'Resources/Info.plist').read_bytes())
    _, build = validate_artifacts(args.artifacts,args.repository,args.tag,info['SUPublicEDKey'])
    secret=args.key_file.read_bytes() if args.key_file else os.environ.get('SPARKLE_PRIVATE_KEY','').strip().encode()
    if not secret:raise SystemExit('Set the SPARKLE_PRIVATE_KEY Actions secret before publishing updates')
    environment=dict(os.environ);environment.pop('SPARKLE_PRIVATE_KEY',None)
    tool=project/'.build/update-key-tool';tool.parent.mkdir(exist_ok=True)
    subprocess.run(['swiftc','-O','-parse-as-library','-module-cache-path',str(project/'.build/update-key-cache'),str(project/'scripts/update-key.swift'),'-o',str(tool)],check=True,env=environment)
    result=subprocess.run([str(tool),'public'],input=secret,capture_output=True,env=environment,check=True)
    if result.stdout.decode().strip()!=info['SUPublicEDKey']:raise SystemExit('Signing secret does not match the public key embedded in the app')
    generator=project/'Vendor/SparkleDistribution/bin/generate_appcast'
    if not generator.is_file():subprocess.run(['python3',str(project/'scripts/prepare-sparkle.py')],check=True,env=environment)
    def run_signed(command, arguments):
        subprocess.run([str(command), '--ed-key-file', '-', *arguments], input=secret, check=True,
                       env=environment, timeout=360)

    previous = None
    if args.deltas:
        try:
            previous = previous_release(args.repository, args.tag, environment)
        except (subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
            print(f'Could not find a previous release ({error}); publishing full packages')
    for arch, name in PACKAGES.items():
        (args.artifacts / Path(name).with_suffix('.delta')).unlink(missing_ok=True)
        if previous:
            try:
                with tempfile.TemporaryDirectory(prefix='tvbox-delta-base-') as temporary:
                    baseline = download_baseline(Path(temporary) / 'baseline', args.repository, previous, arch,
                                                 name, build, info['SUPublicEDKey'],
                                                 lambda values: run_signed(generator.with_name('sign_update'), ['--verify', *values]),
                                                 environment)
                    if not generate_feed(args.artifacts, args.repository, args.tag, arch, name, build, generator,
                                         run_signed, baseline):
                        print(f'{arch}: Sparkle did not produce a delta; full package available')
                    continue
            except (subprocess.SubprocessError, OSError, ValueError, KeyError, ET.ParseError, zipfile.BadZipFile) as error:
                print(f'{arch}: skipping delta from {previous} ({error}); publishing the full package')
                (args.artifacts / Path(name).with_suffix('.delta')).unlink(missing_ok=True)
        generate_feed(args.artifacts, args.repository, args.tag, arch, name, build, generator, run_signed)
    print('Created and verified signed Intel / Apple Silicon update feeds')

if __name__=='__main__':main()
