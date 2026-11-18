#!/usr/bin/env python3
"""Check bundled languages and actual Foundation lookup in separate processes."""
from pathlib import Path
import json, plistlib, re, shutil, subprocess, uuid

root = Path(__file__).resolve().parent.parent
resources = root / 'Resources'
tables = {}
for language in ['en', 'zh-Hans']:
    table = {}
    for line in (resources / (language + '.lproj/Localizable.strings')).read_text().splitlines():
        if not line or line.startswith('//'): continue
        match = re.fullmatch(r'("(?:[^"\\]|\\.)*") = ("(?:[^"\\]|\\.)*");', line)
        assert match, 'Malformed translation entry'
        key, value = [json.loads(v) for v in match.groups()]
        assert key not in table, 'Duplicate localization key'
        assert key.count('%@') == value.count('%@'), 'Changed interpolation argument count'
        if language == 'en': assert not re.search('[\u4e00-\u9fff]', value), 'Untranslated English label'
        table[key] = value
    tables[language] = table
assert tables['en'].keys() == tables['zh-Hans'].keys()
for key in ['发现','电视直播','我的收藏','播放记录','配置管理','网络探测','播放菜单','检查更新…','修改名称 / 地址','安卓电视 · DLNA','AirPlay 电视']:
    assert key in tables['en'], 'Missing feature menu translation'

build = root / '.build/localization-check'
build.mkdir(parents=True, exist_ok=True)
binary = build / 'LocalizationCheck'
subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(build / 'cache'), str(root / 'Sources/TVBoxMac/Localization.swift'), str(root / 'scripts/check-localization.swift'), '-o', str(binary)], check=True)
for language in ['en','zh-Hans']:
    app = build / (language + '.app/Contents')
    (app / 'MacOS').mkdir(parents=True,exist_ok=True)
    shutil.copy2(binary, app / 'MacOS/LocalizationCheck')
    info = {'CFBundleIdentifier':'local.tvboxmac.validation.localization.' + language, 'CFBundleExecutable':'LocalizationCheck', 'CFBundleDevelopmentRegion':'en', 'CFBundleLocalizations':['en','zh-Hans'], 'CFBundlePackageType':'APPL'}
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    for locale in ['en','zh-Hans']: shutil.copytree(resources / (locale + '.lproj'), app / 'Resources' / (locale + '.lproj'), dirs_exist_ok=True)
    requested = ['en', 'en-GB', 'fr-FR'] if language == 'en' else ['zh-Hans', 'zh-Hans-CN']
    for preference in requested:
        suite = 'local.tvboxmac.validation.language.' + uuid.uuid4().hex
        subprocess.run([str(app / 'MacOS/LocalizationCheck'), language, '--ui-test', '--ui-test-suite', suite, '--cleanup', '-AppleLanguages', '(' + preference + ')'], check=True)
    # A manual choice beats the opposite macOS app language. A second process
    # reads the saved choice without reseeding it; follow-system restores the OS.
    system = 'zh-Hans' if language == 'en' else 'en'
    suite = 'local.tvboxmac.validation.language.' + uuid.uuid4().hex
    command = [str(app / 'MacOS/LocalizationCheck'), language, '--ui-test', '--ui-test-suite', suite, '-AppleLanguages', '(' + system + ')']
    subprocess.run(command + ['--preference', language], check=True)
    subprocess.run(command, check=True)
    subprocess.run([str(app / 'MacOS/LocalizationCheck'), system, '--ui-test', '--ui-test-suite', suite, '--preference', 'system', '--cleanup', '-AppleLanguages', '(' + system + ')'], check=True)
print('PASS localization catalogs: ' + str(len(tables['en'])) + ' matching Chinese / English entries')
