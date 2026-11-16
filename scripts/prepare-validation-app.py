#!/usr/bin/env python3
"""Prepare an isolated bundle that follows the normal startup path."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
intel = len(sys.argv) > 1 and sys.argv[1] == "intel"
destination = root / ("dist/TVBox-Intel-Validation.app" if intel else "dist/TVBox-Validation.app")
release = root / ("dist/Intel/TVBox.app" if intel else "dist/Release/TVBox.app")
if destination.exists(): shutil.rmtree(destination)
shutil.copytree(release, destination, symlinks=True)
info_path = destination / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
version = info["CFBundleShortVersionString"].replace(".", "")
info["CFBundleIdentifier"] = "local.tvboxmac.validation.component." + version + (".intel" if intel else "")
info["CFBundleDisplayName"] = "TVBox 验证"
info["CFBundleName"] = "TVBox 验证"
info_path.write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True)
print(destination)
