#!/usr/bin/env python3
# 将本地编译库整理为宿主缓存布局；保留所有未验证标记，不开启游戏启动。
# Stage locally compiled libraries in the host cache layout; retain unverified markers and disabled game launch.
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import struct

KEY = re.compile(r'[0-9a-f]{16}')
CHAIN = re.compile(r'[0-9a-f]{12}')
STAGES = {'vs': ('vertex', '顶点'), 'ps': ('fragment', '像素'), 'cs': ('kernel', '计算')}
REPO = Path(__file__).resolve().parents[2]
KINDS = {'support', 'c1', 'cbuf', 'sbuf', 'ubo_ptr', 'tex', 'tex_combined',
         'samp', 'samp_tex', 'samp_combined', 'tbuf', 'tbuf_combined'}


def digest(blob):
    return hashlib.sha256(blob).hexdigest()


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8'))


def indexed(rows, label):
    result = {}
    for row in rows:
        key = row['key']
        if not isinstance(key, str) or not KEY.fullmatch(key) or key in result:
            raise ValueError('Invalid or duplicate ' + label + ' key')
        result[key] = row
    return result


def checked_bytes(path, expected, label):
    blob = path.read_bytes()
    if digest(blob) != expected:
        raise ValueError(label + ' digest mismatch')
    return blob


def stage_shader(key, source, job, row, preparation, diagnostics, cache, chain):
    stage = row['stage']
    if stage not in STAGES or source['stage'] != stage or job['stage'] != stage or row['status'] != 'diagnostic_passed':
        raise ValueError('Shader stage/status mismatch: ' + key)
    plan = json.loads(checked_bytes(diagnostics / 'reflection-plans' / (key + '.plan.json'),
                                   row['reflection_plan']['sha256'], 'Reflection plan'))
    if (plan.get('key') != key or plan.get('stage') != stage or plan.get('profile') != 'p5r'
            or plan.get('route') != 'B' or plan.get('diagnostic_only') is not True
            or plan.get('resource_facts_verified') is not False or plan.get('runtime_ready') is not False
            or plan.get('binding_coverage_complete') is not True or plan.get('missing_descriptors')):
        raise ValueError('Expected a complete, unverified P5R reflection plan')
    for part in ('code', 'control'):
        expected = source[part + '_sha256']
        if plan['source'][part + '_sha256'] != expected:
            raise ValueError('Shader provenance mismatch: ' + part)
        blob = checked_bytes(preparation / part / (key + '.bin'), expected, part)
        expected_size = source[part + '_size'] - (0x30 if part == 'code' and stage != 'cs' else 0)
        if len(blob) != expected_size:
            raise ValueError('Shader segment size mismatch')
        if part == 'control' and (len(blob) != 0x850 or struct.unpack_from('<6I', blob) !=
                (0x98761234, 1, 15, 0x120, 11, 0x848) or struct.unpack_from('<I', blob, 32)[0] != 0x850):
            raise ValueError('Unsupported P5R control layout')
        if part == 'control':
            code_size, total_size, prefix = struct.unpack_from('<3I', blob, 0x700)
            if (code_size != source['code_size'] or total_size != code_size + source['c1_size']
                    or prefix != (0 if stage == 'cs' else 0x30)
                    or struct.unpack_from('<I', blob, 0x714)[0] != {'vs': 0, 'ps': 1, 'cs': 5}[stage]):
                raise ValueError('Control code/constants/stage mismatch')
            if stage == 'cs' and list(struct.unpack_from('<3I', blob, 0x748)) != source['compute_workgroup']:
                raise ValueError('Control compute workgroup mismatch')
    c1 = bytes.fromhex(job['c1'])
    if len(c1) > 4096 or len(c1) != source['c1_size'] or digest(c1) != source['c1_sha256'] or digest(c1) != plan['source']['c1_sha256']:
        raise ValueError('Constant segment provenance/size mismatch')
    if source['control_sha256'][:16] != key:
        raise ValueError('Control key mismatch')
    ids = set()
    for binding in plan['bindings']:
        aid = binding['arg_id']
        if (binding['kind'] not in KINDS or binding.get('slot_mapping_verified') is not True
                or type(aid) is not int or not 0 <= aid < 64 or aid in ids):
            raise ValueError('Unsupported or duplicate runtime binding')
        ids.add(aid)
    if stage == 'cs' and (plan.get('compute_memory_audit', {}).get('memory_unused_proven') is not True
                          or plan.get('threadgroup_size') != source['compute_workgroup']
                          or job.get('local') != source['compute_workgroup']):
        raise ValueError('Unverified compute memory/workgroup configuration')
    msl = checked_bytes(diagnostics / 'msl' / (key + '.metal'), plan['msl_sha256'], 'MSL')
    for name, folder in ((key + '.metal', 'msl'), (key + '.spv', 'spirv'), (key + '.res.json', 'spirv')):
        checked_bytes(diagnostics / folder / name, plan['artifacts'][name], 'Diagnostic artifact')
    entries = re.findall(rb'\b(vertex|fragment|kernel)\s+\w+\s+(\w+)\s*\(', msl)
    if len(entries) != 1 or entries[0][0].decode() != STAGES[stage][0]:
        raise ValueError('Ambiguous or mismatched MSL entry point')
    native = [item for item in row.get('metal', []) if item.get('sdk') == 'iphoneos']
    if (len(native) != 1 or native[0].get('target') != 'air64-apple-ios18.0'
            or native[0].get('strict_float') is not True or native[0].get('diagnostic_only') is not True
            or native[0].get('source_sha256') != digest(msl)):
        raise ValueError('Missing source-matched strict iOS native library')
    # Resolve the expected file inside this diagnostic directory, never a report-supplied path.
    library = checked_bytes(diagnostics / 'metal-iphoneos' / (key + '.metallib'), native[0]['sha256'], 'Native library')
    if len(library) <= 4 or library[:4] != b'MTLB':
        raise ValueError('Invalid native Metal library')
    reflection = dict(plan, key=key + '_b', dm_ctl=key, chain=chain,
                      entry=entries[0][1].decode(), msl_entry_kind=entries[0][0].decode(),
                      c1=c1.hex(), drv_reads={}, drv_unfillable=[])
    # No driver-bank bindings are accepted above; do not infer dynamic c0/c2 contents.
    # Without a raster proof the existing backend uses its conservative defaults.
    reflection['raster'] = dict(colors=[item['location'] for item in plan.get('fragment_outputs', [])], discard=1, sample_mask=1)
    assets = {key + '_b.metallib': library, key + '_b.metal': msl,
              key + '_b.json': (json.dumps(reflection, indent=2) + '\n').encode()}
    hashes = {}
    for name, blob in assets.items():
        (cache / name).write_bytes(blob)
        hashes[name] = digest(blob)
    return dict(key=key, stage=stage, c1_bytes=len(c1), artifacts=hashes)


