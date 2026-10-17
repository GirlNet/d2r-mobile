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

DIMENSIONS = {0: 1, 1: 1 | 0x100, 2: 3, 3: 3 | 0x100,
              4: 4, 5: 4 | 0x100, 6: 5, 7: 5 | 0x100}
TYPE_NAMES = {'Texture1D': 1, 'Texture2D': 3, 'Texture3D': 4, 'TextureCube': 5}


def _numeric_type(name):
    if not name:
        return None
    parts = name.split(', ')
    value = TYPE_NAMES.get(parts[0])
    if value is None:
        return None  # In particular, retain the 1D/buffer ambiguity.
    return value | (0x100 if 'Array' in parts else 0) | (0x200 if 'Multisample' in parts else 0) | (0x400 if 'Shadow' in parts else 0)


def audit_texture_resources(job, resource, code):
    """Corroborate shader-declared shapes directly from original instruction bits.

    This is independent of translated MSL/default query answers. It establishes
    neither bound-object formats nor that the game uses compatible render state.
    """
    header = 0 if job['stage'] == 'cs' else 0x50
    extent = resource.get('decoded_size')
    if (type(extent) is not int or extent < header + 16 or extent > len(code)
            or extent % 8 or len(code) % 8):
        raise ValueError('Invalid decoded texture extent; rebuild the translator')
    table, table_sha = instruction_table()
    instructions, unknown, unsupported = [], [], []
    for offset in range(header, extent, 8):
        if (offset - header) % 32 == 0:
            continue
        word = struct.unpack_from('<Q', code, offset)[0]
        name = table[word >> 50]
        if name is None:
            unknown.append(offset)
            continue
        value = None
        if name in ('Texs', 'TexsF16', 'Tlds', 'TldsF16'):
            target = (word >> 53) & 15
            value = _numeric_type((TEXS if name.startswith('Texs') else TLDS).get(target))
        elif name in ('Tld4s', 'Tld4sF16'):
            # Scalar gather has fixed 2D coordinates; Dc selects comparison.
            value = 3 | (0x400 if word & (1 << 50) else 0)
        elif name in ('Tex', 'Tld', 'Tld4', 'Txd', 'Tmml'):
            value = DIMENSIONS[(word >> 28) & 7]
            if name == 'Tld' and ((word >> 28) & 7) == 0:
                value = None  # Int-coordinate 1D may actually be a buffer.
            if name in ('Tex', 'Tld4') and word & (1 << 50):
                value |= 0x400
            if value is not None and name == 'Tld' and word & (1 << 50):
                value |= 0x200
        elif name == 'Txq':
            # TXQ depends on the descriptor; it supplies no independent shape.
            continue
        elif name.startswith(('Tex', 'Tld', 'Txd', 'Tmml', 'Txq', 'Suld', 'Sust', 'Suatom')):
            unsupported.append(dict(offset=offset, opcode=name))
            continue
        else:
            continue
        instructions.append(dict(offset=offset, opcode=name, handle=(word >> 36) & 0x1fff,
                                 shader_type=value))
    bindings = []
    for descriptor in resource.get('textures', []):
        evidence = [i for i in instructions if descriptor['cbuf_slot'] == -1 and i['handle'] == descriptor['handle']]
        types = sorted({i['shader_type'] for i in evidence if i['shader_type'] is not None})
        bindings.append(dict(binding=descriptor['binding'], handle=descriptor['handle'],
            cbuf_slot=descriptor['cbuf_slot'], translated_type=descriptor['type'],
            evidence=evidence, candidate_types=types,
            shader_shape_corroborated=bool(evidence) and not (unknown or unsupported)
                and descriptor.get('array') == 1 and not descriptor.get('separate', False)
                and all(i['shader_type'] == descriptor['type'] for i in evidence),
            bound_resource_verified=False, sample_format_verified=False))
    return dict(schema_version=1, scope='original_immediate_texture_instruction_shapes',
        code_sha256=hashlib.sha256(code).hexdigest(), decoded_size=extent,
        instruction_table_sha256=table_sha,
        decoder_sha256=hashlib.sha256((ROOT / 'InstDecoders.cs').read_bytes()).hexdigest(),
        emitter_sha256=hashlib.sha256((ROOT.parent / 'Instructions/InstEmitTexture.cs').read_bytes()).hexdigest(),
        unknown_instruction_offsets=unknown, unsupported_texture_instructions=unsupported,
        bindings=bindings, all_shader_shapes_corroborated=all(b['shader_shape_corroborated'] for b in bindings)
            and not (unknown or unsupported), resource_facts_verified=False, runtime_ready=False)


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
