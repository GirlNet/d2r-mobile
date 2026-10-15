#!/usr/bin/env python3
# 无游戏内容的 P5R iOS 宿主链接与打包；显式源码清单不包含 D2R 功能或衍生表。
# Link and package a game-free P5R iOS host; an explicit source list excludes D2R features and derived tables.
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import struct
import sys
import zipfile


REPO = Path(__file__).resolve().parents[3]
CORE = ['crash.c', 'entry.S', 'guest_bootstrap.c', 'hle.c', 'loader.c', 'main.c', 'memstat.m', 'thread.c', 'dm_i18n.c']
EXCLUDE = {'hle_tact.c', 'hle_private_aim.c', 'hle_target.c', 'hle_charname.c', 'hle_granny.c', 'hle_movie.c'}
FRAMEWORKS = ['UIKit', 'Foundation', 'QuartzCore', 'CoreGraphics', 'Metal', 'AudioToolbox', 'ImageIO', 'UniformTypeIdentifiers',
              'GameController', 'Network', 'AVFoundation', 'VideoToolbox', 'CoreMedia', 'CoreVideo', 'Security']


def sources():
    host = REPO / 'dm/host'
    result = [host / f for f in CORE] + [p for p in sorted(host.glob('hle_*.c')) if p.name not in EXCLUDE]
    for directory in ('dm/gfx', 'dm/gfx/nvn', 'dm/gfx/tex'):
        result += sorted(p for p in (REPO / directory).iterdir() if p.suffix in ('.c', '.m', '.S'))
    return result + [REPO / 'dm/ios/p5r/diagnostics.c', REPO / 'dm/ios/p5r/app.m']


def run(command, log):
    result = subprocess.run([str(c) for c in command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_bytes(result.stdout)
    return result.returncode


def build(output):
    output = output.resolve()
    if output.is_relative_to(REPO): raise ValueError('Build output must be outside the repository')
    output.mkdir(parents=True, exist_ok=False)
    objects = output / 'objects'; objects.mkdir()
    logs = output / 'logs'; logs.mkdir()
    app = output / 'Payload/P5RMobile.app'; (app / 'dm').mkdir(parents=True)
    flags = ['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-miphoneos-version-min=26.0', '-O1',
             '-fobjc-arc', '-fblocks', '-Werror=implicit-function-declaration', '-DDM_P5R_ONLY=1', '-DDM_SHELL=1',
             '-I' + str(REPO / 'dm/host'), '-I' + str(REPO / 'dm/gfx/nvn/include')]
    plan = []
    for index, source in enumerate(sources()):
        obj = objects / f'{index:03d}-{source.stem}.o'
        command = flags + (['-Dmain=dm_main'] if source == REPO / 'dm/host/main.c' else []) + ['-c', source, '-o', obj]
        plan.append((source, obj, command, logs / (obj.stem + '.log')))
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda p: run(p[2], p[3]), plan))
    failed = [str(p[0].relative_to(REPO)) for p, code in zip(plan, results) if code]
    report = dict(profile='p5r', game_content_included=False, signed=False, runtime_ready=False,
                  sources=[str(p[0].relative_to(REPO)) for p in plan], failed_sources=failed,
                  linked=False, packaged=False)
    report_path = output / 'build-report.json'
    def save(): report_path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    save()
    if failed:
        for p, code in zip(plan, results):
            if code: print(p[3].read_text(errors='replace')[-6000:], file=sys.stderr)
        raise RuntimeError('Host compilation failed; see logs and build-report.json')
    executable = app / 'P5RMobile'
    command = flags[:8] + [p[1] for p in plan] + ['-Wl,-dead_strip', '-Wl,-rpath,@executable_path/Frameworks']
    for framework in FRAMEWORKS: command += ['-framework', framework]
    command += ['-o', executable]
    if run(command, logs / 'link.log'):
        print((logs / 'link.log').read_text(errors='replace')[-16000:], file=sys.stderr)
        raise RuntimeError('Full host link failed; see link.log')
    binary = executable.read_bytes(); header = struct.unpack_from('<IiiIIIII', binary)
    if header[:4] != (0xfeedfacf, 0x100000c, 0, 2): raise RuntimeError('Linked host has an unexpected Mach-O architecture/type')
    if run(['xcrun', '--sdk', 'iphoneos', 'otool', '-l', executable], logs / 'macho-load-commands.log'):
        raise RuntimeError('Cannot inspect linked host load commands')
    load_commands = (logs / 'macho-load-commands.log').read_text()
    offset, has_entry, has_ios = 32, False, False
    for _ in range(header[4]):
        kind, size = struct.unpack_from('<II', binary, offset)
        if size < 8 or offset + size > 32 + header[5]: raise RuntimeError('Invalid linked Mach-O load commands')
        if kind == 0x80000028: has_entry = True
        if kind == 0x32 and struct.unpack_from('<I', binary, offset + 8)[0] == 2: has_ios = True
        offset += size
    if not has_entry or not has_ios:
        raise RuntimeError('Linked host lacks an iOS entry point/platform declaration')
    if 'sectname __dm' in load_commands: raise RuntimeError('Game module sections must not appear in the shell')
    report['linked'] = True
    info = dict(CFBundleExecutable='P5RMobile', CFBundleIdentifier='org.p5r.experimental', CFBundleName='P5RMobile',
                CFBundleDisplayName='P5R Mobile', CFBundlePackageType='APPL', CFBundleInfoDictionaryVersion='6.0',
                CFBundleVersion='1', CFBundleShortVersionString='0.1', MinimumOSVersion='26.0',
                CFBundleSupportedPlatforms=['iPhoneOS'], UIDeviceFamily=[1,2], LSRequiresIPhoneOS=True,
                UIFileSharingEnabled=True, LSSupportsOpeningDocumentsInPlace=True, UILaunchScreen={},
                UISupportedInterfaceOrientations=['UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'])
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    (app / 'dm/p5r-shell.json').write_text(json.dumps(dict(schema_version=1, profile='p5r', game_content_included=False,
        source_fingerprint=hashlib.sha256(b''.join(p[0].read_bytes() for p in plan)).hexdigest(),
        shader_chain=(REPO / 'dm/gfx/nvn/dmsh_chain.h').read_text().split('"')[1]), indent=2) + '\n')
    archive = output / 'P5RMobile-shell-unsigned.ipa'
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED) as zipped:
        for path in sorted(app.rglob('*')):
            if path.is_file(): zipped.write(path, path.relative_to(output).as_posix())
    report.update(packaged=True, archive=str(archive), archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
    save(); print(json.dumps(report, indent=2)); return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Link and package the game-free P5R iOS host on macOS.')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try: build(args.output)
    except (ValueError, OSError, RuntimeError) as error: parser.exit(1, str(error) + '\n')
