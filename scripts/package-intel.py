#!/usr/bin/env python3
"""Produce a standalone Intel-only application from the verified universal app."""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
source = root / "dist/Release/TVBox.app"
app = root / "dist/Intel/TVBox.app"
if app.exists(): shutil.rmtree(app)
shutil.copytree(source, app, symlinks=True)
for relative in ["Contents/MacOS/TVBoxMac", "Contents/Helpers/tvbox-remux",
                 "Contents/Frameworks/VLCKit.framework/Versions/A/VLCKit"]:
    path = app / relative
    temporary = path.with_name(path.name + ".intel")
    subprocess.run(["lipo", str(path), "-thin", "x86_64", "-output", str(temporary)], check=True)
    temporary.replace(path)
subprocess.run(["python3", str(root / "scripts/sign-and-check-app.py"), str(app), "x86_64"], check=True)
subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(root / "dist/TVBox-macOS-Intel.zip")], check=True)
print(app)
