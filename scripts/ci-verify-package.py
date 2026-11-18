#!/usr/bin/env python3
"""Inspect the actual ZIP produced by CI before making it downloadable."""
from pathlib import Path
import plistlib
import sys
import json
import hashlib
import base64
from zipfile import ZipFile

root = Path(__file__).resolve().parent.parent
expected = plistlib.loads((root / "Resources/Info.plist").read_bytes())
with ZipFile(sys.argv[1]) as archive:
    bad = archive.testzip()
    if bad is not None:
        raise SystemExit(f"Corrupt ZIP member: {bad}")
    prefix = "TVBox.app/Contents/"
    actual = plistlib.loads(archive.read(prefix + "Info.plist"))
    for key in ["CFBundleShortVersionString", "CFBundleVersion"]:
        if actual[key] != expected[key]:
            raise SystemExit(f"Packaged {key} differs from source")
    try:assert len(base64.b64decode(actual['SUPublicEDKey'],validate=True))==32
    except Exception:raise SystemExit('Package is missing a valid update signing public key')
    if actual.get('SUPublicEDKey')!=expected.get('SUPublicEDKey') or not actual.get('SURequireSignedFeed') or not actual.get('SUVerifyUpdateBeforeExtraction'):
        raise SystemExit('Package does not enforce signed update verification')
    sparkle=[name for name in archive.namelist() if name.startswith(prefix+'Frameworks/Sparkle.framework/Versions/') and name.endswith('/Sparkle')]
    if not any(archive.getinfo(name).file_size>0 for name in sparkle):raise SystemExit('Update framework missing from package')
    if not {'en', 'zh-Hans'} <= set(actual.get('CFBundleLocalizations', [])):
        raise SystemExit('Package is missing supported interface languages')
    for language in ['en', 'zh-Hans']:
        for name in ['Localizable.strings', 'InfoPlist.strings']:
            if not archive.getinfo(prefix + 'Resources/' + language + '.lproj/' + name).file_size:
                raise SystemExit('Empty localization resource')
    for relative in ["MacOS/TVBoxMac", "Helpers/tvbox-remux",
                     "Frameworks/VLCKit.framework/Versions/A/VLCKit",
                     "Resources/FFmpeg-LICENSE.txt", "Resources/VLCKit-LICENSE.txt",
                     "Resources/CSPRuntime/CSPRuntimeHost", "Resources/CSPRuntime/manifest.json",
                     "Resources/CSPRuntime/system.qcow2", "Resources/CSPRuntime/data-template.qcow2"]:
        if not archive.getinfo(prefix + relative).file_size:
            raise SystemExit(f"Empty package member: {relative}")
    runtime = prefix + 'Resources/CSPRuntime/'
    manifest = json.loads(archive.read(runtime + 'manifest.json'))
    if manifest.get('version') != 1 or not isinstance(manifest.get('files'),dict):raise SystemExit('Invalid runtime manifest')
    required=['CSPRuntimeHost','gvproxy','kernel','bootstrap.cpio.gz','system.qcow2','data-template.qcow2']
    package=Path(sys.argv[1]).name
    arches=['arm64','x86_64'] if 'Universal' in package else ['x86_64'] if 'Intel' in package else ['arm64'] if 'AppleSilicon' in package else []
    for arch in arches:required += [arch+'/bin/qemu-system-aarch64',arch+'/lib/libglib-2.0.0.dylib']
    for name in required:
        if name not in manifest['files'] or not archive.getinfo(runtime+name).file_size:raise SystemExit('Missing runtime component: '+name)
    for name, expected_hash in manifest['files'].items():
        if name.startswith('/') or '..' in Path(name).parts: raise SystemExit('Invalid runtime manifest path')
        digest = hashlib.sha256()
        with archive.open(runtime + name) as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''): digest.update(block)
        if digest.hexdigest() != expected_hash: raise SystemExit('Runtime checksum mismatch: ' + name)
print(f"Verified application ZIP: {Path(sys.argv[1]).name}")
