from pathlib import Path
import collections,hashlib,os,subprocess,tarfile
r=Path(os.environ['CSP_BUILD_ROOT']);tools=Path(os.environ['CSP_E2FSPROGS'])
env=dict(os.environ,DYLD_LIBRARY_PATH=str(tools/'lib')+':'+os.environ.get('DYLD_LIBRARY_PATH',''),MKE2FS_CONFIG=str(r/'mke2fs.conf'))
commands=[];scratch=r/'image-fixes';scratch.mkdir(exist_ok=True)
def quote(text):return '"'+str(text).replace('\\','\\\\').replace('"','\\"')+'"'
def write(source,name,uid=0,gid=0,mode=0o100644):
 commands.extend(['rm '+quote('/'+name),'write '+quote(source)+' '+quote('/'+name),'set_inode_field '+quote('/'+name)+' uid '+str(uid),'set_inode_field '+quote('/'+name)+' gid '+str(gid),'set_inode_field '+quote('/'+name)+' mode 0'+format(mode,'o')])
with tarfile.open(r/'redroid-arm64.tar.gz') as archive:
 members=[m for m in archive if m.isfile()];counts=collections.Counter(m.name.casefold() for m in members)
 for i,m in enumerate(members):
  if counts[m.name.casefold()] < 2:continue
  path=scratch/('case-'+str(i));path.write_bytes(archive.extractfile(m).read());write(path,m.name,m.uid,m.gid,0o100000|m.mode)
 print('Restoring case-sensitive guest files',sum(1 for m in members if counts[m.name.casefold()]>1),flush=True)
rc=scratch/'tvbox-csp.rc'
rc.write_text('''on early-init
    symlink /dev/hwrng /dev/hw_random

on boot
    stop adbd
    exec_background -- /system/bin/sh /system/etc/tvbox-start-worker.sh

on property:sys.boot_completed=1
    exec_background -- /system/bin/am start --user 0 -n local.tvbox.csp/.WorkerActivity --es token ${ro.boot.tvbox_csp_token}
''')
write(rc,'system/etc/init/tvbox-csp.rc')
starter=scratch/'tvbox-start-worker.sh'
starter.write_text('''#!/system/bin/sh
# The Worker does not need a launcher or a rendered desktop. Wait for the
# activity Binder service, rather than waiting for launcher idle / boot complete.
for attempt in $(seq 1 360); do
    if service check activity 2>/dev/null | grep -q 'Service activity: found'; then
        result="$(am start --user 0 -n local.tvbox.csp/.WorkerActivity --es token "$(getprop ro.boot.tvbox_csp_token)" 2>&1)"
        case "$result" in *Error*|*Exception*) ;; *) exit 0 ;; esac
    fi
    sleep 2
done
exit 1
''')
write(starter,'system/etc/tvbox-start-worker.sh',mode=0o100644)
# QEMU exposes Ethernet. Advertising nonexistent Wi-Fi / Bluetooth hardware
# makes the framework start unrelated HALs and wait for them under emulation.
removed=scratch/'redroid-removed-permissions.xml'
removed.write_text('''<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <unavailable-feature name="android.hardware.bluetooth" />
    <unavailable-feature name="android.hardware.bluetooth_le" />
    <unavailable-feature name="android.hardware.wifi" />
    <unavailable-feature name="android.hardware.wifi.direct" />
</permissions>
''')
write(removed,'vendor/etc/permissions/redroid-removed-permissions.xml')
for path in (r/'android-root/vendor/etc/permissions').glob('*bluetooth*'):
 commands.append('rm '+quote('/vendor/etc/permissions/'+path.name))
script=scratch/'fixes.debugfs';script.write_text('\n'.join(commands)+'\n')
result=subprocess.run([str(tools/'sbin/debugfs'),'-w','-f',str(script),str(r/'android-system.raw')],env=env,capture_output=True,text=True,check=True)
(scratch/'fixes.log').write_text(result.stdout+result.stderr)
bad=[s for s in result.stderr.splitlines() if ('not found' in s or 'error' in s.lower()) and not s.startswith('rm: File not found by ext2_lookup')]
assert not bad,bad
subprocess.run([str(tools/'sbin/e2fsck'),'-fn',str(r/'android-system.raw')],env=env,check=True)
template=r/'android-data-template.raw'
if not template.exists():
 subprocess.run([str(tools/'sbin/mke2fs'),'-q','-t','ext4','-F','-b','4096','-m','0','-L','TVBOX_DATA','-E','root_owner=0:0',str(template),'2G'],env=env,check=True)
print('Finalized private Android system and clean data template',flush=True)
