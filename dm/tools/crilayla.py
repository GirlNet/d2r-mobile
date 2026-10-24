"""Bounded CRILAYLA decompression for locally owned CPK entries.

The format stores a 256-byte prefix after a backwards, MSB-first bitstream.
No files are opened or written here. Malformed streams fail before an out-of-
range read/write or an allocation above the caller's limit.
"""
import struct


def decompress(data, expected_size=None, maximum=256 * 1024 * 1024):
    if len(data) < 16 or data[:8] != b'CRILAYLA':
        raise ValueError('Expected a CRILAYLA entry')
    body_size, compressed_size = struct.unpack_from('<II', data, 8)
    total = body_size + 256
    if total > maximum or (expected_size is not None and total != expected_size):
        raise ValueError('CRILAYLA output size mismatch or limit exceeded')
    prefix = 16 + compressed_size
    if prefix > len(data) or len(data) - prefix < 256:
        raise ValueError('CRILAYLA prefix outside entry')
    output = bytearray(total)
    output[:256] = data[prefix:prefix + 256]
    index, pool, remaining = prefix - 1, 0, 0

    def bits(count):
        nonlocal index, pool, remaining
        value = 0
        while count:
            if not remaining:
                if index < 16:
                    raise ValueError('Truncated CRILAYLA bitstream')
                pool = data[index]; index -= 1; remaining = 8
            take = min(count, remaining)
            value = (value << take) | ((pool >> (remaining - take)) & ((1 << take) - 1))
            remaining -= take; count -= take
        return value

    position = total - 1
    while position >= 256:
        if not bits(1):
            output[position] = bits(8); position -= 1
            continue
        distance = bits(13) + 3
        length = 3
        for width in (2, 3, 5, 8):
            part = bits(width); length += part
            if part != (1 << width) - 1:
                break
        else:
            while True:
                part = bits(8); length += part
                if part != 255:
                    break
                if length > position - 255:
                    raise ValueError('CRILAYLA back-reference overruns output')
        if distance > total - position - 1 or length > position - 255:
            raise ValueError('Invalid CRILAYLA back-reference')
        start = position - length + 1
        if length <= distance:
            output[start:position + 1] = output[start + distance:position + 1 + distance]
        else:
            # Repeating the already decoded suffix is equivalent to the
            # backwards overlapping LZ copy, without a Python loop per byte.
            pattern = output[position + 1:position + distance + 1]
            output[start:position + 1] = (pattern * ((length + distance - 1) // distance))[-length:]
        position -= length
    return bytes(output)
