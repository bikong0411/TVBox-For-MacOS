#!/usr/bin/env python3
"""Stamp release metadata in the CI checkout; never commit it back to Git."""
from pathlib import Path
import os
import plistlib
import re

root = Path(__file__).resolve().parent.parent
path = root / "Resources/Info.plist"
original = path.read_bytes()
info = plistlib.loads(original)
version = info["CFBundleShortVersionString"]
if os.environ.get("GITHUB_REF_TYPE") == "tag":
    tag = os.environ.get("GITHUB_REF_NAME", "")
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise SystemExit("Release tag must be vMAJOR.MINOR.PATCH, for example v0.8.1")
    run = os.environ.get("GITHUB_RUN_NUMBER", "")
    base = str(info["CFBundleVersion"])
    if not re.fullmatch(r"[1-9][0-9]*", run) or not re.fullmatch(r"[1-9][0-9]*", base):
        raise SystemExit("GITHUB_RUN_NUMBER and the source CFBundleVersion must be positive integers")
    build = int(base) + int(run)
    if build > 9999:
        raise SystemExit("Generated build number exceeds 9999; update the build-number scheme before releasing")
    version = tag[1:]
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = str(build)
    # Validate everything before writing; preserve all other plist values,
    # including application permissions.
    path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))
print(f"Building TVBox {version} (build {info['CFBundleVersion']})")
