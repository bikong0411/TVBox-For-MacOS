#!/usr/bin/env python3
"""Validate every packaged Mach-O, then sign inside out."""
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
architectures = sys.argv[2:] or ['arm64', 'x86_64']
magics = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'}
executables = []
for path in app.rglob('*'):
    if path.is_symlink() or not path.is_file(): continue
    with path.open('rb') as stream:
        if stream.read(4) not in magics: continue
    subprocess.run(['lipo', str(path), '-verify_arch', *architectures], check=True)
    deps = subprocess.check_output(['otool', '-L', str(path)], text=True)
    for line in deps.splitlines():
        if ' (compatibility version' not in line: continue
        dep = line.strip().split(' (compatibility version')[0]
        if not dep.startswith(('@rpath/', '@loader_path/', '@executable_path/', '/System/Library/', '/usr/lib/')):
            raise SystemExit(f'Non-portable dependency: {path.name}: {dep}')
    executables.append(path)
for path in sorted(executables, key=lambda x: len(x.parts), reverse=True):
    if path == app / 'Contents/MacOS/TVBoxMac': continue
    subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True, capture_output=True)
framework = app / 'Contents/Frameworks/VLCKit.framework'
subprocess.run(['codesign', '--force', '--sign', '-', str(framework)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--strict', '--deep', str(app)], check=True)
print(f'Validated and signed {len(executables)} portable Mach-O files for {architectures}')
