#!/usr/bin/env python3
"""Reproducibly assemble the private CSP runtime from checksum-pinned inputs.

Build dependencies only: Python 3.9+, Xcode/CLT, pkg-config and e2fsprogs.
The distributed application needs none of Java, Python, Homebrew or Android SDK.
"""
from pathlib import Path, PurePosixPath
import argparse, concurrent.futures, hashlib, json, os, platform, posixpath, shutil, subprocess, sys, tarfile, time

project=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--arch',choices=['arm64','x86_64','universal'],default=platform.machine())
parser.add_argument('--build-root',type=Path,default=project/'.build/csp-runtime')
args=parser.parse_args();root=args.build_root.resolve();root.mkdir(parents=True,exist_ok=True)
host=platform.machine();arches=['arm64','x86_64'] if args.arch=='universal' else [args.arch]
scripts=project/'scripts/csp';destination=project/'Vendor/CSPRuntime'
sys.path.insert(0,str(scripts))
from download import fetch as verified_fetch
environment=dict(os.environ,CSP_BUILD_ROOT=str(root))
def run(command,**kwargs):subprocess.run([str(x) for x in command],env=environment,check=True,**kwargs)
def sha(path):
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):digest.update(block)
    return digest.hexdigest()
def fetch(row):
    verified_fetch(row,root)
downloads=[row for row in json.loads((scripts/'downloads.json').read_text()) if row.get('host',host)==host]
libraries=json.loads((project/'Helpers/CSPWorker/dependencies.json').read_text())
downloads += [dict(name='tools/libraries/'+row['file'],url=row['url'],sha256=row['sha256']) for row in libraries]
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(fetch,downloads))
(root/'tools/libraries/manifest.json').write_text(json.dumps(libraries,indent=2)+'\n')
(root/'tools/gvproxy').chmod(0o755)

def extract(archive, target, *, omit_symlink=None):
    target.mkdir(parents=True,exist_ok=True)
    with tarfile.open(archive) as source:
        members = []
        for member in source:
            if member.name.startswith('/') or '..' in PurePosixPath(member.name).parts:raise RuntimeError('Archive path escapes build directory')
            if member.issym() and (member.name, member.linkname) == omit_symlink:
                continue
            if member.issym() or member.islnk():
                base = posixpath.dirname(member.name) if member.issym() else ''
                link = posixpath.normpath(posixpath.join(base, member.linkname))
                if member.linkname.startswith('/') or link == '..' or link.startswith('../'):
                    raise RuntimeError(f'Archive link escapes build directory: {archive.name}: {member.name!r} -> {member.linkname!r}')
            members.append(member)
        source.extractall(target, members=members)

def deb_files(archive,target,predicate):
    members=subprocess.check_output(['ar','-t',str(archive)],text=True).splitlines()
    member=next(name for name in members if name.startswith('data.tar.'))
    process=subprocess.Popen(['ar','p',str(archive),member],stdout=subprocess.PIPE)
    with tarfile.open(fileobj=process.stdout,mode='r|*') as source:
        for entry in source:
            name=entry.name.removeprefix('./') if hasattr(str,'removeprefix') else entry.name.lstrip('./')
            if not entry.isfile() or not predicate(name):continue
            if name.startswith('/') or '..' in PurePosixPath(name).parts:raise RuntimeError('Invalid Debian file path')
            path=target/name;path.parent.mkdir(parents=True,exist_ok=True)
            with source.extractfile(entry) as incoming,path.open('wb') as outgoing:shutil.copyfileobj(incoming,outgoing)
            path.chmod(entry.mode & 0o777)
    assert process.wait()==0

if not (root/'kernel/boot/vmlinuz-6.1.0-56-arm64').exists():
    deb_files(root/'linux-arm64.deb',root/'kernel',lambda n:n.startswith('boot/') or n.startswith('lib/modules/') and '.ko' in n)
if not (root/'busybox').exists():
    deb_files(root/'busybox-arm64.deb',root/'busybox-package',lambda n:n.endswith('/busybox'))
    shutil.copy2(next((root/'busybox-package').rglob('busybox')),root/'busybox')

