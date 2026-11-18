#!/usr/bin/env python3
"""Extract the checksum-pinned official framework without altering signatures."""
from pathlib import Path
import hashlib,os,shutil,stat,subprocess,zipfile
root=Path(__file__).resolve().parent.parent
archive=root/'ThirdPartySources/Sparkle-2.10.0.zip'
if not archive.exists():subprocess.run(['python3',str(root/'scripts/fetch-dependencies.py')],check=True)
expected='17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959'
if hashlib.sha256(archive.read_bytes()).hexdigest()!=expected:raise SystemExit('Sparkle SDK checksum mismatch')
folder=root/'Vendor/SparkleDistribution'
stamp=folder/'archive.sha256'
if not stamp.exists() or stamp.read_text().strip()!=expected:
    folder.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(archive) as source:
        for item in source.infolist():
            if item.filename.split('/')[0] not in ['Sparkle.xcframework','bin','LICENSE']:continue
            path=folder/item.filename
            if not str(path.resolve()).startswith(str(folder.resolve())+'/'):raise SystemExit('Unsafe Sparkle archive path')
            if item.is_dir():path.mkdir(parents=True,exist_ok=True);continue
            path.parent.mkdir(parents=True,exist_ok=True)
            mode=item.external_attr>>16
            if stat.S_ISLNK(mode):
                target=source.read(item).decode()
                if not str((path.parent/target).resolve()).startswith(str(folder.resolve())+'/'):raise SystemExit('Unsafe Sparkle archive link')
                if not path.is_symlink():path.symlink_to(target)
            else:
                path.write_bytes(source.read(item));path.chmod(mode&0o777 or 0o644)
    stamp.write_text(expected+'\n')
target=root/'Vendor/Sparkle.xcframework'
if not target.exists():target.symlink_to('SparkleDistribution/Sparkle.xcframework',target_is_directory=True)
framework=next(target.glob('*/Sparkle.framework'))
subprocess.run(['codesign','--verify','--strict','--deep',str(framework)],check=True)
print('Verified official Sparkle 2.10.0 framework and update tools')
