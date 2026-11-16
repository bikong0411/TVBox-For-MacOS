#!/usr/bin/env python3
"""Compile the released HTTP engine with the actual UI model, then test local fixtures."""
from pathlib import Path
import subprocess
import platform
import sys
import argparse
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("url", nargs="?", default="http://127.0.0.1:18791/probe-config.json")
parser.add_argument("--render", action="store_true")
args = parser.parse_args()

root = Path(__file__).resolve().parent.parent
build = root / f".build/{platform.machine()}-apple-macosx/release"
binary = root / ".build/check-network-probe"
objects = sorted((build / "TVBoxCore.build").glob("*.o"))
if not objects:
    raise SystemExit("Run scripts/build-app.sh first")
subprocess.run(["swiftc", "-O", "-parse-as-library", "-I", str(build / "Modules"),
                str(root / "Sources/TVBoxMac/NetworkProbeModel.swift"),
                str(root / "scripts/check-network-probe.swift"),
                *map(str, objects), "-o", str(binary)], check=True)
subprocess.run([str(binary), args.url], check=True)
if args.render:
    preview = root / ".build/render-network-probe"
    sources = sorted(path for path in (root / "Sources/TVBoxMac").glob("*.swift") if path.name != "TVBoxMacApp.swift")
    subprocess.run(["swiftc", "-O", "-parse-as-library", "-I", str(build / "Modules"),
                    *map(str, sources), str(root / "scripts/render-network-probe.swift"),
                    *map(str, objects), "-o", str(preview)], check=True)
    subprocess.run([str(preview), args.url, "--ui-test", "--ui-test-suite", "local.tvboxmac.probe.preview." + uuid.uuid4().hex], cwd=root, check=True)