source=root/'qemu-source/qemu-darwin-arm64-v0.1.0-sources'
if not source.exists():extract(root/'qemu-sources.tar',root/'qemu-source')
# The pinned QEMU tarball ships an EDK II host-emulator link to XQuartz.
# Our QEMU build never builds the EDK II host emulator.
x11_link = ('qemu-10.2.4/roms/edk2/EmulatorPkg/Unix/Host/X11IncludeHack', '/opt/X11/include')
for name,expected in [('qemu-10.2.4.tar.xz','821b545b92f165e57dddccac5077d76d4d436a226595b8813ad59306bbfd0746'),('glib-2.88.4.tar.xz','25fd169f3b2f91fe2391ad297883ce0fcf30c69fc789ffd1c9672d1332b1c5a8')]:
    assert sha(source/name)==expected
    if not (source/'src'/name.split('.tar')[0]).exists():
        extract(source/name, source/'src', omit_symlink=x11_link if name == 'qemu-10.2.4.tar.xz' else None)
cache=source/'src/glib-2.88.4/subprojects/packagecache';cache.mkdir(exist_ok=True)
for path in (source/'glib-subprojects').iterdir():shutil.copy2(path,cache/path.name)
if not (source/'dtc-extracted/dtc/libfdt').exists():extract(source/'qemu-subproject-dtc.tar.gz',source/'dtc-extracted')
venv=root/'build-venv'
if not (venv/'bin/meson').exists():
    run([sys.executable,'-m','venv',venv])
    run([venv/'bin/pip','install','--disable-pip-version-check','meson==1.9.0','ninja==1.13.0'])
if not shutil.which('pkg-config'):raise SystemExit('Build dependency missing: brew install pkgconf')
e2fs=os.environ.get('CSP_E2FSPROGS')
if not e2fs:
    e2fs=subprocess.check_output(['brew','--prefix','e2fsprogs'],text=True).strip()
environment['CSP_E2FSPROGS']=e2fs
if not (Path(e2fs)/'sbin/mke2fs').is_file():raise SystemExit('Build dependency missing: brew install e2fsprogs')
run([sys.executable,project/'scripts/build-csp-worker.py','--tools-dir',root/'tools'])
for architecture in dict.fromkeys(arches+[host]):run([sys.executable,scripts/'build-emulator.py',architecture])
run([sys.executable,scripts/'make-bootstrap.py'])
image_inputs=[project/'Helpers/CSPWorker/AndroidManifest.xml',*sorted((project/'Helpers/CSPWorker/src').rglob('*.java')),project/'.build/csp-worker/TVBoxCSPWorker.apk',scripts/'build-image.py',scripts/'finalize-image.py']
image_hash=hashlib.sha256(''.join(sha(path) for path in image_inputs).encode()).hexdigest()
stamp=root/'image-inputs.sha256'
rebuild=not stamp.exists() or stamp.read_text()!=image_hash or not (root/'android-system.raw').exists()
if rebuild:
    run([sys.executable,scripts/'build-image.py']);run([sys.executable,scripts/'finalize-image.py'])
    stamp.write_text(image_hash)

destination.mkdir(parents=True,exist_ok=True)
entitlements=root/'hvf-entitlements.plist'
entitlements.write_text('<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>')
for architecture in arches:
    build=root/('emulator-arm64/qemu-build' if architecture=='arm64' else 'emulator-x86_64-cross/qemu-cross-build')
    prefix=build.parent/'deps'
    target=destination/architecture
    (target/'bin').mkdir(parents=True,exist_ok=True);(target/'lib').mkdir(exist_ok=True)
    binary=target/'bin/qemu-system-aarch64';glib=target/'lib/libglib-2.0.0.dylib'
    shutil.copy2(build/'qemu-system-aarch64-unsigned',binary);shutil.copy2(prefix/'lib/libglib-2.0.0.dylib',glib)
    run(['install_name_tool','-change',prefix/'lib/libglib-2.0.0.dylib','@rpath/libglib-2.0.0.dylib',binary])
    lines=subprocess.check_output(['otool','-l',str(binary)],text=True).splitlines()
    for index,line in enumerate(lines):
        if line.strip()=='cmd LC_RPATH':run(['install_name_tool','-delete_rpath',lines[index+2].strip().split(' ',2)[1],binary])
    run(['install_name_tool','-add_rpath','@executable_path/../lib',binary])
    run(['install_name_tool','-id','@rpath/libglib-2.0.0.dylib',glib])
    run(['codesign','--force','--sign','-',glib])
    signing=['codesign','--force','--sign','-']
    if architecture=='arm64':signing+=['--entitlements',entitlements]
    run(signing+[binary])
