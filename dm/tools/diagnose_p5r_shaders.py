#!/usr/bin/env python3
# P5R 本地诊断流水线：校验提取来源，翻译、验证并审计资源；可选苹果编译，始终不生成运行时库。
# Local P5R diagnostic pipeline: check extracted provenance, translate, validate and audit resources; optional Apple compilation never produces runtime libraries.
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import struct
import sys
from nvn_handle_layout import decode_handle
from maxwell_memory_audit import audit_compute_memory
from p5r_reflection import reflection_plan
from prepare_p5r_shaders import CONTROL_SIZE, HEADER_FIELDS, STAGES, compute_workgroup, word


MSL_OPTIONS = ['--msl', '--msl-version', '20300', '--msl-argument-buffers',
               '--msl-texture-buffer-native', '--msl-pad-fragment-output']
KEY = re.compile(r'[0-9a-f]{16}')


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8'))


def save_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def load_jobs(preparation):
    manifest = read_json(preparation / 'shader-preparation.json')
    jobs = read_json(preparation / 'diagnostic-jobs.json')
    if manifest.get('schema_version') != 2 or manifest.get('translation_ready') is not False:
        raise ValueError('Expected diagnostic extraction schema 2; rerun prepare_p5r_shaders.py')
    records = {}
    for row in manifest['shaders']:
        key = row['key']
        if not isinstance(key, str) or not KEY.fullmatch(key):
            raise ValueError('Invalid shader key')
        if key in records and records[key] != row:
            raise ValueError('Conflicting duplicate shader records')
        records[key] = row
    if not records:
        raise ValueError('Empty shader manifest')
    unique = {}
    for job in jobs:
        key = job['key']
        if key not in records or key in unique:
            raise ValueError('Unknown or duplicate diagnostic job')
        row = records[key]
        control_path = (preparation / 'control' / (key + '.bin')).resolve()
        if not control_path.is_relative_to(preparation):
            raise ValueError('Control must stay within the extraction directory')
        control = control_path.read_bytes()
        if len(control) != CONTROL_SIZE or hashlib.sha256(control).hexdigest() != row['control_sha256']:
            raise ValueError(f'Control digest mismatch: {key}')
        if (row['control_sha256'][:16] != key or word(control, 0) != 0x98761234
                or any(word(control, off) != value for off, value in HEADER_FIELDS.items())
                or STAGES.get(word(control, 0x714)) != job['stage']):
            raise ValueError(f'Control layout or stage mismatch: {key}')
        code = Path(job['code']).resolve()
        if not code.is_relative_to(preparation) or code == preparation:
            raise ValueError('Code must stay within the extraction directory')
        if hashlib.sha256(code.read_bytes()).hexdigest() != row['code_sha256']:
            raise ValueError(f'Code digest mismatch: {key}')
        constants = bytes.fromhex(job['c1'])
        if len(constants) != row['c1_size']:
            raise ValueError(f'Constant length mismatch: {key}')
        if row.get('c1_sha256') is None:
            raise ValueError('Extraction lacks constant digests; rerun prepare_p5r_shaders.py')
        if hashlib.sha256(constants).hexdigest() != row['c1_sha256']:
            raise ValueError(f'Constant digest mismatch: {key}')
        if job['stage'] not in ('vs', 'ps', 'cs') or job['stage'] != row['stage']:
            raise ValueError(f'Stage mismatch: {key}')
        if (job.get('diagnostic_only') is not True or job.get('resource_facts_verified') is not False
                or job.get('debug') is not True or job.get('reduced') is not False):
            raise ValueError('Expected diagnostic jobs with strict floating point and AST optimization disabled')
        if any(job.get(field) for field in ('tex', 'img', 'attr', 'fout', 'shared')):
            raise ValueError('This pipeline accepts extracted diagnostic defaults only')
        expected_group = compute_workgroup(control) if job['stage'] == 'cs' else None
        if job.get('local') != expected_group or row.get('compute_workgroup') != expected_group:
            raise ValueError(f'Compute workgroup does not match the hashed control: {key}')
        unique[key] = dict(job, code=str(code))
    if unique.keys() != records.keys():
        raise ValueError('Manifest/job coverage mismatch')
    return manifest, list(unique.values())


