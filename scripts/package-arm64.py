#!/usr/bin/env python3
"""Produce an Apple Silicon package from the verified universal application."""
from pathlib import Path
import shutil,subprocess
root=Path(__file__).resolve().parent.parent
source=root/'dist/Release/TVBox.app';app=root/'dist/AppleSilicon/TVBox.app'
if app.exists():shutil.rmtree(app)
shutil.copytree(source,app,symlinks=True)
for relative in ['Contents/MacOS/TVBoxMac','Contents/Helpers/tvbox-remux','Contents/Resources/CSPRuntime/CSPRuntimeHost','Contents/Resources/CSPRuntime/gvproxy','Contents/Frameworks/VLCKit.framework/Versions/A/VLCKit']:
    path=app/relative;temporary=path.with_name(path.name+'.arm64')
    subprocess.run(['lipo',str(path),'-thin','arm64','-output',str(temporary)],check=True);temporary.replace(path)
unused=app/'Contents/Resources/CSPRuntime/x86_64'
if unused.exists():shutil.rmtree(unused)
subprocess.run(['python3',str(root/'scripts/configure-update-feed.py'),str(app/'Contents/Info.plist'),'--arch','arm64'],check=True)
subprocess.run(['python3',str(root/'scripts/sign-and-check-app.py'),str(app),'arm64'],check=True)
subprocess.run(['ditto','-c','-k','--keepParent',str(app),str(root/'dist/TVBox-macOS-AppleSilicon.zip')],check=True)
print(app)
