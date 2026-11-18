#!/usr/bin/env python3
"""Guard against stale duplicate release workflows and missing CSP preparation."""
from pathlib import Path
import argparse, os, re, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parent.parent

def require(condition, message):
    if not condition: raise ValueError(message)

def validate(project):
    folder = project / '.github/workflows'
    workflows = [p for p in sorted(folder.glob('*')) if p.suffix in ['.yml', '.yaml']]
    builders = [p for p in workflows if 'scripts/build-app.sh' in p.read_text() or 'gh release create' in p.read_text()]
    require([p.name for p in builders] == ['main.yml'], 'Keep one application build/release workflow: .github/workflows/main.yml; remove the obsolete macos-build.yml')
    text = builders[0].read_text()
    require('\n  release:' in text, 'Missing tagged release job')
    build, release = text.split('\n  release:', 1)
    steps = re.split(r'(?m)^      - name: ', build)[1:]
    def step(needle):
        positions = [i for i, value in enumerate(steps) if needle in value]
        require(len(positions) == 1, 'Missing or repeated build step: ' + needle)
        return positions[0]
    tools = step('brew install e2fsprogs pkgconf')
    runtime = step('python3 scripts/prepare-csp-runtime.py --arch "$BUILD_ARCH"')
    app = step('bash scripts/build-app.sh "$BUILD_ARCH"')
    require(tools < runtime < app, 'Build tools and the native CSP runtime must be prepared before application packaging')
    require('test -s Vendor/CSPRuntime/manifest.json' in steps[runtime], 'Check the prepared runtime manifest before continuing')
    require('arch: x86_64' in build and 'arch: arm64' in build, 'Build both supported native architectures')
    require('runs-on: macos-' in release, 'Sparkle release signing requires a macOS runner')
    require('SPARKLE_PRIVATE_KEY' in release and 'scripts/create-update-feeds.py' in release, 'Tagged releases must publish signed update feeds')
    require(release.index('scripts/create-update-feeds.py') < release.index('gh release create'), 'Sign and validate updates before publishing a release')
    require('scripts/csp/package-sources.py' in build, 'Keep the runtime corresponding-source artifact')
    script = (project / 'scripts/build-app.sh').read_text()
    require(script.index('CSP runtime is missing.') < script.index('swift build'), 'Detect a missing runtime before compiling the application')

def self_test():
    healthy = (ROOT / '.github/workflows/main.yml').read_text()
    count = 0
    with tempfile.TemporaryDirectory(prefix='tvbox-ci-contract-') as temporary:
        fixture = Path(temporary)
        folder = fixture / '.github/workflows'; folder.mkdir(parents=True)
        (fixture / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/build-app.sh', fixture / 'scripts/build-app.sh')
        main = folder / 'main.yml'
        mutations = [
            healthy.replace('python3 scripts/prepare-csp-runtime.py --arch "$BUILD_ARCH"', 'echo runtime omitted'),
            healthy.replace('test -s Vendor/CSPRuntime/manifest.json', 'echo manifest unchecked'),
            healthy.replace('brew install e2fsprogs pkgconf', 'echo tools omitted'),
            healthy.replace('    runs-on: macos-15\n', '    runs-on: ubuntu-24.04\n'),
            healthy.replace('scripts/create-update-feeds.py', 'scripts/unsigned-release.py'),
        ]
        for text in mutations:
            main.write_text(text)
            try: validate(fixture)
            except ValueError: count += 1
            else: raise AssertionError('Invalid workflow was accepted')
        main.write_text(healthy)
        legacy = folder / 'macos-build.yml'; legacy.write_text(healthy)
        try: validate(fixture)
        except ValueError: count += 1
        else: raise AssertionError('Duplicate application workflows were accepted')
        legacy.unlink(); validate(fixture)
        # A clean checkout has no Vendor outputs. Fail before dependency fetch
        # or compilation rather than spending minutes before the same error.
        for target in ['arm64', 'intel', '--universal']:
            result = subprocess.run(['bash',str(fixture/'scripts/build-app.sh'),target],capture_output=True,text=True,env=dict(os.environ,GITHUB_ACTIONS='true'))
            require(result.returncode != 0 and 'CSP runtime is missing.' in result.stderr and '.github/workflows/main.yml' in result.stderr, 'Missing-runtime preflight did not stop the build')
            require('No such file' not in result.stderr, 'Dependency setup started before runtime preflight')
            count += 1
    print('PASS workflow regression and clean-checkout preflight: ' + str(count) + ' cases')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--self-test',action='store_true'); args=parser.parse_args()
    try:
        validate(ROOT)
        if args.self_test: self_test()
    except ValueError as error: raise SystemExit('CI configuration error: ' + str(error))
    print('PASS one native macOS build workflow, CSP preparation order and signed release contract')
