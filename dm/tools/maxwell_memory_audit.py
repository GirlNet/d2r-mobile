# 计算代码内存审计：依照仓内 Ryujinx InstTable 的 14 位解码优先级和 Decoder 的调度字布局。
# Compute-code memory audit: follows the vendored Ryujinx InstTable's 14-bit decoding priority and Decoder's scheduling-word layout.
from collections import Counter
from functools import lru_cache
import hashlib
from pathlib import Path
import re
import struct


LOCAL = {'Ldl', 'Stl'}
SHARED = {'Atoms', 'AtomsCas', 'Lds', 'Sts'}
AMBIGUOUS = {'Ld', 'St'}
ROOT = Path(__file__).resolve().parents[1] / 'third_party/ryujinx/src/Ryujinx.Graphics.Shader/Decoders'


@lru_cache(maxsize=1)
def instruction_table():
    source = (ROOT / 'InstTable.cs').read_bytes()
    text = source.decode('utf-8')
    if 'private const int EncodingBits = 14;' not in text:
        raise ValueError('Unsupported Maxwell instruction table')
    patterns = re.findall(r'Add\("([01x]{64})", InstName\.(\w+)', text)
    if not patterns or not (LOCAL | SHARED | AMBIGUOUS) <= {name for _, name in patterns}:
        raise ValueError('Incomplete Maxwell instruction table')
    table, specificity = [None] * 16384, [-1] * 16384
    for pattern, name in patterns:
        prefix = pattern[:14]
        mask = int(''.join('0' if c == 'x' else '1' for c in prefix), 2)
        value = int(prefix.replace('x', '0'), 2)
        bits = mask.bit_count()
        for index in range(16384):
            if index & mask == value and bits > specificity[index]:
                table[index], specificity[index] = name, bits
    return table, hashlib.sha256(source).hexdigest()


def audit_compute_memory(code, decoded_size):
    if (type(decoded_size) is not int or decoded_size < 16 or decoded_size > len(code)
            or decoded_size % 8 or len(code) % 8):
        raise ValueError('Invalid decoded compute extent; rebuild the translator')
    table, source_sha = instruction_table()
    counts, unknown = Counter(), []
    # 审计整个已解码范围，包括不可达间隙；不能凭优化后的 MSL 缺少变量来证明原指令未使用内存。
    # Audit the entire decoded extent, including unreachable gaps; absent optimized MSL variables cannot prove original instructions did not use memory.
    for offset in range(0, decoded_size, 8):
        if offset % 32 == 0:
            continue
        word = struct.unpack_from('<Q', code, offset)[0]
        name = table[word >> 50]
        if name is None:
            unknown.append(offset)
        else:
            counts[name] += 1
    local, shared = sorted(LOCAL & counts.keys()), sorted(SHARED & counts.keys())
    ambiguous = sorted(AMBIGUOUS & counts.keys())
    return dict(method='vendored_maxwell_instruction_table', code_sha256=hashlib.sha256(code).hexdigest(),
                instruction_table_sha256=source_sha, decoded_size=decoded_size,
                instructions=sum(counts.values()), local_memory_ops=local, shared_memory_ops=shared,
                ambiguous_memory_ops=ambiguous, unknown_instruction_offsets=unknown,
                memory_unused_proven=not (local or shared or ambiguous or unknown))
