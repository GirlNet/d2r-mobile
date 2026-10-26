import hashlib
import io
from pathlib import Path
import struct
import tempfile
import unittest

from cpk_reader import inventory, read_entry, utf
from prepare_p5r_shaders import extract_archives, scan_segment, unique_records, write_outputs
from test_crilayla import literals, stream
from test_prepare_p5r_shaders import shader


def table(columns, records):
    strings = bytearray(b'table\0')
    def string(value):
        offset = len(strings); strings.extend(value.encode() + b'\0'); return offset
    descriptors = b''.join(struct.pack('>BI', 0x50 | kind, string(name)) for name, kind in columns)
    rows = bytearray()
    formats = {4: '>I', 6: '>Q', 10: '>I'}
    for record in records:
        for name, kind in columns:
            value = string(record[name]) if kind == 10 else record[name]
            rows.extend(struct.pack(formats[kind], value))
    width = sum(struct.calcsize(formats[k]) for _, k in columns)
    rows_start = 32 + len(descriptors); strings_start = rows_start + len(rows)
    end = strings_start + len(strings)
    header = struct.pack('>4s5IHHI', b'@UTF', end - 8, rows_start - 8,
                         strings_start - 8, end - 8, 0, len(columns), width, len(records))
    return header + descriptors + rows + strings


def packet(magic, data):
    return magic + bytes(4) + struct.pack('<Q', len(data)) + data


def archive(path, decoded, compressed=False, name='GFDNXHHPRESET_INIT.GSC'):
    stored = stream(literals(decoded[256:]), len(decoded) - 256, decoded[:256]) if compressed else decoded
    header = table([('TocOffset', 6), ('ContentOffset', 6)], [dict(TocOffset=512, ContentOffset=2048)])
    toc = table([('FileName', 10), ('FileOffset', 6), ('FileSize', 4), ('ExtractSize', 4)],
                [dict(FileName=name, FileOffset=1536, FileSize=len(stored), ExtractSize=len(decoded))])
    data = packet(b'CPK ', header); data += bytes(512 - len(data))
    data += packet(b'TOC ', toc); data += bytes(2048 - len(data))
    path.write_bytes(data + stored)


class CpkReaderTests(unittest.TestCase):
    def test_plain_and_compressed_entries_and_provenance(self):
        data = bytes(shader())
        for compressed in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'test.cpk'; archive(path, data, compressed)
                index = inventory(path)
                with path.open('rb') as file:
                    decoded, stored_sha = read_entry(file, index['files'][0])
                self.assertEqual(decoded, data)
                self.assertEqual(stored_sha, hashlib.sha256(path.read_bytes()[2048:]).hexdigest())
                rows, sources = extract_archives([path])
                self.assertEqual(len(rows), 1)
                self.assertEqual(sources[0]['entries'][0]['decoded_sha256'], hashlib.sha256(data).hexdigest())
                merged = unique_records(rows + rows)
                self.assertEqual(len(merged), 1)
                self.assertEqual(len(merged[0]['origins']), 2)
                manifest = write_outputs(Path(directory) / 'out', dict(file_sha256='test', build_id='test', shader_archives=sources), merged, [])
                self.assertEqual(manifest['source_archives'], sources)
                self.assertFalse(manifest['runnable_verified'])

    def test_entry_names_never_become_output_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.cpk'
            archive(path, bytes(shader()), name='../GFDNXEVIL.GSC')
            self.assertEqual(extract_archives([path])[0], [])
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ['test.cpk'])

    def test_invalid_utf_and_archive_bounds(self):
        valid = table([('a', 4)], [dict(a=7)])
        self.assertEqual(utf(valid), [dict(a=7)])
        for length in (0, 4, 31, len(valid) - 1):
            with self.assertRaises(ValueError): utf(valid[:length])
        for offset, value in ((8, 0), (12, 0xffffffff), (24, 0xffff0004), (28, 100)):
            bad = bytearray(valid); struct.pack_into('>I', bad, offset, value)
            with self.assertRaises(ValueError): utf(bad)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.cpk'; archive(path, bytes(shader()))
            path.write_bytes(path.read_bytes()[:-1])
            with self.assertRaises(ValueError): inventory(path)

    def test_entry_limits_and_unknown_compression(self):
        for entry, content in ((dict(FileSize=4, ExtractSize=5, absolute_offset=0), b'data'),
                               (dict(FileSize=5, ExtractSize=5, absolute_offset=0), b'data')):
            with self.assertRaises(ValueError): read_entry(io.BytesIO(content), entry)
        with self.assertRaises(ValueError):
            read_entry(io.BytesIO(b'abc'), dict(FileSize=3, ExtractSize=3, absolute_offset=0), maximum=2)

    def test_control_key_conflicts_rejected(self):
        row = scan_segment(shader())[0][0]
        for field in ('control', 'code', 'c1', 'stage'):
            other = dict(row); other[field] = b'changed'
            with self.assertRaises(ValueError): unique_records([row, other])


if __name__ == '__main__': unittest.main()
