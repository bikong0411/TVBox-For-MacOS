#!/usr/bin/env python3
"""Exercise production playback code against generated local media."""
from pathlib import Path
import platform
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
architecture = sys.argv[1] if len(sys.argv) > 1 else platform.machine()
if architecture not in ("arm64", "x86_64"): raise SystemExit("Expected arm64 or x86_64")
build = root / f".build/{architecture}-apple-macosx/release"
frameworks = root / "dist/Release/TVBox.app/Contents/Frameworks"
sources = sorted(p for p in (root / "Sources/TVBoxMac").glob("*.swift") if p.name != "TVBoxMacApp.swift")
objects = sorted((build / "TVBoxCore.build").glob("*.o"))
if not objects: raise SystemExit("Build the release application first")
folder = root / f".build/vlc-check-{architecture}/Contents/MacOS"
folder.mkdir(parents=True, exist_ok=True)
if not (folder.parent / "Frameworks").exists():
    (folder.parent / "Frameworks").symlink_to(frameworks, target_is_directory=True)
binary = folder / "check-vlc"
subprocess.run(["swiftc", "-O", "-parse-as-library", "-target", f"{architecture}-apple-macosx13.0",
                "-I", str(build / "Modules"), "-F", str(frameworks), "-framework", "VLCKit",
                "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                *map(str, sources), str(root / "scripts/check-vlc-playback.swift"),
                *map(str, objects), "-o", str(binary)], check=True)
print("Running playback checks:", architecture, flush=True)
subprocess.run(["arch", f"-{architecture}", str(binary)], cwd=root, check=True, timeout=150)
