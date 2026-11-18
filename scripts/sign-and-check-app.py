#!/usr/bin/env python3
"""Validate every packaged Mach-O, then sign inside out."""
from pathlib import Path
import subprocess
import sys
import hashlib
import json

app = Path(sys.argv[1]).resolve()
architectures = sys.argv[2:] or ['arm64', 'x86_64']
magics = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'}
executables = []
for path in app.rglob('*'):
    if path.is_symlink() or not path.is_file(): continue
    with path.open('rb') as stream:
        if stream.read(4) not in magics: continue
    relative = path.relative_to(app).parts
    required = architectures
    if 'CSPRuntime' in relative:
        runtime_index = relative.index('CSPRuntime')
        if len(relative) > runtime_index + 1 and relative[runtime_index + 1] in ['arm64', 'x86_64']:
            required = [relative[runtime_index + 1]]
    subprocess.run(['lipo', str(path), '-verify_arch', *required], check=True)
    deps = subprocess.check_output(['otool', '-L', str(path)], text=True)
    for line in deps.splitlines():
        if ' (compatibility version' not in line: continue
        dep = line.strip().split(' (compatibility version')[0]
        if not dep.startswith(('@rpath/', '@loader_path/', '@executable_path/', '/System/Library/', '/usr/lib/')):
            raise SystemExit(f'Non-portable dependency: {path.name}: {dep}')
    executables.append(path)
for path in sorted(executables, key=lambda x: len(x.parts), reverse=True):
    if path == app / 'Contents/MacOS/TVBoxMac': continue
    # Sparkle's signed nested installer/XPC bundles must retain their original
    # signatures. The official universal framework works in both app packages.
    if 'Sparkle.framework' in path.relative_to(app).parts: continue
    subprocess.run(['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements', str(path)], check=True, capture_output=True)
runtime = app / 'Contents/Resources/CSPRuntime'
if runtime.is_dir():
    def digest(path):
        value = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''): value.update(block)
        return value.hexdigest()
    manifest = {'version': 1, 'files': {str(path.relative_to(runtime)): digest(path) for path in runtime.rglob('*') if path.is_file() and path.name != 'manifest.json'}}
    (runtime / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
framework = app / 'Contents/Frameworks/VLCKit.framework'
subprocess.run(['codesign', '--force', '--sign', '-', str(framework)], check=True)
sparkle = app / 'Contents/Frameworks/Sparkle.framework'
if sparkle.exists():subprocess.run(['codesign', '--verify', '--strict', '--deep', str(sparkle)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--strict', '--deep', str(app)], check=True)
print(f'Validated and signed {len(executables)} portable Mach-O files for {architectures}')
