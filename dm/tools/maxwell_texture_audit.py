# 从原始 TEXS/TLDS 指令提取同句柄的类型约束；仅作旁证，不替代纹理对象/绘制状态验证。
# Extract same-handle type constraints from original TEXS/TLDS instructions; corroboration does not validate texture objects or draw state.
import hashlib
import struct

from maxwell_memory_audit import ROOT, instruction_table


TEXS = {0: 'Texture1D', 1: 'Texture2D', 2: 'Texture2D', 3: 'Texture2D',
        4: 'Texture2D, Shadow', 5: 'Texture2D, Shadow', 6: 'Texture2D, Shadow',
        7: 'Texture2D, Array', 8: 'Texture2D, Array', 9: 'Texture2D, Array, Shadow',
        10: 'Texture3D', 11: 'Texture3D', 12: 'TextureCube', 13: 'TextureCube'}
TLDS = {0: 'Texture1DOrBuffer', 1: 'Texture1D', 2: 'Texture2D', 4: 'Texture2D',
        5: 'Texture2D', 6: 'Texture2D, Multisample', 7: 'Texture3D',
        8: 'Texture2D, Array', 12: 'Texture2D'}


def audit_texture_queries(job, resource, code):
    header = 0 if job['stage'] == 'cs' else 0x50
    extent = resource.get('decoded_size')
    if (type(extent) is not int or extent < header + 16 or extent > len(code)
            or extent % 8 or len(code) % 8):
        raise ValueError('Invalid decoded texture extent; rebuild the translator')
    table, table_sha = instruction_table()
    instructions, unknown = [], []
    for offset in range(header, extent, 8):
        if (offset - header) % 32 == 0:
            continue
        word = struct.unpack_from('<Q', code, offset)[0]
        name = table[word >> 50]
        if name is None:
            unknown.append(offset)
        if name in ('Texs', 'Tlds'):
            target = (word >> 53) & 15
            instructions.append(dict(offset=offset, opcode=name, target=target,
                handle=(word >> 36) & 0x1fff, instruction_type=(TEXS if name == 'Texs' else TLDS).get(target)))
    queries = []
    for row in resource['query_audit']:
        if row['query'] != 'sampler_type':
            continue
        # 只有默认纹理句柄库可直接与立即数句柄匹配；不能跨着色器/常量库借用类型。
        # Only the default texture-handle bank can match immediate handles; never borrow types across shaders/banks.
        evidence = [i for i in instructions if row['cbuf_slot'] == -1 and i['handle'] == row['handle']]
        types = sorted({i['instruction_type'] for i in evidence if i['instruction_type']})
        queries.append(dict(handle=row['handle'], cbuf_slot=row['cbuf_slot'],
            answer=row['value'], answer_source=row['source'], evidence=evidence, candidate_types=types,
            answer_corroborated=bool(evidence) and not unknown and all(i['instruction_type'] == row['value'] for i in evidence),
            resource_object_verified=False))
    return dict(scope='same_shader_TEXS_TLDS_immediate_handle_constraints_only',
        code_sha256=hashlib.sha256(code).hexdigest(), decoded_size=extent,
        instruction_table_sha256=table_sha,
        decoder_sha256=hashlib.sha256((ROOT / 'InstDecoders.cs').read_bytes()).hexdigest(),
        emitter_sha256=hashlib.sha256((ROOT.parent / 'Instructions/InstEmitTexture.cs').read_bytes()).hexdigest(),
        unknown_instruction_offsets=unknown, queries=queries, auto_applied=False, resource_facts_verified=False)
