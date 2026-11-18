"""Initialize only the stock Android framework and our own Worker.

No subscription or third-party spider is loaded. Per-install identifiers,
recent tasks and Worker application data are removed before packaging.
"""
from pathlib import Path
import argparse,hashlib,json,os,re,select,subprocess,time,urllib.request,uuid
parser=argparse.ArgumentParser();parser.add_argument('--assets',type=Path,required=True);parser.add_argument('--build-root',type=Path,required=True);parser.add_argument('--image-tool',type=Path,required=True);parser.add_argument('--e2fsprogs',type=Path,required=True);parser.add_argument('--emulate',action='store_true');args=parser.parse_args()
assets=args.assets.resolve();root=args.build_root.resolve()
work=root/('factory-'+uuid.uuid4().hex[:12]);work.mkdir(mode=0o700)
command=[str(assets/'CSPRuntimeHost')]
if args.emulate:command.append('--emulate')
process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
ready=False
try:
 process.stdin.write((json.dumps({'assets':str(assets),'storage':str(work)})+'\n').encode());process.stdin.flush()
 assert select.select([process.stdout],[],[],30)[0],'Factory supervisor handshake timeout'
 state=json.loads(process.stdout.readline());assert 'error' not in state,state
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}));started=time.monotonic()
 for attempt in range(900):
  assert process.poll() is None,'Factory runtime exited'
  try:
   request=urllib.request.Request(state['endpoint']+'/health',headers={'Authorization':'Bearer '+state['token']})
   with opener.open(request,timeout=1) as response:health=json.load(response)
   if health.get('runtime')=='android-art':ready=True;break
  except OSError:pass
  if attempt%30==0:print('Initializing clean runtime framework',round(time.monotonic()-started),'seconds',flush=True)
  time.sleep(1)
 assert ready,'Factory Worker startup timeout'
 print('Clean runtime initialized in',round(time.monotonic()-started,2),'seconds',flush=True)
finally:
 process.stdin.close();process.wait(timeout=18)
raw=root/'factory-data.raw'
subprocess.run([str(args.image_tool),'convert','-f','qcow2','-O','raw',str(work/'data-v1.qcow2'),str(raw)],check=True)
environment=dict(os.environ,DYLD_LIBRARY_PATH=str(args.e2fsprogs/'lib')+':'+os.environ.get('DYLD_LIBRARY_PATH',''))
debugfs=args.e2fsprogs/'sbin/debugfs'
def repair():
 result=subprocess.run([str(args.e2fsprogs/'sbin/e2fsck'),'-fy',str(raw)],env=environment)
 if result.returncode not in (0,1):raise RuntimeError('Factory filesystem recovery failed')
# Replay the ext4 journal before inspecting or editing the offline filesystem.
repair()
def invoke(command):return subprocess.check_output([str(debugfs),'-R',command,str(raw)],env=environment,stderr=subprocess.DEVNULL,text=True)
def entries(path):
 result=[]
 for row in invoke('ls -p '+path).splitlines():
  parts=row.split('/')
  if len(parts)<7 or not parts[1].isdigit() or parts[5] in ('.','..') or parts[1]=='0':continue
  result.append((parts[5],parts[2].startswith('04')))
 return result
def quote(value):return '"'+value.replace('\\','\\\\').replace('"','\\"')+'"'
commands=[]
def remove_tree(path):
 for name,directory in entries(path):
  child=path+'/'+name
  if directory:remove_tree(child)
  else:commands.append('rm '+quote(child))
 commands.append('rmdir '+quote(path))
for path in ['/data/local.tvbox.csp','/user_de/0/local.tvbox.csp','/system_ce/0/recent_tasks','/system_ce/0/recent_images']:
 if entries(path):remove_tree(path)
for name,directory in entries('/system/users/0'):
 if not directory and name.startswith(('settings_ssaid.xml','settings_secure.xml')):commands.append('rm '+quote('/system/users/0/'+name))
script=root/'factory-cleanup.debugfs';script.write_text('\n'.join(commands)+'\n')
with (root/'factory-cleanup.log').open('wb') as log:subprocess.run([str(debugfs),'-w','-f',str(script),str(raw)],env=environment,stdout=log,stderr=log,check=True)
repair()
subprocess.run([str(args.e2fsprogs/'sbin/e2fsck'),'-fn',str(raw)],env=environment,check=True)
temporary=assets/'data-template.pending.qcow2'
subprocess.run([str(args.image_tool),'convert','-f','raw','-O','qcow2','-c',str(raw),str(temporary)],check=True)
temporary.replace(assets/'data-template.qcow2')
manifest=json.loads((assets/'manifest.json').read_text())
manifest['files']['data-template.qcow2']=hashlib.sha256((assets/'data-template.qcow2').read_bytes()).hexdigest()
(assets/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Prepared clean framework cache; no source components or accounts loaded',flush=True)
