#!/usr/bin/env python3
from pathlib import Path
import argparse,subprocess,zipfile
project=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--tools-dir',type=Path,required=True);args=parser.parse_args()
tools=args.tools_dir.resolve();extracted=tools/'extracted'
java=next(extracted.glob('*jre/Contents/Home/bin/java'))
android=extracted/'android-35/android.jar'
work=project/'.build/csp-fixture';work.mkdir(exist_ok=True)
classes=work/'classes';classes.mkdir(exist_ok=True)
dex=work/'dex';dex.mkdir(exist_ok=True)
api=work/'worker-api.jar'
with zipfile.ZipFile(api,'w') as archive:archive.write(project/'.build/csp-worker/classes/com/github/catvod/crawler/Spider.class','com/github/catvod/crawler/Spider.class')
subprocess.run([str(java),'-jar',str(tools/'ecj.jar'),'-source','8','-target','8','-proc:none','-encoding','UTF-8','-classpath',str(android)+':'+str(api),'-d',str(classes),str(project/'Tests/Fixtures/CSPFixture.java'),str(project/'Tests/Fixtures/Proxy.java')],check=True)
subprocess.run([str(java),'-cp',str(extracted/'android-15/lib/d8.jar'),'com.android.tools.r8.D8','--lib',str(android),'--classpath',str(api),'--min-api','26','--output',str(dex),*map(str,classes.rglob('*.class'))],check=True)
with zipfile.ZipFile(work/'fixture.jar','w',zipfile.ZIP_DEFLATED) as archive:archive.write(dex/'classes.dex','classes.dex')
print('Built independent CSP fixture',work/'fixture.jar')
