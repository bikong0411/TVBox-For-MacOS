#!/usr/bin/env python3
"""Verify actual app state and render only our own offscreen fixture views."""
from pathlib import Path
import subprocess
import uuid

root = Path(__file__).resolve().parent.parent
build = root / ".build/arm64-apple-macosx/release"
sources = sorted(p for p in (root / "Sources/TVBoxMac").glob("*.swift") if p.name != "TVBoxMacApp.swift")
objects = sorted((build / "TVBoxCore.build").glob("*.o"))
if not objects:
    raise SystemExit("Run scripts/build-app.sh first")
binary = root / ".build/check-live-overlay"
subprocess.run(["swiftc", "-O", "-parse-as-library", "-I", str(build / "Modules"),
                *map(str, sources), str(root / "scripts/check-live-overlay.swift"), str(root / "scripts/check-fullscreen.swift"), str(root / "scripts/check-tls-retry.swift"),
                *map(str, objects), "-o", str(binary)], check=True)
subprocess.run([str(binary), "--ui-test", "--ui-test-suite", "local.tvboxmac.overlay.check." + uuid.uuid4().hex], cwd=root, check=True)
