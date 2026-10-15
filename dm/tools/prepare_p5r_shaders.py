#!/usr/bin/env python3
# 提取本地 P5R NSO 中已确认的内嵌 NVN 11 控制块与代码，供诊断翻译；不复用 D2R 映射或类型事实。
# Extract the inspected embedded NVN 11 controls/code from a local P5R NSO for diagnostic translation; never reuse D2R maps/type facts.
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

import lz4.block
from inspect_exefs import inspect_module

CONTROL_MAGIC = bytes.fromhex('34127698')
CODE_MAGIC = bytes.fromhex('78563412')
CONTROL_SIZE = 0x850
HEADER_FIELDS = {4: 1, 8: 15, 12: 0x120, 16: 11, 20: 0x848, 32: CONTROL_SIZE}
STAGES = {0: 'vs', 1: 'ps', 5: 'cs'}


def compute_workgroup(control):
    if len(control) != CONTROL_SIZE or any(word(control, off) != value for off, value in HEADER_FIELDS.items()):
        raise ValueError('Unsupported compute control layout')
    if word(control, 0) != 0x98761234 or word(control, 0x714) != 5:
        raise ValueError('Expected an NVN 11 compute control')
    # SDK 计算元数据访问器返回这三个 uint32 字段；1024 是本准备流程的线程数上限。
    # The SDK compute metadata accessor returns these three uint32 fields; 1024 is this preparation pipeline's thread-count limit.
    group = [word(control, off) for off in (0x748, 0x74c, 0x750)]
    if any(not 0 < n <= 0xffff for n in group) or group[0] * group[1] * group[2] > 1024:
        raise ValueError('Invalid or unsupported compute workgroup')
    return group


def word(data, offset):
    if offset < 0 or offset + 4 > len(data):
        raise ValueError('Truncated shader field')
    return struct.unpack_from('<I', data, offset)[0]


def scan_segment(data, memory_offset=0):
    records, rejected = [], []
    occupied_end = 0
    for match in re.finditer(CONTROL_MAGIC, data):
        start = match.start()
        if start < occupied_end:
            continue  # 代码/常数里的相同字节不是新的控制块 | Matching bytes inside code/constants are not new controls.
        if start + 0x24 > len(data) or any(word(data, start + off) != value for off, value in HEADER_FIELDS.items()):
            rejected.append(memory_offset + start)
            continue
        if start + CONTROL_SIZE > len(data):
            raise ValueError(f'Truncated NVN 11 control at {memory_offset + start:#x}')
        control = data[start:start + CONTROL_SIZE]
        code_size, total_size, prefix, stage_number = [word(control, off) for off in (0x700, 0x704, 0x708, 0x714)]
        if stage_number not in STAGES:
            raise ValueError(f'Unsupported shader stage {stage_number}')
        stage = STAGES[stage_number]
        code_start = start + CONTROL_SIZE
        if not 0 < code_size <= total_size <= 16 * 1024 * 1024 or code_start + total_size > len(data):
            raise ValueError(f'Invalid code/constants range at {memory_offset + start:#x}')
        code = data[code_start:code_start + code_size]
        c1 = data[code_start + code_size:code_start + total_size]
        if stage == 'cs':
            if prefix != 0 or code_size % 8:
                raise ValueError('Invalid compute code layout')
        else:
            if prefix != 0x30 or len(code) < 0x80 or code[:4] != CODE_MAGIC:
                raise ValueError('Invalid graphics code prefix')
            sph_stage = (word(code, 0x30) >> 10) & 15
            if sph_stage != {'vs': 1, 'ps': 5}[stage] or (code_size - prefix) % 8:
                raise ValueError('Control/SPH stage or graphics code alignment mismatch')
        records.append(dict(control_address=memory_offset + start, code_address=memory_offset + code_start,
                            key=hashlib.sha256(control).hexdigest()[:16], control_sha256=hashlib.sha256(control).hexdigest(),
                            control_size=CONTROL_SIZE, stage=stage, code_size=code_size, c1_size=len(c1),
                            code_sha256=hashlib.sha256(code[prefix:]).hexdigest(),
                            c1_sha256=hashlib.sha256(c1).hexdigest(), code=code[prefix:], c1=c1,
                            control=control, compute_workgroup=compute_workgroup(control) if stage == 'cs' else None))
        occupied_end = code_start + total_size
    return records, rejected


