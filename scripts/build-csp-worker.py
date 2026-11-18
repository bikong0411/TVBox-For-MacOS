#!/usr/bin/env python3
"""Build the small Android-only CSP worker using pinned local SDK tools.

No Java installation is required by the Mac application. This is a build tool;
the resulting APK is executed only inside the private Android runtime.
"""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess, tarfile, zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--tools-dir', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
tools = (args.tools_dir or root/'.build/csp-tools').resolve()
work = root/'.build/csp-worker'; work.mkdir(parents=True,exist_ok=True)
extracted = tools/'extracted'; extracted.mkdir(exist_ok=True)

# Keep an unchanged APK byte-for-byte: ZIP timestamps would otherwise force a
# complete Android image rebuild on every packaging run.
source_inputs = [Path(__file__).resolve(), root/'Helpers/CSPWorker/AndroidManifest.xml',
                 root/'Helpers/CSPWorker/worker-development.p12',
                 *sorted((root/'Helpers/CSPWorker/src').rglob('*.java'))]
dependency_manifest = tools/'libraries/manifest.json'
if dependency_manifest.exists():
    source_inputs.append(dependency_manifest)
    for row in json.loads(dependency_manifest.read_text()):
        library = tools/'libraries'/row['file']
        if library.name != row['file'] or hashlib.sha256(library.read_bytes()).hexdigest() != row['sha256']:
            raise SystemExit('Worker dependency checksum mismatch')
source_inputs += [tools/name for name in ['jre.tar.gz','platform.zip','build-tools.zip','ecj.jar']]
fingerprint = hashlib.sha256()
for path in source_inputs:
    fingerprint.update(path.name.encode())
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''): fingerprint.update(block)
input_hash = fingerprint.hexdigest()
stamp = work/'inputs.json'
destination = work/'TVBoxCSPWorker.apk'
if stamp.exists() and destination.exists():
    previous = json.loads(stamp.read_text())
    if previous.get('inputs') == input_hash and previous.get('apk') == hashlib.sha256(destination.read_bytes()).hexdigest():
        print('Verified unchanged private Android worker:', destination)
        raise SystemExit(0)

def inside(path):
    return str(path.resolve()).startswith(str(extracted.resolve())+'/')

if not list(extracted.glob('*jre*')):
    with tarfile.open(tools/'jre.tar.gz') as archive:
        for member in archive:
            target=extracted/member.name
            if not inside(target): raise SystemExit('Invalid Java archive path')
            if member.issym() and not inside(target.parent/member.linkname): raise SystemExit('Invalid Java archive link')
        archive.extractall(extracted)
for name in ['platform.zip', 'build-tools.zip']:
    with zipfile.ZipFile(tools/name) as archive:
        for member in archive.infolist():
            if not inside(extracted/member.filename): raise SystemExit('Invalid SDK archive path')
        archive.extractall(extracted)

java_home = next(extracted.glob('*jre/Contents/Home'))
java = java_home/'bin/java'
android = extracted/'android-35/android.jar'
build_tools = extracted/'android-15'
for name in ['aapt2','zipalign']:
    (build_tools/name).chmod(0o755)
classes = work/'classes'; classes.mkdir(exist_ok=True)
dex = work/'dex'; dex.mkdir(exist_ok=True)
sources = sorted((root/'Helpers/CSPWorker/src').rglob('*.java'))
libraries = []
manifest = tools/'libraries/manifest.json'
if manifest.exists():
    for row in json.loads(manifest.read_text()):
        jar = tools/'libraries'/row['file']
        if jar.name != row['file'] or hashlib.sha256(jar.read_bytes()).hexdigest() != row['sha256']:
            raise SystemExit('Worker dependency checksum mismatch')
        libraries.append(jar)
subprocess.run([str(java),'-jar',str(tools/'ecj.jar'),'-source','8','-target','8','-proc:none','-encoding','UTF-8','-classpath',os.pathsep.join(map(str,[android,*libraries])),'-d',str(classes),*map(str,sources)],check=True)
subprocess.run([str(java),'-cp',str(build_tools/'lib/d8.jar'),'com.android.tools.r8.D8','--lib',str(android),'--min-api','26','--output',str(dex),*map(str,classes.rglob('*.class')),*map(str,libraries)],check=True)
unsigned = work/'unsigned.apk'
subprocess.run([str(build_tools/'aapt2'),'link','--manifest',str(root/'Helpers/CSPWorker/AndroidManifest.xml'),'-I',str(android),'-o',str(unsigned)],check=True)
with zipfile.ZipFile(unsigned,'a',zipfile.ZIP_DEFLATED) as archive:
    archive.write(dex/'classes.dex','classes.dex')
    for index, jar in enumerate(libraries):
        with zipfile.ZipFile(jar) as dependency:
            for member in dependency.namelist():
                if member.startswith('META-INF/') and any(tag in member.upper() for tag in ['LICENSE','NOTICE','COPYING']):
                    archive.writestr('assets/licenses/'+jar.stem+'/'+Path(member).name,dependency.read(member))
aligned = work/'aligned.apk'
subprocess.run([str(build_tools/'zipalign'),'-f','4',str(unsigned),str(aligned)],check=True)
keystore = work/'worker.p12'
development_key = root/'Helpers/CSPWorker/worker-development.p12'
if not keystore.exists() and development_key.exists(): shutil.copy2(development_key,keystore)
if not keystore.exists():
    subprocess.run([str(java_home/'bin/keytool'),'-genkeypair','-noprompt','-keystore',str(keystore),'-storetype','PKCS12','-storepass','tvbox-worker-development','-keypass','tvbox-worker-development','-alias','worker','-keyalg','RSA','-keysize','2048','-validity','10000','-dname','CN=TVBox Private CSP Worker'],check=True)
destination = work/'TVBoxCSPWorker.apk'
subprocess.run([str(java),'-jar',str(build_tools/'lib/apksigner.jar'),'sign','--ks',str(keystore),'--ks-pass','pass:tvbox-worker-development','--key-pass','pass:tvbox-worker-development','--out',str(destination),str(aligned)],check=True)
subprocess.run([str(java),'-jar',str(build_tools/'lib/apksigner.jar'),'verify',str(destination)],check=True)
print('Built private Android worker:',destination)
print('SHA256:',hashlib.sha256(destination.read_bytes()).hexdigest())
stamp.write_text(json.dumps({'inputs':input_hash,'apk':hashlib.sha256(destination.read_bytes()).hexdigest()})+'\n')
