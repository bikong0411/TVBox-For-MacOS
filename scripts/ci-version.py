#!/usr/bin/env python3
"""Reject release tags that disagree with the actual application version."""
from pathlib import Path
import os
import plistlib

root = Path(__file__).resolve().parent.parent
info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
version = info["CFBundleShortVersionString"]
if os.environ.get("GITHUB_REF_TYPE") == "tag":
    tag = os.environ.get("GITHUB_REF_NAME", "")
    if tag != "v" + version:
        raise SystemExit(f"Tag {tag!r} must match Info.plist version: v{version}")
print(f"Building TVBox {version} (build {info['CFBundleVersion']})")
