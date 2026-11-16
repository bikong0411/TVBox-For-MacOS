#!/usr/bin/env python3
"""Run production source-edit actions against an isolated preference suite."""
from pathlib import Path
import platform
import subprocess
import uuid

root = Path(__file__).resolve().parent.parent
build = root / f".build/{platform.machine()}-apple-macosx/release"
frameworks = root / "dist/Release/TVBox.app/Contents/Frameworks"
sources = sorted(p for p in (root / "Sources/TVBoxMac").glob("*.swift") if p.name != "TVBoxMacApp.swift")
objects = sorted((build / "TVBoxCore.build").glob("*.o"))
folder = root / ".build/source-edit-check/Contents/MacOS"
folder.mkdir(parents=True, exist_ok=True)
if not (folder.parent / "Frameworks").exists():
    (folder.parent / "Frameworks").symlink_to(frameworks, target_is_directory=True)
binary = folder / "check-source-edit"
subprocess.run(["swiftc", "-O", "-parse-as-library", "-target", f"{platform.machine()}-apple-macosx13.0", "-I", str(build / "Modules"),
                "-F", str(frameworks), "-framework", "VLCKit",
                *map(str, sources), str(root / "scripts/check-source-edit.swift"),
                *map(str, objects), "-o", str(binary)], check=True)
subprocess.run([str(binary), "--ui-test", "--ui-test-suite",
                "local.tvboxmac.source-edit.check." + uuid.uuid4().hex], cwd=root, check=True, timeout=60)
