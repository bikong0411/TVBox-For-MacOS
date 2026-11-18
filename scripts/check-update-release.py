#!/usr/bin/env python3
"""Exercise release validation without an account, private key or real ZIPs."""
from pathlib import Path
import base64,hashlib,importlib.util,plistlib,tempfile,zipfile
root=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('update_feeds',root/'scripts/create-update-feeds.py')
feeds=importlib.util.module_from_spec(spec);spec.loader.exec_module(feeds)
with tempfile.TemporaryDirectory(prefix='tvbox-publish-check-') as temporary:
    folder=Path(temporary);public=base64.b64encode(bytes(range(32))).decode();repo='example/TVBox';tag='v1.2.3'
    def write(arch,version='1.2.3',build='52',key=public):
        name=feeds.PACKAGES[arch]
        info={'CFBundleIdentifier':'local.tvboxmac','CFBundleShortVersionString':version,'CFBundleVersion':build,'SUPublicEDKey':key,'TVBoxUpdateRepository':repo,'SUFeedURL':f'https://github.com/{repo}/releases/latest/download/appcast-{arch}.xml','SURequireSignedFeed':True,'SUVerifyUpdateBeforeExtraction':True}
        with zipfile.ZipFile(folder/name,'w') as archive:archive.writestr('TVBox.app/Contents/Info.plist',plistlib.dumps(info))
        (folder/(Path(name).stem+'.sha256')).write_text(hashlib.sha256((folder/name).read_bytes()).hexdigest()+'  '+name+'\n')
    for arch in feeds.PACKAGES:write(arch)
    assert feeds.validate_artifacts(folder,repo,tag,public)==('1.2.3','52')
    checks=1
    for bad_repo,bad_tag in [('owner/..',tag),(repo,'v1.2.3-beta'),(repo,'v01.2.3')]:
        try:feeds.validate_artifacts(folder,bad_repo,bad_tag,public);raise AssertionError('Invalid release metadata accepted')
        except ValueError:checks+=1
    for change in [{'build':'53'},{'key':base64.b64encode(b'x'*32).decode()},{'version':'1.2.4'}]:
        write('Intel',**change)
        try:feeds.validate_artifacts(folder,repo,tag,public);raise AssertionError('Mismatched native package accepted')
        except ValueError:checks+=1
        write('Intel')
    with (folder/feeds.PACKAGES['Intel']).open('ab') as stream:stream.write(b'changed-after-checksum')
    try:feeds.validate_artifacts(folder,repo,tag,public);raise AssertionError('Changed release archive accepted')
    except ValueError:checks+=1
    print('PASS signed-update publisher validation:',checks,'cases')
