from pathlib import Path
import gzip, struct, lzma, stat, os

root=Path(os.environ['CSP_BUILD_ROOT'])
module_root=next((root/'kernel/lib/modules').iterdir())
paths={p.name.split('.ko')[0].replace('-','_'):p for p in module_root.rglob('*.ko*') if p.is_file()}
selected={}
def elf(data):
 if data[:6]!=b'\x7fELF\x02\x01':raise ValueError('Not ARM64 ELF')
 offset=struct.unpack_from('<Q',data,40)[0]; size,count,strings=struct.unpack_from('<HHH',data,58)
 headers=[struct.unpack_from('<IIQQQQIIQQ',data,offset+i*size) for i in range(count)]
 section=headers[strings]; names=data[section[4]:section[4]+section[5]]
 for section in headers:
  end=names.find(b'\0',section[0]); name=names[section[0]:end]
  if name==b'.modinfo':
   fields=dict(row.split(b'=',1) for row in data[section[4]:section[4]+section[5]].split(b'\0') if b'=' in row)
   return fields.get(b'depends',b'').decode().split(',')
 return []
def include(name):
 if name in selected or not name:return
 p=paths[name]; data=p.read_bytes()
 if p.suffix=='.xz':data=lzma.decompress(data)
 deps=elf(data); selected[name]=(p,data,deps)
 for dep in deps:include(dep)
for name in ['virtio_mmio','virtio_blk','virtio_net','virtio_rng','crc32c_generic','ext4','binder_linux','fuse','loop','dm_mod','configfs']:include(name)
network_modules=['ip_tables','iptable_filter','iptable_nat','iptable_mangle','iptable_raw','ip6_tables','ip6table_filter','ip6table_nat','ip6table_mangle','ip6table_raw','xt_owner','xt_mark','xt_conntrack','xt_connmark','xt_bpf','xt_IDLETIMER','xt_quota','xt_limit','xt_multiport','xt_NFLOG','ipt_REJECT','ip6t_REJECT','xt_TCPMSS','xt_CT','xt_MASQUERADE','xt_REDIRECT','nf_conntrack','nf_nat','af_packet']
for name in network_modules:
 if name in paths:include(name)
network_modules+=['dummy','xfrm_user','nfnetlink','nfnetlink_log','nfnetlink_queue','nf_socket_ipv4','nf_socket_ipv6','xt_socket','xt_addrtype','xt_comment','xt_u32','xt_string','xt_pkttype','xt_hashlimit']
for name in network_modules:
 if name in paths:include(name)
files={}; directories={'bin','dev','proc','sys','newroot','run','lib','lib/modules','lib/modules/'+module_root.name}
def put(name,data,mode=0o100644):
 p=Path(name)
 for parent in p.parents:
  if str(parent)!='.':directories.add(str(parent))
 files[name]=(data,mode)
put('bin/busybox',(root/'busybox').read_bytes(),0o100755)
for applet in ['sh','mount','modprobe','cat','mkdir','echo','ls','switch_root','sleep','ip','ln','blkid','chmod']:
 put('bin/'+applet,b'busybox',0o120777)
dep_lines=[]
def all_deps(name):
 result=[]
 for dep in selected[name][2]:
  if dep and dep not in result:
   result.append(dep)
   for child in all_deps(dep):
    if child not in result:result.append(child)
 return result
for name,(p,data,deps) in selected.items():
 relative=str(p.relative_to(module_root)).replace('.ko.xz','.ko')
 put('lib/modules/'+module_root.name+'/'+relative,data)
 dep_lines.append(relative+': '+ ' '.join(str(selected[d][0].relative_to(module_root)).replace('.ko.xz','.ko') for d in all_deps(name)))
put('lib/modules/'+module_root.name+'/modules.dep', ('\n'.join(dep_lines)+'\n').encode())
init=b'''#!/bin/sh
export PATH=/bin
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
echo TVBOX_CSP_KERNEL_STARTED
modprobe virtio_mmio
modprobe virtio_blk
modprobe virtio_net
modprobe virtio_rng
modprobe crc32c_generic
modprobe ext4
modprobe binder_linux devices=binder,hwbinder,vndbinder
modprobe fuse
modprobe loop
modprobe dm_mod
modprobe configfs
NETWORK_MODULES
chmod 0666 /dev/binder /dev/hwbinder /dev/vndbinder
chmod 0444 /dev/hwrng
ls /dev/binder /dev/hwbinder /dev/vndbinder
ls /sys/class/net
echo TVBOX_CSP_BOOTSTRAP_READY
ip link set lo up
ip link set eth0 up
ip addr add 192.168.127.2/24 dev eth0
ip route add default via 192.168.127.1
if [ -b /dev/vda ]; then
    mount -t ext4 LABEL=TVBOX_SYSTEM /newroot || exec /bin/sh
    mount -t ext4 LABEL=TVBOX_DATA /newroot/data || exec /bin/sh
    mount --move /dev /newroot/dev
    mount --move /proc /newroot/proc
    mount --move /sys /newroot/sys
    set -- androidboot.hardware=redroid androidboot.selinux=permissive androidboot.redroid_gpu_mode=guest androidboot.redroid_net_ndns=1 androidboot.redroid_net_dns1=192.168.127.1 androidboot.redroid_width=320 androidboot.redroid_height=240 androidboot.redroid_fps=1 androidboot.redroid_dpi=160
    for value in $(cat /newroot/proc/cmdline); do
        case "$value" in androidboot.tvbox_csp_token=*) set -- "$@" "$value" ;; esac
    done
    exec switch_root /newroot /init "$@"
fi
exec /bin/sh
'''
init=init.replace(b'NETWORK_MODULES',('\n'.join('modprobe '+n for n in network_modules if n in paths)).encode())
put('init',init,0o100755)
out=bytearray(); ino=1
def entry(name,data,mode,rdev_major=0,rdev_minor=0):
 global ino
 encoded=name.encode()+b'\0'; values=[ino,mode,0,0,1,0,len(data),0,0,rdev_major,rdev_minor,len(encoded),0]
 out.extend(b'070701'+b''.join(('%08x'%n).encode() for n in values));out.extend(encoded)
 out.extend(b'\0'*((-len(out))%4));out.extend(data);out.extend(b'\0'*((-len(out))%4));ino+=1
for name in sorted(directories,key=lambda n:(len(Path(n).parts),n)):entry(name,b'',0o040755)
entry('dev/console',b'',0o020600,5,1)
entry('dev/null',b'',0o020666,1,3)
for name,(data,mode) in files.items():entry(name,data,mode)
entry('TRAILER!!!',b'',0)
(root/'bootstrap.cpio.gz').write_bytes(gzip.compress(bytes(out),compresslevel=6,mtime=0))
print('Created bootstrap',len(out),'bytes;',len(selected),'modules')
