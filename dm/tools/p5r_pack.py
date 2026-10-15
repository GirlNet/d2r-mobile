#!/usr/bin/env python3
# 将已链接的 P5R 壳与本地等价验证过的模块组合成实验性未签名 IPA；诊断图形资源始终不宣称可运行。
# Combine a linked P5R shell with locally equivalence-checked modules into an experimental unsigned IPA; diagnostic graphics never imply runtime readiness.
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import zipfile

import guest_dylib


MODULES = ('main', 'sdk', 'subsdk0')
KEY = re.compile(r'[0-9a-f]{16}')
REPO = Path(__file__).resolve().parents[2]


def digest(blob): return hashlib.sha256(blob).hexdigest()
def read_json(path): return json.loads(path.read_text(encoding='utf-8'))


def shell_contents(path):
    with zipfile.ZipFile(path) as archive:
        names, total = set(), 0
        for info in archive.infolist():
            name = info.filename; parts = PurePosixPath(name).parts
            if (name in names or not parts or parts[0] != 'Payload' or name.startswith('/')
                    or '..' in parts or '\\' in name or ':' in name or stat.S_ISLNK(info.external_attr >> 16)):
                raise ValueError('Unsafe or duplicate shell ZIP entry')
            names.add(name); total += info.file_size
        if total > 512 * 1024 * 1024: raise ValueError('Unexpected shell archive size')
        apps = {n.split('/')[1] for n in names if n.startswith('Payload/') and len(n.split('/')) > 2}
        if apps != {'P5RMobile.app'}: raise ValueError('Expected the dedicated P5R shell')
        base = 'Payload/P5RMobile.app/'
        manifest = json.loads(archive.read(base + 'dm/p5r-shell.json'))
        if manifest.get('profile') != 'p5r' or manifest.get('game_content_included') is not False:
            raise ValueError('Expected a game-free P5R shell')
        if any('/Guest.framework/' in n or '/_CodeSignature/' in n or n.endswith('embedded.mobileprovision') for n in names):
            raise ValueError('Shell already contains guest code or signing data')
        executable = archive.read(base + 'P5RMobile')
        if len(executable) < 32 or struct.unpack_from('<IiiI', executable) != (0xfeedfacf, 0x100000c, 0, 2):
            raise ValueError('Shell executable must be an ARM64 Mach-O executable')
        info = plistlib.loads(archive.read(base + 'Info.plist'))
        return [(item, archive.read(item)) for item in archive.infolist() if not item.is_dir()], base, manifest, info


def module_inputs(preparation):
    report = read_json(preparation / 'port-preparation.json')
    if report.get('status') != 'equivalence_passed': raise ValueError('Modules must pass rewrite equivalence checks')
    rewritten = preparation / 'rewritten'
    sources = {}
    for name in MODULES:
        image = (rewritten / (name + '.patched.bin')).read_bytes()
        if digest(image) != report['outputs'][name]: raise ValueError('Rewritten module digest mismatch: ' + name)
        fields = dict(line[2:].split() for line in (rewritten / (name + '.fixups.tsv')).read_text().splitlines() if line.startswith('# '))
        text_end, patch, key, key_size = [int(fields[k], 16) for k in ('TEXT_END','PATCH_OFF','KEY_PAGE_OFF','KEY_PAGE_SIZE')]
        if not (0 < text_end <= key < patch < len(image) and patch % 16384 == key % 16384 == 0
                and key_size == 16384 and key + key_size <= patch): raise ValueError('Invalid module segment bounds')
        indices = [int(fields['KEY_' + key + '_IDX']) for key in
                   ('K18','KTLS','KTLR','KGATE','KRES0','KRES1','KASPECT','KASPECTUI')]
        if len(set(indices)) != 8 or any(not 0 <= index < 2048 for index in indices):
            raise ValueError('Invalid module thread-key indices')
        if not text_end <= int(fields['RO_OFF'], 16) <= int(fields['DATA_OFF'], 16) <= key:
            raise ValueError('Invalid module data offsets')
        for suffix in ('fixups.tsv', 'gates.tsv'):
            data = (rewritten / (name + '.' + suffix)).read_bytes()
            sources[name + '.' + suffix] = data
        for suffix in ('cuts.tsv', 'obs.tsv', 'params.tsv'):
            path = rewritten / (name + '.' + suffix)
            if path.exists() and any(line.strip() and not line.startswith('#') for line in path.read_text().splitlines()):
                raise ValueError('P5R modules must not contain D2R private cuts, observations or parameters')
    return report, rewritten, sources


