"""Read bounded, plain @UTF CPK indices and individual local entries.

Format reference: CriPakTools/CPK.cs (https://github.com/esperknight/CriPakTools).
Unsupported/encrypted indices fail explicitly. Entry names are metadata only;
they are never used as filesystem output paths.
"""
import hashlib
from pathlib import Path
import struct
from crilayla import decompress


def utf(blob):
    if len(blob) < 32 or blob[:4] != b'@UTF':
        raise ValueError('Unsupported or truncated CPK UTF index')
    size, rows, strings, data, name, columns, width, count = struct.unpack_from('>5IHHI', blob, 4)
    rows += 8; strings += 8; data += 8; end = size + 8
    if (not 32 <= rows <= strings <= data <= end <= len(blob)
            or count * width > strings - rows or count > 1000000 or columns > 1024):
        raise ValueError('CPK UTF bounds')

    def string(offset):
        start = strings + offset
        if not strings <= start < data:
            raise ValueError('CPK UTF string offset')
        try:
            stop = blob.index(0, start, data)
            return blob[start:stop].decode('utf-8')
        except (ValueError, UnicodeDecodeError) as error:
            raise ValueError('Invalid CPK UTF string') from error

    def value(kind, pos, limit):
        formats = 'BbHhIiQqfd'
        size = struct.calcsize('>' + formats[kind]) if kind < len(formats) else 4 if kind == 10 else 8 if kind == 11 else 0
        if not size or pos + size > limit:
            raise ValueError('CPK UTF value bounds/type')
        if kind < len(formats):
            result = struct.unpack_from('>' + formats[kind], blob, pos)[0]
        else:
            offset = struct.unpack_from('>I', blob, pos)[0]
            if kind == 10:
                result = string(offset)
            else:
                length = struct.unpack_from('>I', blob, pos + 4)[0]
                if offset > end - data or length > end - data - offset:
                    raise ValueError('CPK UTF data bounds')
                result = dict(offset=data + offset, size=length)
        return result, pos + size

    cols, pos, names = [], 32, set()
    for _ in range(columns):
        if pos + 5 > rows:
            raise ValueError('CPK UTF column bounds')
        flags, offset = struct.unpack_from('>BI', blob, pos); pos += 5
        column = string(offset)
        if column in names:
            raise ValueError('Duplicate CPK UTF column')
        names.add(column)
        storage, kind = flags & 0xf0, flags & 15
        default = 0 if storage == 0x10 else None
        if storage == 0x30:
            default, pos = value(kind, pos, rows)
        elif storage not in (0, 0x10, 0x50):
            raise ValueError('Unsupported CPK UTF storage')
        cols.append((column, storage, kind, default))
    result = []
    for row in range(count):
        pos, record, limit = rows + row * width, {}, rows + (row + 1) * width
        for column, storage, kind, default in cols:
            if storage == 0x50:
                record[column], pos = value(kind, pos, limit)
            else:
                record[column] = default
        result.append(record)
    return result


def packet(file, offset, magic):
    file.seek(offset); header = file.read(16)
    if len(header) != 16 or header[:4] != magic:
        raise ValueError('CPK packet identity/range')
    size = struct.unpack_from('<Q', header, 8)[0]
    if size > 64 * 1024 * 1024:
        raise ValueError('CPK index exceeds limit')
    data = file.read(size)
    if len(data) != size:
        raise ValueError('Truncated CPK index')
    return utf(data), hashlib.sha256(header + data).hexdigest()


def inventory(path):
    path = Path(path); size = path.stat().st_size
    with path.open('rb') as file:
        headers, header_sha = packet(file, 0, b'CPK ')
        if len(headers) != 1:
            raise ValueError('Expected one CPK header row')
        header = headers[0]
        if any(type(header.get(k)) is not int or not 0 <= header[k] < size for k in ('TocOffset', 'ContentOffset')):
            raise ValueError('Invalid CPK TOC/content offset')
        entries, toc_sha = packet(file, header['TocOffset'], b'TOC ')
    base = min(header['TocOffset'], header['ContentOffset'])
    for row in entries:
        if not isinstance(row.get('FileName'), str):
            raise ValueError('Invalid CPK entry name')
        if any(type(row.get(k)) is not int or row[k] < 0 for k in ('FileSize', 'ExtractSize', 'FileOffset')):
            raise ValueError('Invalid CPK entry range')
        offset = base + row['FileOffset']
        if offset > size or row['FileSize'] > size - offset:
            raise ValueError('CPK entry outside archive')
        row['absolute_offset'] = offset
    return dict(path=str(path.resolve()), size=size, header_sha256=header_sha,
                toc_sha256=toc_sha, files=entries)


def read_entry(file, entry, maximum=256 * 1024 * 1024):
    if entry['FileSize'] > maximum or entry['ExtractSize'] > maximum:
        raise ValueError('CPK entry exceeds decompression limit')
    file.seek(entry['absolute_offset']); stored = file.read(entry['FileSize'])
    if len(stored) != entry['FileSize']:
        raise ValueError('Truncated CPK entry')
    if stored.startswith(b'CRILAYLA'):
        decoded = decompress(stored, entry['ExtractSize'], maximum)
    elif len(stored) == entry['ExtractSize']:
        decoded = stored
    else:
        raise ValueError('Unsupported CPK entry compression')
    return decoded, hashlib.sha256(stored).hexdigest()
