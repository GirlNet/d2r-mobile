"""Build pinned, game-free libvpx for host tests or the arm64 iPhone shell."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import tarfile
import urllib.request

VERSION = '1.15.2'
SOURCE_SHA256 = '26fcd3db88045dee380e581862a6ef106f49b74b6396ee95c2993a260b4636aa'
SOURCE_URL = f'https://github.com/webmproject/libvpx/archive/refs/tags/v{VERSION}.tar.gz'


def build(root, target):
    root = Path(root).resolve()
    if target not in ('ios', 'macos'): raise ValueError('Unknown VP9 target')
    arch = 'arm64' if target == 'ios' else platform.machine()
    identity = dict(version=VERSION, source_sha256=SOURCE_SHA256, target=target, architecture=arch,
                    implementation=('arm64 NEON VP9 decoder, four worker threads, no encoder'
                                    if target == 'ios' else
                                    'portable C VP9 decoder, four worker threads, no encoder'))
    report = root / 'libvpx-build.json'
    library = root / 'lib/libvpx.a'
    if report.exists():
        previous = json.loads(report.read_text())
        if any(previous.get(k) != v for k, v in identity.items()): raise ValueError('Existing VP9 build has a different target')
        if hashlib.sha256(library.read_bytes()).hexdigest() != previous['library_sha256']: raise ValueError('VP9 library changed')
        return root
    root.mkdir(parents=True, exist_ok=False)
    archive = root / 'source.tar.gz'
    with urllib.request.urlopen(SOURCE_URL, timeout=60) as response: archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SOURCE_SHA256: raise ValueError('libvpx source digest mismatch')
    with tarfile.open(archive) as compressed: compressed.extractall(root / 'source', filter='data')
    source = root / f'source/libvpx-{VERSION}'
    objects = root / 'objects'; objects.mkdir()
    sdk = 'iphoneos' if target == 'ios' else 'macosx'
    minimum = '-miphoneos-version-min=26.0' if target == 'ios' else '-mmacosx-version-min=13.0'
    compiler = shlex.join(['xcrun', '--sdk', sdk, 'clang', '-arch', arch, minimum])
    env = dict(os.environ, CC=compiler, LD=compiler, AR=f'xcrun --sdk {sdk} ar',
               AS=compiler, STRIP=f'xcrun --sdk {sdk} strip', CFLAGS='-O3 -fPIC')
    configure_target = 'arm64-darwin-gcc' if target == 'ios' else 'generic-gnu'
    configure = [str(source / 'configure'), '--target=' + configure_target,
                 '--disable-runtime-cpu-detect', '--disable-vp8', '--disable-vp9-encoder',
                 '--disable-vp9-highbitdepth', '--disable-examples', '--disable-tools',
                 '--disable-docs', '--disable-unit-tests', '--disable-webm-io', '--enable-pic',
                 '--disable-shared', '--enable-static', '--prefix=' + str(root)]
    if target == 'ios': configure.append('--enable-neon')
    for name, command in [('configure', configure), ('compile', ['make', '-j4']), ('install', ['make', 'install'])]:
        result = subprocess.run(command, cwd=objects, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (root / (name + '.log')).write_bytes(result.stdout)
        if result.returncode:
            print(result.stdout.decode(errors='replace')[-12000:])
            raise RuntimeError('libvpx ' + name + ' failed')
    identity['library_sha256'] = hashlib.sha256(library.read_bytes()).hexdigest()
    report.write_text(json.dumps(identity, indent=2) + '\n')
    print('LIBVPX BUILD OK:', json.dumps(identity))
    return root


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--target', choices=('ios', 'macos'), required=True)
    args = parser.parse_args()
    build(args.root, args.target)