def stage_bundle(preparation, diagnostics, output, chain, workers=4):
    preparation, diagnostics, output = (Path(path).resolve() for path in (preparation, diagnostics, output))
    if not CHAIN.fullmatch(chain) or type(workers) is not int or not 1 <= workers <= 16:
        raise ValueError('Invalid chain or worker count')
    if any(output.is_relative_to(path) for path in (REPO, preparation, diagnostics)):
        raise ValueError('Staged game artifacts must stay outside repository and input trees')
    source = read_json(preparation / 'shader-preparation.json')
    report_blob = (diagnostics / 'diagnostic-report.json').read_bytes()
    report = json.loads(report_blob)
    if (source.get('schema_version') != 2 or report.get('status') != 'diagnostic_passed'
            or report.get('diagnostic_only') is not True or source['source_sha256'] != report['source_sha256']):
        raise ValueError('Shader preparation/diagnostic source mismatch or incomplete inputs')
    sources = indexed(source['shaders'], 'preparation')
    jobs = indexed(read_json(preparation / 'diagnostic-jobs.json'), 'job')
    shaders = indexed(report['shaders'], 'diagnostic')
    if not sources or sources.keys() != jobs.keys() or sources.keys() != shaders.keys():
        raise ValueError('Incomplete shader coverage across preparation, jobs and diagnostics')
    output.mkdir(parents=True, exist_ok=False)
    cache = output / 'msl' / ('b-' + chain)
    cache.mkdir(parents=True)
    dm = output / 'dm'
    dm.mkdir()
    result = dict(schema_version=1, profile='p5r', status='staging', shader_chain=chain,
                  source_sha256=source['source_sha256'], diagnostic_report_sha256=digest(report_blob),
                  diagnostic_only=True, runtime_ready=False, graphics_verified=False,
                  game_gpu_output_verified=False, game_launch_enabled=False)
    report_path = output / 'bundle-report.json'
    try:
        with ThreadPoolExecutor(max_workers=workers) as executor:
            staged = list(executor.map(lambda key: stage_shader(key, sources[key], jobs[key], shaders[key],
                preparation, diagnostics, cache, chain), sorted(sources)))
        mapping = 'package\tindex\tstage\tcontrol_key\n' + ''.join(
            'p5r\t0\t' + STAGES[row['stage']][1] + '\t' + row['key'] + '\n' for row in staged)
        (dm / 'shader_map.tsv').write_text(mapping, encoding='utf-8')
        # No bound has been proven for dynamic c1 accesses: preserve exclusive 64 KiB banks.
        (dm / 'c1_full.tsv').write_text('# chain b-' + chain + '\n' + ''.join(row['key'] + '\n' for row in staged), encoding='utf-8')
        result.update(status='staged_unverified', shaders=len(staged), shader_records=staged,
                      blockers=['Translation defaults and actual game resource/state contracts remain unverified',
                                'Staged reflections intentionally retain markers rejected by the runtime loader'])
    except BaseException as error:
        result.update(status='staging_failed', error=str(error))
        raise
    finally:
        report_path.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Stage P5R iOS libraries in host cache layout without claiming runtime readiness.')
    parser.add_argument('preparation', type=Path)
    parser.add_argument('diagnostics', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--chain', required=True)
    parser.add_argument('--workers', type=int, default=4)
    args = parser.parse_args()
    try:
        result = stage_bundle(args.preparation, args.diagnostics, args.output, args.chain, args.workers)
        print(json.dumps({key: value for key, value in result.items() if key != 'shader_records'}, indent=2))
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, str(error) + '\n')
