#!/usr/bin/env python3
"""Inspect the actual ZIP produced by CI before making it downloadable."""
from pathlib import Path
import plistlib
import sys
from zipfile import ZipFile

root = Path(__file__).resolve().parent.parent
expected = plistlib.loads((root / "Resources/Info.plist").read_bytes())
with ZipFile(sys.argv[1]) as archive:
    bad = archive.testzip()
    if bad is not None:
        raise SystemExit(f"Corrupt ZIP member: {bad}")
    prefix = "TVBox.app/Contents/"
    actual = plistlib.loads(archive.read(prefix + "Info.plist"))
    for key in ["CFBundleShortVersionString", "CFBundleVersion"]:
        if actual[key] != expected[key]:
            raise SystemExit(f"Packaged {key} differs from source")
    for relative in ["MacOS/TVBoxMac", "Helpers/tvbox-remux",
                     "Frameworks/VLCKit.framework/Versions/A/VLCKit",
                     "Resources/FFmpeg-LICENSE.txt", "Resources/VLCKit-LICENSE.txt"]:
        if not archive.getinfo(prefix + relative).file_size:
            raise SystemExit(f"Empty package member: {relative}")
print(f"Verified application ZIP: {Path(sys.argv[1]).name}")
