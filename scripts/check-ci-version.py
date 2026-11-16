#!/usr/bin/env python3
"""Verify CI metadata using temporary projects, without changing real Info.plist."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parent.parent
source = (root / "Resources/Info.plist").read_bytes()
initial = plistlib.loads(source)
checks = 0

def check(ref_type="branch", ref="main", run="12", attempt="1", valid=True):
    global checks
    with tempfile.TemporaryDirectory(prefix="tvbox-ci-version-") as temporary:
        project = Path(temporary)
        (project / "Resources").mkdir(); (project / "scripts").mkdir()
        path = project / "Resources/Info.plist"; path.write_bytes(source)
        for name in ["ci-version.py", "ci-verify-package.py"]:
            shutil.copy2(root / "scripts" / name, project / "scripts" / name)
        env = dict(os.environ, GITHUB_REF_TYPE=ref_type, GITHUB_REF_NAME=ref,
                   GITHUB_RUN_NUMBER=run, GITHUB_RUN_ATTEMPT=attempt)
        result = subprocess.run([sys.executable, str(project / "scripts/ci-version.py")], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == valid, result.stdout + result.stderr
        if not valid or ref_type != "tag":
            assert path.read_bytes() == source, "Non-release / invalid input modified Info.plist"
        else:
            stamped = plistlib.loads(path.read_bytes())
            expected = dict(initial, CFBundleShortVersionString=ref[1:],
                            CFBundleVersion=str(int(initial["CFBundleVersion"]) + int(run)))
            assert stamped == expected, "Stamp altered unrelated application metadata"
            # Inspect the package with the exact production verifier after stamping.
            package = project / "fixture.zip"
            prefix = "TVBox.app/Contents/"
            members = ["MacOS/TVBoxMac", "Helpers/tvbox-remux", "Frameworks/VLCKit.framework/Versions/A/VLCKit",
                       "Resources/FFmpeg-LICENSE.txt", "Resources/VLCKit-LICENSE.txt"]
            def archive(info):
                with zipfile.ZipFile(package, "w") as output:
                    output.writestr(prefix + "Info.plist", plistlib.dumps(info))
                    for member in members: output.writestr(prefix + member, b"fixture")
            verify = [sys.executable, str(project / "scripts/ci-verify-package.py"), str(package)]
            archive(stamped)
            assert subprocess.run(verify, capture_output=True).returncode == 0, "Stamped package rejected"
            archive(initial)
            assert subprocess.run(verify, capture_output=True).returncode != 0, "Wrong package version accepted"
        checks += 1

check()
check(ref="v0.9.0")  # A branch named like a version must not stamp a release.
check(ref_type="", ref="", run="")  # Local execution remains read-only.
check("tag", "v0.8.1")
check("tag", "v0.8.1", attempt="2")  # Rerun the same workflow, fresh checkout.
check("tag", "v1.2.3", run="13")
for tag in ["0.8.1", "v0.8", "v0.8.1-beta.1", "v00.8.1", "v0.8.1\n", "v$(whoami)"]:
    check("tag", tag, valid=False)
for number in ["", "0", "-1", "12x", "10000"]:
    check("tag", "v0.8.1", run=number, valid=False)
assert (root / "Resources/Info.plist").read_bytes() == source
print(f"PASS: {checks} CI version cases; valid package accepted, wrong package rejected; source unchanged")
