#!/usr/bin/env python3
"""Fetch missing official archives; verify cached/offline archives identically."""
from pathlib import Path
import hashlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent
ARCHIVES = [
    ("VLCKit-3.7.3.tar.xz",
     "https://download.videolan.org/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz",
     "019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d"),
    ("ffmpeg-8.1.1.tar.xz",
     "https://ffmpeg.org/releases/ffmpeg-8.1.1.tar.xz",
     "b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3"),
]


def verify(path, expected):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise SystemExit(f"SHA-256 mismatch: {path.name}. Remove this archive and retry.")


def main():
    folder = ROOT / "ThirdPartySources"
    folder.mkdir(exist_ok=True)
    for name, url, digest in ARCHIVES:
        destination = folder / name
        if not destination.exists():
            temporary = destination.with_suffix(destination.suffix + ".download")
            print(f"Downloading official archive: {name}", flush=True)
            try:
                subprocess.run(["curl", "--fail", "--location", "--retry", "3",
                                "--retry-all-errors", "--retry-delay", "3",
                                "--connect-timeout", "30", "--max-time", "600",
                                "--output", str(temporary), url], check=True)
                verify(temporary, digest)
                temporary.replace(destination)
            finally:
                temporary.unlink(missing_ok=True)
        verify(destination, digest)
        print(f"Verified SHA-256: {name}", flush=True)


if __name__ == "__main__":
    main()
