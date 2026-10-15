# P5R 反射草案：按 Ryujinx ResourceManager 命名和 MSL 参数成员对应资源，保留未验证的槽映射。
# P5R reflection plans: match resources using Ryujinx ResourceManager names and MSL argument members, retaining unverified slot mappings.
import hashlib
import re

from nvn_handle_layout import decode_handle


PREFIX = {'vs': 'vp', 'ps': 'fp', 'cs': 'cp'}
MEMBER = re.compile(r'\s*(.+?)\s+(\w+)\s*\[\[id\((\d+)\)\]\];\s*', re.S)


def integer(value, label, maximum=0x7fffffff):
    if type(value) is not int or not 0 <= value <= maximum:
        raise ValueError('Invalid ' + label)
    return value


def pointer_source(stage, descriptor):
    bank = integer(descriptor['cb_slot'], 'storage pointer bank')
    offset = integer(descriptor['cb_offset'], 'storage pointer word offset') * 4
    base = {'vs': 0x110, 'cs': 0x310, 'ps': 0x510}[stage]
    if bank == 0:
        if stage == 'cs' and 0x210 <= offset < 0x310 and (offset - 0x210) % 16 == 0:
            return dict(kind='ubo_ptr', reg=(offset - 0x210) // 16)
        if 0 <= offset - base < 0x100 and (offset - base) % 16 == 0:
            return dict(kind='sbuf', reg=(offset - base) // 16)
    return None


def reflection_plan(job, resource, msl):
    stage, key = job['stage'], job['key']
    if stage not in PREFIX or resource['key'] != key or resource['stage'] != stage:
        raise ValueError('Reflection resource identity mismatch')
    if job.get('diagnostic_only') is not True or job.get('resource_facts_verified') is not False:
        raise ValueError('Expected a diagnostic job with unverified facts')
    prefix = PREFIX[stage]
    descriptors, names = {}, {}
    for category in ('cbufs', 'sbufs', 'textures', 'images'):
        for index, item in enumerate(resource[category]):
            binding = integer(item['binding'], 'resource binding')
            identity = (category, index)
            if category in ('cbufs', 'sbufs'):
                slot = integer(item['slot'], 'buffer slot')
                name = f'{prefix}_{"c" if category == "cbufs" else "s"}{slot}'
            else:
                handle = integer(item['handle'], 'packed texture handle')
                bank = item['cbuf_slot']
                if type(bank) is not int or not -1 <= bank <= 0x7fffffff:
                    raise ValueError('Invalid texture constant-buffer banks')
                integer(item['array'], 'resource array length')
                table = 'tcb' if bank == -1 else f'cb{bank}'
                # 数组、图像及独立采样器名称仍匹配来源，但不据此声称后端支持。
                # Match array, image and separate-sampler provenance without claiming backend support.
                tag = 'i' if category == 'images' else 's' if item.get('type') == 0 else 't'
                name = f'{prefix}_{tag}_{table}_{handle:X}'
            if binding in descriptors or name in names:
                raise ValueError('Duplicate resource binding or name')
            descriptors[binding] = identity
            names[name] = (identity, item)

    bodies = re.findall(r'struct spvDescriptorSetBuffer0\s*\{(.*?)\};', msl, re.S)
    if len(bodies) > 1:
        raise ValueError('Duplicate MSL argument-buffer structure')
    bindings, used, seen_ids, seen_names = [], set(), set(), set()
    body = bodies[0] if bodies else ''
    for declaration in body.splitlines():
        if not declaration.strip():
            continue
        match = MEMBER.fullmatch(declaration)
        if not match:
            raise ValueError('Unsupported MSL argument member declaration')
        ty, name, aid = match.group(1).strip(), match.group(2), int(match.group(3))
        if aid in seen_ids or name in seen_names:
            raise ValueError('Duplicate MSL argument id or name')
        seen_ids.add(aid); seen_names.add(name)
        entry = dict(msl_name=name, msl_type=ty, arg_id=aid, kind='unresolved',
                     slot_mapping_verified=False, resource_type_verified=False, blockers=[])
        bindings.append(entry)
        if aid >= 64:
            entry['blockers'].append('Argument id exceeds the current runtime limit')
        if name == 'support_buffer':
            if not ty.startswith('constant ') or not ty.endswith('*'):
                raise ValueError('Unexpected support buffer type')
            entry.update(kind='support', slot_mapping_verified=True, resource_type_verified=True)
            continue
        sampler = name.endswith('Smplr')
        base_name = name[:-5] if sampler else name
        matched = names.get(base_name)
        if matched is None:
            entry['blockers'].append('No unique translator descriptor matches this MSL name')
            continue
        identity, item = matched
        used.add(identity)
        category = identity[0]
        entry['descriptor'] = dict(category=category, **item)
        if category in ('cbufs', 'sbufs'):
            if sampler or not ty.endswith('*') or not ty.startswith(('constant ', 'device ')):
                raise ValueError('Unexpected buffer member type')
            if category == 'cbufs':
                slot = item['slot']
                if slot == 1:
                    entry.update(kind='c1', bank=1, slot_mapping_verified=True)
                elif slot in (0, 2):
                    entry.update(kind='drvcb', bank=slot)
                elif 3 <= slot <= (7 if stage == 'cs' else 16):
                    entry.update(kind='cbuf', reg=slot - 3, slot_mapping_verified=True)
                entry['resource_type_verified'] = True
            else:
                flags = integer(item['flags'], 'storage usage flags')
                source = pointer_source(stage, item)
                if source:
                    entry.update(source)
                    entry['slot_mapping_verified'] = True
                entry.update(rw=bool(flags & 1), resource_type_verified=True)
                if flags & ~1:
                    entry['blockers'].append('Unknown storage usage flags')
        else:
            if sampler and ty != 'sampler':
                raise ValueError('Unexpected sampler member type')
            if item['array'] != 1 or category == 'images' or item.get('separate', False) or item.get('type') == 0:
                entry['blockers'].append('Resource arrays, images and separate descriptors require additional mapping')
                continue
            source = decode_handle(item['handle'], item['cbuf_slot'])
            if source:
                entry.update(source['sampler' if sampler else 'texture'])
                if not sampler:
                    if not ty.startswith(('texture', 'depth')):
                        raise ValueError('Unexpected texture member type')
                    if ty.startswith('texture_buffer'):
                        entry['kind'] = 'tbuf_combined' if entry['kind'] == 'tex_combined' else 'tbuf'
                entry['slot_mapping_verified'] = True
            if sampler:
                entry['resource_type_verified'] = True
        if entry['kind'] == 'unresolved':
            entry['blockers'].append('Unsupported resource slot or handle source')
        if not entry['slot_mapping_verified']:
            entry['blockers'].append('Unsupported direct uniform bank or unverified driver-bank contents')
        if not entry['resource_type_verified']:
            entry['blockers'].append('Texture type and format require independent P5R evidence')

    missing = [dict(category=category, **resource[category][index])
               for category, index in descriptors.values() if (category, index) not in used]
    blockers = ['P5R translation state and resource facts remain unverified']
    if stage == 'cs':
        blockers.append('Compute local and shared memory remain unverified')
    return dict(schema_version=1, route='B', profile='p5r', key=key, stage=stage,
                diagnostic_only=True, resource_facts_verified=False, runtime_ready=False,
                bindings=bindings, missing_descriptors=missing, blockers=blockers,
                binding_coverage_complete=not missing and all(b['kind'] != 'unresolved' for b in bindings),
                threadgroup_size=job.get('local'),
                msl_sha256=hashlib.sha256(msl.encode('utf-8')).hexdigest())
