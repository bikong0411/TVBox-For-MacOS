#!/usr/bin/env python3
"""Exercise handoff with real media and an injected route event, not a real TV."""
from pathlib import Path
import platform, subprocess, sys
root=Path(__file__).resolve().parent.parent
architecture=sys.argv[1] if len(sys.argv)>1 else platform.machine()
if architecture not in ('arm64','x86_64'):raise SystemExit('Expected arm64 or x86_64')
build=root/f'.build/{architecture}-apple-macosx/release'; frameworks=root/'dist/Release/TVBox.app/Contents/Frameworks'
folder=root/f'.build/airplay-check-{architecture}/Contents/MacOS';folder.mkdir(parents=True,exist_ok=True)
if not (folder.parent/'Frameworks').exists():(folder.parent/'Frameworks').symlink_to(frameworks,target_is_directory=True)
sources=sorted(p for p in (root/'Sources/TVBoxMac').glob('*.swift') if p.name!='TVBoxMacApp.swift')
objects=list((build/'TVBoxCore.build').glob('*.o'))+list((build/'MPVBridge.build').glob('*.o'))
binary=folder/'check-airplay'
subprocess.run(['swiftc','-O','-parse-as-library','-target',f'{architecture}-apple-macosx13.0','-I',str(build/'Modules'),'-Xcc','-fmodule-map-file='+str(build/'MPVBridge.build/module.modulemap'),'-I',str(root/'Sources/MPVBridge/include'),'-F',str(frameworks),'-framework','VLCKit',*map(str,sources),str(root/'scripts/check-airplay.swift'),*map(str,objects),'-o',str(binary)],check=True)
subprocess.run(['arch',f'-{architecture}',str(binary)],cwd=root,check=True,timeout=100)