helpers=[]
for architecture in arches:
    helper=root/('CSPRuntimeHost-'+architecture);helpers.append(helper)
    run(['swiftc','-O','-module-cache-path',root/('swift-cache-'+architecture),'-target',architecture+'-apple-macos13',project/'Helpers/CSPRuntimeHost.swift','-o',helper])
run(['lipo','-create',*helpers,'-output',destination/'CSPRuntimeHost'])
run(['codesign','--force','--sign','-',destination/'CSPRuntimeHost'])
for original,name in [(root/'tools/gvproxy','gvproxy'),(root/'kernel/boot/vmlinuz-6.1.0-56-arm64','kernel'),(root/'bootstrap.cpio.gz','bootstrap.cpio.gz')]:shutil.copy2(original,destination/name)
image_tool=root/('emulator-arm64/qemu-build/qemu-img' if host=='arm64' else 'emulator-x86_64-cross/qemu-cross-build/qemu-img')
for original,name in [(root/'android-system.raw','system.qcow2'),(root/'android-data-template.raw','data-template.qcow2')]:
    if rebuild or not (destination/name).exists():run([image_tool,'convert','-f','raw','-O','qcow2','-c',original,destination/name])
notices=destination/'licenses';notices.mkdir(exist_ok=True)
for relative,label in [('src/qemu-10.2.4/COPYING','QEMU-GPL-2.0.txt'),('src/qemu-10.2.4/COPYING.LIB','QEMU-LGPL-2.1.txt'),('src/glib-2.88.4/COPYING','GLib-LGPL-2.1.txt')]:shutil.copy2(source/relative,notices/label)
android_notice=root/'android-root/system/etc/NOTICE.xml.gz'
if android_notice.exists():shutil.copy2(android_notice,notices/'Android-NOTICE.xml.gz')
shutil.copy2(project/'Helpers/CSPWorker/dependencies.json',notices/'worker-dependencies.json')
shutil.copy2(root/'gvproxy-LICENSE.txt',notices/'gvproxy-Apache-2.0.txt')
manifest={'version':1,'files':{str(p.relative_to(destination)):sha(p) for p in destination.rglob('*') if p.is_file() and p.name!='manifest.json'}}
(destination/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
# Cache only framework initialization, never a runtime that has loaded a source.
factory_hash=hashlib.sha256(''.join([image_hash,sha(scripts/'prewarm.py'),sha(destination/'bootstrap.cpio.gz')]).encode()).hexdigest()
factory_stamp=root/'factory-inputs.sha256';factory_cache=root/'factory-template.qcow2'
if factory_stamp.exists() and factory_stamp.read_text()==factory_hash and factory_cache.exists():
    shutil.copy2(factory_cache,destination/'data-template.qcow2')
else:
    run([image_tool,'convert','-f','raw','-O','qcow2','-c',root/'android-data-template.raw',destination/'data-template.qcow2'])
    manifest['files']['data-template.qcow2']=sha(destination/'data-template.qcow2')
    (destination/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    factory=[sys.executable,scripts/'prewarm.py','--assets',destination,'--build-root',root,'--image-tool',image_tool,'--e2fsprogs',e2fs]
    # Hosted macOS runners may not provide nested hardware virtualization.
    if host!='arm64' or os.environ.get('GITHUB_ACTIONS')=='true':factory.append('--emulate')
    run(factory)
    shutil.copy2(destination/'data-template.qcow2',factory_cache);factory_stamp.write_text(factory_hash)
manifest['files']['data-template.qcow2']=sha(destination/'data-template.qcow2')
(destination/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Prepared standalone CSP runtime for',', '.join(arches),flush=True)
