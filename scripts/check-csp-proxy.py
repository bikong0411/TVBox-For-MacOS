#!/usr/bin/env python3
"""Verify standard Java proxy callbacks through the real private runtime."""
from pathlib import Path
import argparse,platform,subprocess
root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--tools-dir',type=Path,required=True);args=parser.parse_args()
subprocess.run(['python3',str(root/'scripts/build-csp-fixture.py'),'--tools-dir',str(args.tools_dir)],check=True)
arch=platform.machine();build=root/f'.build/{arch}-apple-macosx/release';binary=root/'.build/check-csp-proxy'
subprocess.run(['swiftc','-O','-parse-as-library','-target',arch+'-apple-macos13.0','-module-cache-path',str(root/'.build/proxy-check-cache'),'-I',str(build/'Modules'),str(root/'scripts/check-csp-proxy.swift'),*map(str,sorted((build/'TVBoxCore.build').glob('*.o'))),'-o',str(binary)],check=True)
subprocess.run([str(binary),str(root/'Vendor/CSPRuntime'),str(root/'.build/csp-fixture/fixture.jar')],check=True,timeout=120)