def extract_module(path):
    inventory = inspect_module(path)  # 先验证原 NSO 的段与散列，再解压扫描 | Validate original NSO segments/hashes before scanning.
    raw = path.read_bytes()
    records, rejected = [], []
    for segment in inventory['segments']:
        blob = raw[segment['file_offset']:segment['file_offset'] + segment['stored_size']]
        if segment['compressed']:
            blob = lz4.block.decompress(blob, uncompressed_size=segment['size'])
        found, skipped = scan_segment(blob, segment['memory_offset'])
        for record in found:
            record['segment'] = segment['name']
        records.extend(found); rejected.extend(skipped)
    if not records:
        raise ValueError('No supported embedded NVN 11 shaders found')
    keys = {}
    for record in records:
        value = (record['control_sha256'], record['code_sha256'], hashlib.sha256(record['c1']).hexdigest())
        if record['key'] in keys and keys[record['key']] != value:
            raise ValueError(f"Ambiguous control key {record['key']}")
        keys[record['key']] = value
    return inventory, records, rejected


def write_outputs(workspace, inventory, records, rejected):
    # 产物含游戏衍生代码；只写新的仓库外目录，拒绝覆盖已有输出。
    # Outputs contain game-derived code; use a new directory outside the repo and refuse existing outputs.
    workspace.mkdir(parents=True, exist_ok=False)
    code_dir = workspace / 'code'; code_dir.mkdir()
    control_dir = workspace / 'control'; control_dir.mkdir()
    jobs, rows = [], []
    for record in records:
        code_path = code_dir / (record['key'] + '.bin')
        if not code_path.exists():
            code_path.write_bytes(record['code'])
        (control_dir / (record['key'] + '.bin')).write_bytes(record['control'])
        jobs.append(dict(key=record['key'], stage=record['stage'], code=str(code_path.resolve()),
                         c1=record['c1'].hex(), tex={}, img={}, attr={}, fout={}, debug=True, reduced=False,
                         diagnostic_only=True, resource_facts_verified=False))
        if record['stage'] == 'cs': jobs[-1]['local'] = record['compute_workgroup']
        rows.append({k: v for k, v in record.items() if k not in ('code', 'c1', 'control')})
    manifest = dict(schema_version=2, status='extracted_for_diagnostic_translation', source_sha256=inventory['file_sha256'],
                    build_id=inventory['build_id'], shaders=rows, rejected_magic_addresses=rejected,
                    translation_ready=False, graphics_verified=False, runnable_verified=False,
                    caveat='Embedded shaders only. Jobs use unverified resource/state defaults; SPIR-V is diagnostic, not a validated shader library.')
    for name, value in [('shader-preparation.json', manifest), ('diagnostic-jobs.json', jobs)]:
        (workspace / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return manifest


def main():
    parser = argparse.ArgumentParser(description='Extract embedded P5R NVN 11 shaders for local diagnostics, not a playable build.')
    parser.add_argument('main_nso', type=Path)
    parser.add_argument('workspace', type=Path, help='New output directory outside the repository and source directory')
    args = parser.parse_args()
    source, output = args.main_nso.resolve(), args.workspace.resolve()
    repo = Path(__file__).resolve().parents[2]
    if output.is_relative_to(repo) or output.is_relative_to(source.parent):
        parser.error('Workspace must be outside the repository and source directory')
    try:
        inventory, records, rejected = extract_module(source)
        write_outputs(output, inventory, records, rejected)
        print(f'Extracted {len(records)} embedded shaders; resource facts and rendered output remain UNVERIFIED.')
        return 0
    except (ValueError, OSError, lz4.block.LZ4BlockError) as error:
        print(f'Shader preparation failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