def diagnostics_inputs(directory):
    report = read_json(directory / 'diagnostic-report.json')
    if report.get('status') != 'diagnostic_passed' or report.get('diagnostic_only') is not True:
        raise ValueError('Expected a completed diagnostic shader report')
    assets, keys = {}, set()
    for shader in report['shaders']:
        key = shader['key']
        if not isinstance(key, str) or not KEY.fullmatch(key) or key in keys: raise ValueError('Invalid or duplicate shader key')
        keys.add(key)
        if shader['status'] != 'diagnostic_passed': raise ValueError('Incomplete shader diagnostic')
        plan_path = directory / 'reflection-plans' / (key + '.plan.json'); blob = plan_path.read_bytes()
        if digest(blob) != shader['reflection_plan']['sha256']: raise ValueError('Reflection plan digest mismatch')
        plan = json.loads(blob)
        if plan.get('diagnostic_only') is not True or plan.get('runtime_ready') is not False:
            raise ValueError('Unexpected runtime-ready diagnostic plan')
        if plan['key'] != key or plan['stage'] != shader['stage']: raise ValueError('Shader plan identity mismatch')
        assets['reflection-plans/' + plan_path.name] = blob
        for suffix, folder in (('.spv','spirv'),('.res.json','spirv'),('.metal','msl')):
            name = key + suffix; data = (directory / folder / name).read_bytes()
            if digest(data) != plan['artifacts'][name]: raise ValueError('Diagnostic artifact digest mismatch')
            assets[folder + '/' + name] = data
    if not keys: raise ValueError('Empty shader diagnostic')
    return assets, len(keys), report['source_sha256']


def package(shell, preparation, diagnostics, output):
    shell, preparation, diagnostics, output = [p.resolve() for p in (shell, preparation, diagnostics, output)]
    if output.is_relative_to(REPO) or output.is_relative_to(preparation) or output.is_relative_to(diagnostics):
        raise ValueError('Package output must stay outside source and preparation trees')
    if output.exists() or output.with_suffix('.report.json').exists(): raise FileExistsError(output)
    items, base, shell_info, plist = shell_contents(shell)
    report, rewritten, modules = module_inputs(preparation)
    assets, shaders, shader_source = diagnostics_inputs(diagnostics)
    if shader_source != report['inputs']['main']: raise ValueError('Shader/module source mismatch')
    guest = guest_dylib.build(str(rewritten), MODULES)
    manifest = dict(schema_version=1, profile='p5r', package_kind='experimental_unsigned',
        host_linked=True, guest_framework_generated=True, game_content_included=True,
        runtime_ready=False, graphics_verified=False, device_verified=False, signed=False,
        modules={name:report['outputs'][name] for name in MODULES}, diagnostic_shaders=shaders,
        shell_sha256=digest(shell.read_bytes()), guest_sha256=digest(guest), shader_chain=shell_info['shader_chain'],
        blockers=['Diagnostic shader resource types and render state remain unverified',
                  'Complete game startup and platform compatibility have not been validated',
                  'The application and Guest framework must be signed together before installation'])
    additions = {'dm/' + name:data for name, data in modules.items()}
    additions.update({'p5r-diagnostics/' + name:data for name, data in assets.items()})
    additions['dm/p5r-package.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    additions['Frameworks/Guest.framework/Guest'] = guest
    additions['Frameworks/Guest.framework/Info.plist'] = (guest_dylib.INFO_PLIST % (plist['CFBundleIdentifier'] + '.guest')).encode()
    if any(base + name == item.filename for name in additions for item, _ in items): raise ValueError('Package entry collision')
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + '.tmp')
    if temporary.exists(): raise FileExistsError(temporary)
    try:
        with zipfile.ZipFile(temporary, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
            for info, data in items: archive.writestr(info, data)
            for name, data in sorted(additions.items()):
                info = zipfile.ZipInfo(base + name); info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (0o100755 if name.endswith('/Guest') else 0o100644) << 16
                archive.writestr(info, data)
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None: raise ValueError('Package CRC verification failed')
        temporary.replace(output)
    except BaseException:
        temporary.unlink(missing_ok=True); raise
    manifest['archive_sha256'] = digest(output.read_bytes()); manifest['archive'] = str(output)
    output.with_suffix('.report.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Create a local experimental P5R IPA; game launch remains disabled until graphics are verified.')
    parser.add_argument('shell', type=Path); parser.add_argument('preparation', type=Path)
    parser.add_argument('diagnostics', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try: print(json.dumps(package(args.shell, args.preparation, args.diagnostics, args.output), indent=2))
    except (ValueError, OSError, KeyError, zipfile.BadZipFile) as error: parser.exit(1, str(error) + '\n')
