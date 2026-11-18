from pathlib import Path, PurePosixPath
import hashlib, io, json, os, posixpath, shutil, stat, subprocess, tarfile

root=Path(os.environ['CSP_BUILD_ROOT'])
source=root/'redroid-arm64.tar.gz'
assert hashlib.sha256(source.read_bytes()).hexdigest()=='7ae0e9111b77895cc932d126b75e9bf16af5f9bb881e3dae79163621e8b10cb3'
tree=root/'android-root'; tree.mkdir(exist_ok=True)
metadata=[]; links=[]
with tarfile.open(source) as archive:
    for member in archive:
        name=member.name.lstrip('./')
        if not name:continue
        if member.name.startswith('/') or '..' in PurePosixPath(member.name).parts or any(c in name for c in ['\r','\n','\0']):raise RuntimeError('Invalid rootfs entry')
        path=tree/name
        if not str(path.resolve()).startswith(str(tree.resolve())+'/'):raise RuntimeError('Rootfs entry escapes image')
        path.parent.mkdir(parents=True,exist_ok=True)
        if member.isdir():path.mkdir(exist_ok=True)
        elif member.isfile():
            if path.exists():path.chmod(path.stat().st_mode | stat.S_IWUSR)
            with archive.extractfile(member) as stream, path.open('wb') as out:shutil.copyfileobj(stream,out,1024*1024)
            path.chmod(member.mode & 0o777)
        elif member.issym():
            target=posixpath.normpath(member.linkname.lstrip('/') if member.linkname.startswith('/') else posixpath.join(posixpath.dirname(name),member.linkname))
            if target=='..' or target.startswith('../'):raise RuntimeError('Invalid rootfs symlink')
            if path.is_symlink():path.unlink()
            path.symlink_to(os.path.relpath(tree/target,path.parent))
            links.append((name,member.linkname))
        elif member.islnk():
            target=tree/member.linkname.lstrip('./')
            if '..' in PurePosixPath(member.linkname).parts or not str(target.resolve()).startswith(str(tree.resolve())+'/'):raise RuntimeError('Invalid hard link')
            if path.exists():path.unlink()
            os.link(target,path)
        else:continue
        mode=stat.S_IFDIR if member.isdir() else stat.S_IFLNK if member.issym() else stat.S_IFREG
        metadata.append((name,member.uid,member.gid,mode|member.mode))
print('Extracted isolated Android rootfs',len(metadata),'entries',flush=True)

# Explicit network settings are for this private VM, never for the Mac.
props=tree/'system/build.prop'
text=props.read_text()
values={'ro.hardware.hwcomposer':'redroid','ro.boot.redroid_gpu_mode':'guest','redroid.gpu.mode':'guest','ro.zygote.disable_gl_preload':'true','debug.sf.nobootanimation':'1','ro.hw_timeout_multiplier':'5','service.adb.tcp.port':'-1','persist.adb.tcp.port':'-1','persist.sys.usb.config':'none','ro.adb.secure':'1'}
rows=[s for s in text.splitlines() if s.split('=',1)[0] not in values]
props.write_text('\n'.join(rows+[k+'='+v for k,v in values.items()])+'\n')
rc=tree/'system/etc/init/tvbox-csp.rc'
rc.write_text('''on early-init
    symlink /dev/hwrng /dev/hw_random

on boot
    stop adbd

on property:sys.boot_completed=1
    exec_background -- /system/bin/am start --user 0 -n local.tvbox.csp/.WorkerActivity --es token ${ro.boot.tvbox_csp_token}
''')
apk=tree/'system/app/TVBoxCSP/TVBoxCSP.apk'; apk.parent.mkdir(parents=True,exist_ok=True)
shutil.copy2(Path(__file__).resolve().parents[2]/'.build/csp-worker/TVBoxCSPWorker.apk',apk)
metadata.extend([('system/etc/init/tvbox-csp.rc',0,0,0o100644),('system/app/TVBoxCSP',0,0,0o040755),('system/app/TVBoxCSP/TVBoxCSP.apk',0,0,0o100644)])

tool=Path(os.environ['CSP_E2FSPROGS'])
env=dict(os.environ,DYLD_LIBRARY_PATH=str(tool/'lib')+':'+os.environ.get('DYLD_LIBRARY_PATH',''))
config=root/'mke2fs.conf'
config.write_text('''[defaults]
base_features = sparse_super,large_file,filetype,resize_inode,dir_index,ext_attr
default_mntopts = acl,user_xattr
inode_size = 256
blocksize = 4096
[fs_types]
ext4 = {
    features = has_journal,extent,huge_file,flex_bg,metadata_csum,64bit,dir_nlink,extra_isize
}
''')
env['MKE2FS_CONFIG']=str(config)
image=root/'android-system.raw'
subprocess.run([str(tool/'sbin/mke2fs'),'-q','-t','ext4','-F','-b','4096','-m','0','-L','TVBOX_SYSTEM','-E','root_owner=0:0','-d',str(tree),str(image),'4G'],env=env,check=True)
def quote(value):return '"'+value.replace('\\','\\\\').replace('"','\\"')+'"'
commands=[]
for name,target in links:
    commands.extend(['rm '+quote('/'+name),'symlink '+quote('/'+name)+' '+quote(target)])
for name,uid,gid,mode in metadata:
    commands.extend(['set_inode_field '+quote('/'+name)+' uid '+str(uid),'set_inode_field '+quote('/'+name)+' gid '+str(gid),'set_inode_field '+quote('/'+name)+' mode '+("0"+format(mode,"o"))])
fixes=root/'rootfs-metadata.debugfs'; fixes.write_text('\n'.join(commands)+'\n')
with (root/'rootfs-metadata.log').open('wb') as log:
    subprocess.run([str(tool/'sbin/debugfs'),'-w','-f',str(fixes),str(image)],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
subprocess.run([str(tool/'sbin/mke2fs'),'-q','-t','ext4','-F','-b','4096','-m','0','-L','TVBOX_DATA','-E','root_owner=0:0',str(root/'android-data-template.raw'),'2G'],env=env,check=True)
print('Created Android system and separate persistent data images',flush=True)
