from pathlib import Path
import os,subprocess,shutil,sys
r=Path(os.environ['CSP_BUILD_ROOT'])
s=r/'qemu-source/qemu-darwin-arm64-v0.1.0-sources'
v=r/'build-venv/bin'
arch=sys.argv[1] if len(sys.argv)>1 else 'arm64'
assert arch in ('arm64','x86_64')
b=r/('emulator-'+arch+('-cross' if arch=='x86_64' else '')); b.mkdir(exist_ok=True)
prefix=b/'deps'
e=dict(os.environ,PATH=str(v)+':'+os.environ['PATH'],MACOSX_DEPLOYMENT_TARGET='13.0',PKG_CONFIG_LIBDIR=str(prefix/'lib/pkgconfig'),PKG_CONFIG_PATH='',PYTHONPYCACHEPREFIX=str(b/'pycache'))
def run(args,cwd=None):
 print('Running',str(args[0]),' '.join(str(x) for x in args[1:4]),flush=True)
 with (b/'build.log').open('ab') as log:
  result=subprocess.run([str(x) for x in args],cwd=cwd,env=e,stdout=log,stderr=log)
 if result.returncode:
  print((b/'build.log').read_text(errors='replace')[-6000:],flush=True)
  result.check_returncode()
native=b/'native.ini';native.write_text("[binaries]\nc = ['clang', '-arch', '"+arch+"']\ncpp = ['clang++', '-arch', '"+arch+"']\nobjc = ['clang', '-arch', '"+arch+"']\nobjcpp = ['clang++', '-arch', '"+arch+"']\n")
if arch=='x86_64':
 with native.open('a') as f:f.write("pkg-config = '"+shutil.which('pkg-config')+"'\n[host_machine]\nsystem = 'darwin'\nsubsystem = 'macos'\ncpu_family = 'x86_64'\ncpu = 'x86_64'\nendian = 'little'\n[properties]\nneeds_exe_wrapper = false\n")
glib=s/'src/glib-2.88.4'
if not (b/'glib-build/build.ninja').exists():
 run([v/'meson','setup',b/'glib-build',glib,'--cross-file' if arch=='x86_64' else '--native-file',native,'--prefix',prefix,'--libdir=lib','--buildtype=release','-Ddefault_library=shared','--force-fallback-for=libpcre2-8,libffi,intl','-Dpcre2:default_library=static','-Dlibffi:default_library=static','-Dproxy-libintl:default_library=static','-Dtests=false','-Dintrospection=disabled','-Dnls=disabled','-Ddocumentation=false','-Dman-pages=disabled','-Dlibelf=disabled','-Dsysprof=disabled','-Ddtrace=disabled','-Dglib_debug=disabled','--wrap-mode=nodownload'])
run([v/'meson','compile','-C',b/'glib-build','-j','4'])
run([v/'meson','install','-C',b/'glib-build','--quiet'])
q=s/'src/qemu-10.2.4'
dtc=q/'subprojects/dtc'
if not (dtc/'libfdt').exists():shutil.copytree(s/'dtc-extracted/dtc',dtc,dirs_exist_ok=True)
# The pinned upstream sources stay unmodified. Guest RAM is owned by QEMU,
# without shared-memory vhost backends or their separate cache-maintenance needs.
qb=b/('qemu-build' if arch=='arm64' else 'qemu-cross-build');qb.mkdir(exist_ok=True)
if not (qb/'build.ninja').exists():
 args=[q/'configure','--prefix=/opt/tvbox-csp','--target-list=aarch64-softmmu','--without-default-features','--enable-tcg','--enable-tools','--enable-fdt=internal','--disable-docs','--disable-install-blobs','--cc=clang -arch '+arch,'--cxx=clang++ -arch '+arch]
 if arch=='arm64':args+=['--enable-hvf']
 else:args+=['--disable-hvf','--cpu=x86_64','--cross-prefix=','--objcc=clang -arch x86_64']
 run(args,qb)
run([v/'ninja','-C',qb,'-j','4','qemu-system-aarch64-unsigned'])
if arch=='arm64' or __import__('platform').machine()=='x86_64':run([v/'ninja','-C',qb,'-j','4','qemu-img'])
print('Built private emulator',arch,flush=True)