def spirv_compute_workgroup(path):
    blob = path.read_bytes()
    if len(blob) < 20 or len(blob) % 4 or blob[:4] != bytes.fromhex('03022307'):
        raise ValueError('Invalid SPIR-V header')
    words = struct.unpack('<' + 'I' * (len(blob) // 4), blob)
    entries, modes = [], []
    offset = 5
    while offset < len(words):
        size, opcode = words[offset] >> 16, words[offset] & 0xffff
        if not size or offset + size > len(words):
            raise ValueError('Invalid SPIR-V instruction size')
        instruction = words[offset:offset + size]
        if opcode == 15 and size >= 4 and instruction[1] == 5:
            entries.append(instruction[2])
        if opcode == 16 and size == 6 and instruction[2] == 17:
            modes.append((instruction[1], list(instruction[3:6])))
        offset += size
    matching = [group for entry, group in modes if entry in entries]
    if len(entries) != 1 or len(matching) != 1:
        raise ValueError('Expected one compute entry point and literal LocalSize mode')
    return matching[0]


def run_command(command, log, timeout=120):
    try:
        result = subprocess.run([str(arg) for arg in command], capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        log.write_text(str(error), encoding='utf-8')
        raise RuntimeError(f'Cannot execute {command[0]}; see {log.name}') from error
    log.write_bytes(result.stdout + b'\n' + result.stderr)
    if result.returncode:
        raise RuntimeError(f'{command[0]} exited {result.returncode}; see {log.name}')


def audit_resources(job, resource):
    if resource['key'] != job['key'] or resource['stage'] != job['stage']:
        raise ValueError('Translator resource identity mismatch')
    # 记录原始地址并解码组合/分离 API 表；缓冲槽在反射草案中另行核对，不推断资源类型或绘制状态。
    # Record raw addresses and decode combined/separate API tables; check buffer slots separately in reflection plans without inferring resource types or draw state.
    handles = []
    for kind in ('textures', 'images'):
        for item in resource[kind]:
            handle = item['handle']
            if type(handle) is not int or not 0 <= handle <= 0x7fffffff:
                raise ValueError('Invalid packed texture handle')
            offset = (handle & 0x3fff) * 4
            bank = item['cbuf_slot']
            handle_type = handle >> 28
            handles.append(dict(kind=kind, binding=item['binding'], packed_handle=handle,
                                cbuf_slot=bank, texture_byte_offset=offset,
                                sampler_byte_offset=((handle >> 14) & 0x3fff) * 4,
                                handle_type=handle_type, array_length=item['array'],
                                translated_type=item['type'], translated_format=item['format'],
                                d2r_texture_range_match=(bank == -1 or bank & 0xffff == 2)
                                and 0x168 <= offset < 0x568 and (offset - 0x168) % 8 == 0,
                                handle_source=decode_handle(handle, bank) if kind == 'textures' and item['array'] == 1 else None))
    return dict(resource_bindings_verified=False, render_state_verified=False,
                constant_buffers=resource['cbufs'], storage_buffers=resource['sbufs'],
                handles=handles, translator_notes=resource['notes'],
                compute_configuration_verified=False if job['stage'] == 'cs' else None,
                compute_workgroup=job.get('local'),
                compute_workgroup_verified=bool(job.get('local')) if job['stage'] == 'cs' else None,
                blockers=['P5R texture types, driver-bank contents and render state require independent evidence']
                + (['Compute local and shared memory remain unverified'] if job['stage'] == 'cs' else []))


def compile_metal(msl, directory, sdk, xcrun='xcrun', runner=run_command):
    directory.mkdir(parents=True, exist_ok=True)
    air = directory / (msl.stem + '.air')
    library = directory / (msl.stem + '.metallib')
    minimum = ['-mios-version-min=18.0'] if sdk == 'iphoneos' else []
    runner([xcrun, '-sdk', sdk, 'metal', '-c', *minimum, msl, '-o', air],
           directory / (msl.stem + '-metal.log'))
    runner([xcrun, '-sdk', sdk, 'metallib', air, '-o', library],
           directory / (msl.stem + '-metallib.log'))
    if not library.is_file() or not library.stat().st_size:
        raise RuntimeError('Metal compiler did not produce a nonempty library')
    return dict(sdk=sdk, path=str(library), sha256=hashlib.sha256(library.read_bytes()).hexdigest(),
                diagnostic_only=True, gpu_output_verified=False)


def diagnose(preparation, output, translator, validator, cross, sdks=(), xcrun='xcrun', runner=run_command):
    preparation, output = preparation.resolve(), output.resolve()
    repo = Path(__file__).resolve().parents[2]
    if output.is_relative_to(repo) or output.is_relative_to(preparation) or preparation.is_relative_to(output):
        raise ValueError('Output must be a new directory outside the repository and extraction tree')
    if any(sdk not in ('macosx', 'iphoneos') for sdk in sdks):
        raise ValueError('Unsupported Metal SDK')
    manifest, jobs = load_jobs(preparation)
    # 提取文件保持只读；运行时文件名/链目录不出现在诊断输出中。
    # Extraction files remain read-only; diagnostic outputs use neither runtime filenames nor chain directories.
    output.mkdir(parents=True, exist_ok=False)
    spv = output / 'spirv'; spv.mkdir()
    msl_dir = output / 'msl'; msl_dir.mkdir()
    reflection_dir = output / 'reflection-plans'; reflection_dir.mkdir()
    jobs_path = output / 'jobs.json'; save_json(jobs_path, jobs)
    report = dict(schema_version=1, status='running', diagnostic_only=True,
                  source_sha256=manifest['source_sha256'], build_id=manifest['build_id'],
                  resource_bindings_verified=False, graphics_verified=False, runnable_verified=False,
                  tools={}, shaders=[], errors=[], requested_metal_sdks=list(sdks))
    report_path = output / 'diagnostic-report.json'
    save_json(report_path, report)
    try:
        for name, executable in [('translator', translator), ('validator', validator), ('spirv_cross', cross)]:
            path = Path(executable).resolve()
            report['tools'][name] = dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        # 翻译器报告嵌入源码的指纹，避免只记录 .NET 启动器而漏掉程序版本。
        # Record the translator's embedded-source fingerprint, rather than only its .NET launcher version.
        runner([translator, '--source-sha'], output / 'translator-source.log')
        source_sha = (output / 'translator-source.log').read_text(encoding='utf-8').strip()
        if not KEY.fullmatch(source_sha):
            raise ValueError('Invalid translator source fingerprint')
        report['tools']['translator']['source_sha16'] = source_sha
        try:
            runner([translator, jobs_path, spv], output / 'translation.log', timeout=600)
        except RuntimeError as error:
            report['errors'].append(str(error))
        for job in jobs:
            key = job['key']; row = dict(key=key, stage=job['stage'], status='running', completed=[])
            report['shaders'].append(row)
            try:
                binary = spv / (key + '.spv')
                resource = read_json(spv / (key + '.res.json'))
                if not binary.is_file():
                    raise ValueError('Translator did not produce SPIR-V')
                row['audit'] = audit_resources(job, resource)
                row['completed'].append('translated')
                runner([validator, '--target-env', 'vulkan1.2', binary], output / (key + '-validation.log'))
                row['completed'].append('spirv_validated')
                if job['stage'] == 'cs':
                    row['spirv_compute_workgroup'] = spirv_compute_workgroup(binary)
                    if row['spirv_compute_workgroup'] != job['local']:
                        raise ValueError('SPIR-V LocalSize does not match the extracted control')
                    row['completed'].append('compute_workgroup_validated')
                    row['compute_memory_audit'] = audit_compute_memory(Path(job['code']).read_bytes(), resource.get('decoded_size'))
                msl = msl_dir / (key + '.metal')
                runner([cross, binary, *MSL_OPTIONS, '--output', msl], output / (key + '-msl.log'))
                if not msl.is_file() or not msl.stat().st_size:
                    raise ValueError('SPIRV-Cross did not produce MSL')
                row['completed'].append('msl_generated')
                plan = reflection_plan(job, resource, msl.read_bytes().decode('utf-8'))
                row['audit']['buffer_slot_mapping_verified'] = not plan['missing_descriptors'] and all(
                    b['slot_mapping_verified'] for b in plan['bindings']
                    if b.get('descriptor', {}).get('category') in ('cbufs', 'sbufs'))
                if job['stage'] == 'cs':
                    plan['compute_memory_audit'] = row['compute_memory_audit']
                    if plan['compute_memory_audit']['memory_unused_proven']:
                        plan['blockers'].remove('Compute local and shared memory remain unverified')
                plan['source'] = next({field: record[field] for field in
                                     ('control_sha256', 'code_sha256', 'c1_sha256')}
                                    for record in manifest['shaders'] if record['key'] == key)
                plan['artifacts'] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                     for path in (binary, spv / (key + '.res.json'), msl)}
                plan_path = reflection_dir / (key + '.plan.json'); save_json(plan_path, plan)
                row['reflection_plan'] = dict(path=str(plan_path),
                    sha256=hashlib.sha256(plan_path.read_bytes()).hexdigest(),
                    binding_coverage_complete=plan['binding_coverage_complete'],
                    bindings=len(plan['bindings']),
                    missing_descriptors=len(plan['missing_descriptors']),
                    unresolved=sum(b['kind'] == 'unresolved' for b in plan['bindings']),
                    unverified=sum(bool(b['blockers']) for b in plan['bindings']), runtime_ready=False)
                row['completed'].append('reflection_planned')
                row['metal'] = []
                for sdk in sdks:
                    row['metal'].append(compile_metal(msl, output / ('metal-' + sdk), sdk, xcrun, runner))
                    row['completed'].append('metal_compiled_' + sdk)
                row['status'] = 'diagnostic_passed'
            except (ValueError, OSError, RuntimeError, KeyError, TypeError) as error:
                row.update(status='failed', error=str(error))
            save_json(report_path, report)
        report['summary'] = dict(shaders=len(jobs), passed=sum(r['status'] == 'diagnostic_passed' for r in report['shaders']),
                                 stages=dict(Counter(j['stage'] for j in jobs)),
                                 shaders_with_textures=sum(bool(r.get('audit', {}).get('handles')) for r in report['shaders']),
                                 shaders_outside_d2r_texture_layout=sum(any(not h['d2r_texture_range_match']
                                     for h in r.get('audit', {}).get('handles', [])) for r in report['shaders']),
                                 shaders_with_unresolved_handles=sum(any(h['handle_source'] is None
                                     for h in r.get('audit', {}).get('handles', [])) for r in report['shaders']),
                                 reflection_plans=sum('reflection_plan' in r for r in report['shaders']),
                                 reflection_plans_with_complete_binding_coverage=sum(
                                     r.get('reflection_plan', {}).get('binding_coverage_complete', False)
                                     for r in report['shaders']))
        report['status'] = 'diagnostic_passed' if report['summary']['passed'] == len(jobs) and not report['errors'] else 'failed'
    except (ValueError, OSError, RuntimeError) as error:
        report['errors'].append(str(error)); report['status'] = 'failed'
    save_json(report_path, report)
    return report


def main():
    parser = argparse.ArgumentParser(description='Run local P5R shader diagnostics; outputs are not runtime assets.')
    parser.add_argument('preparation', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--translator', type=Path, required=True)
    parser.add_argument('--spirv-val', type=Path, required=True)
    parser.add_argument('--spirv-cross', type=Path, required=True)
    parser.add_argument('--metal-sdk', action='append', choices=['macosx', 'iphoneos'], default=[])
    args = parser.parse_args()
    try:
        report = diagnose(args.preparation, args.output, args.translator.resolve(), args.spirv_val.resolve(),
                          args.spirv_cross.resolve(), tuple(dict.fromkeys(args.metal_sdk)))
        print(json.dumps(dict(status=report['status'], summary=report.get('summary'),
                              report=str(args.output.resolve() / 'diagnostic-report.json')), indent=2))
        return 0 if report['status'] == 'diagnostic_passed' else 1
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f'Diagnostic preparation failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
