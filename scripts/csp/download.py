"""Checksum-pinned downloads with bounded, resumable range requests."""
from pathlib import Path
import concurrent.futures,hashlib,shutil,subprocess,time
def sha(path):
 value=hashlib.sha256()
 with Path(path).open('rb') as stream:
  for data in iter(lambda:stream.read(1024*1024),b''):value.update(data)
 return value.hexdigest()
def fetch(row,root):
 path=Path(root)/row['name'];path.parent.mkdir(parents=True,exist_ok=True)
 if path.exists() and sha(path)==row['sha256']:return path
 size=row.get('size',0)
 if size>8*1024*1024:
  folder=path.with_name(path.name+'.parts');folder.mkdir(exist_ok=True)
  chunk=4*1024*1024
  specifications=[(index,start,min(size,start+chunk)-1) for index,start in enumerate(range(0,size,chunk))]
  def part(spec):
   index,start,end=spec;target=folder/str(index)
   if target.exists() and target.stat().st_size==end-start+1:return target
   temporary=folder/(str(index)+'.download')
   for attempt in range(4):
    result=subprocess.run(['curl','-fL','--http1.1','--retry','2','--max-time','150','--silent','--show-error','--range',str(start)+'-'+str(end),row['url'],'-o',str(temporary)],capture_output=True)
    if result.returncode==0 and temporary.exists() and temporary.stat().st_size==end-start+1:temporary.replace(target);return target
    time.sleep(1+attempt)
   raise RuntimeError('Cannot fetch source range: '+row['name']+' '+str(index))
  with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:list(pool.map(part,specifications))
  temporary=path.with_name(path.name+'.download')
  with temporary.open('wb') as output:
   for index,_,_ in specifications:
    with (folder/str(index)).open('rb') as incoming:shutil.copyfileobj(incoming,output)
  if sha(temporary)!=row['sha256']:
   # Range caches can outlive a failed mirror response; invalidate only our
   # own part files so the next run downloads fresh bytes.
   for index,_,_ in specifications:(folder/str(index)).unlink(missing_ok=True)
   raise RuntimeError('Source checksum mismatch: '+row['name'])
  temporary.replace(path)
 else:
  temporary=path.with_name(path.name+'.download')
  for attempt in range(4):
   result=subprocess.run(['curl','-fL','--http1.1','--retry','2','--max-time','180','--silent','--show-error',row['url'],'-o',str(temporary)],capture_output=True)
   if result.returncode==0 and temporary.exists() and sha(temporary)==row['sha256']:temporary.replace(path);break
   time.sleep(1+attempt)
  else:raise RuntimeError('Cannot fetch verified source: '+row['name'])
 print('Verified dependency',row['name'],flush=True)
 return path
