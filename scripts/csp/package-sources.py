#!/usr/bin/env python3
"""Collect source archives and reproduction instructions next to releases."""
from pathlib import Path
import argparse,concurrent.futures,hashlib,json,shutil,subprocess,zipfile
from download import fetch as verified_fetch
project=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser();parser.add_argument('--build-root',type=Path,default=project/'.build/csp-runtime');args=parser.parse_args()
root=args.build_root.resolve();cache=root/'corresponding-sources';cache.mkdir(parents=True,exist_ok=True)
rows=json.loads((project/'scripts/csp/corresponding-sources.json').read_text())
def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as stream:
  for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
def fetch(row):
 verified_fetch(row,cache)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(fetch,rows))
source=root/'qemu-sources.tar'
assert source.is_file() and digest(source)=='c46947444ffc4980b5de5dca06b7f90be9f05837b12acb2472f833f6bf709a61'
output=project/'dist/TVBox-CSP-Corresponding-Sources.zip';output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output,'w',zipfile.ZIP_STORED) as archive:
 archive.write(source,'sources/qemu-glib-and-subprojects.tar')
 for row in rows:archive.write(cache/row['name'],'sources/'+row['name'])
 for directory in ['Helpers/CSPWorker','scripts/csp']:
  for path in sorted((project/directory).rglob('*')):
   if path.is_file() and '__pycache__' not in path.parts:archive.write(path,'TVBoxMac/'+str(path.relative_to(project)))
 for name in ['Helpers/CSPRuntimeHost.swift','scripts/prepare-csp-runtime.py','scripts/build-csp-worker.py','ThirdPartySources/CSP-Runtime.md']:
  path=project/name
  if path.exists():archive.write(path,'TVBoxMac/'+name)
print(output,flush=True)
