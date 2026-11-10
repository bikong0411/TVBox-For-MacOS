#!/usr/bin/env python3
"""Prepare an isolated bundle that follows the normal startup path."""
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
destination = root / "dist/TVBox-Validation.app"
shutil.copytree(root / "dist/Release/TVBox.app", destination, dirs_exist_ok=True)
info_path = destination / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
info["CFBundleIdentifier"] = "local.tvboxmac.validation.fullscreenfix.054"
info["CFBundleDisplayName"] = "TVBox 验证"
info["CFBundleName"] = "TVBox 验证"
info_path.write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True)
print(destination)
