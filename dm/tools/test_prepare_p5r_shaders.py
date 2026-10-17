# 用合成数据验证 P5R 控制段/代码布局及坏输入拒绝，不依赖游戏文件。
# Validate P5R control/code layout and malformed-input rejection using synthetic data, without game files.
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest

from prepare_p5r_shaders import CONTROL_SIZE, HEADER_FIELDS, compute_workgroup, scan_segment, write_outputs


def shader(stage=1, constants=0):
    control = bytearray(CONTROL_SIZE)
    struct.pack_into('<I', control, 0, 0x98761234)
    for off, value in HEADER_FIELDS.items():
        struct.pack_into('<I', control, off, value)
    code = bytearray(0x100)
    if stage != 5:
        struct.pack_into('<I', code, 0, 0x12345678)
        struct.pack_into('<I', code, 0x30, (1 if stage == 0 else 5) << 10)
    else:
        struct.pack_into('<3I', control, 0x748, 4, 2, 1)
    for off, value in [(0x700, len(code)), (0x704, len(code) + constants),
                       (0x708, 0 if stage == 5 else 0x30), (0x714, stage)]:
        struct.pack_into('<I', control, off, value)
    return control + code + bytearray([0xa5] * constants)


class ShaderPreparationTests(unittest.TestCase):
    def test_graphics_stage_code_and_constants(self):
        for stage, name in [(0, 'vs'), (1, 'ps')]:
            data = shader(stage, 256)
            rows, rejected = scan_segment(data, 0x2000000)
            self.assertFalse(rejected)
            r = rows[0]
            self.assertEqual((r['control_address'], r['code_address']), (0x2000000, 0x2000850))
            self.assertEqual((r['stage'], len(r['code']), r['c1_size']), (name, 0xd0, 256))
            self.assertEqual(r['key'], hashlib.sha256(data[:CONTROL_SIZE]).hexdigest()[:16])
            self.assertEqual(r['c1'], bytes([0xa5] * 256))

    def test_compute_has_no_graphics_prefix(self):
        rows, _ = scan_segment(shader(5))
        self.assertEqual((rows[0]['stage'], len(rows[0]['code'])), ('cs', 0x100))
        self.assertEqual(rows[0]['compute_workgroup'], [4, 2, 1])

    def test_invalid_compute_workgroups_rejected(self):
        for group in [(0, 1, 1), (1, 0, 1), (1, 1, 0), (65536, 1, 1), (32, 64, 1)]:
            data = shader(5); struct.pack_into('<3I', data, 0x748, *group)
            with self.assertRaises(ValueError): scan_segment(data)
        self.assertEqual(compute_workgroup(shader(5)[:CONTROL_SIZE]), [4, 2, 1])

    def test_compute_job_keeps_hashed_control_and_dimensions(self):
        rows, rejected = scan_segment(shader(5))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'out'
            manifest = write_outputs(output, dict(file_sha256='test', build_id='test'), rows, rejected)
            self.assertEqual(manifest['schema_version'], 2)
            self.assertEqual((output / 'control' / (rows[0]['key'] + '.bin')).read_bytes(), shader(5)[:CONTROL_SIZE])

    def test_unknown_layout_is_rejected(self):
        data = shader(); struct.pack_into('<I', data, 16, 12)
        self.assertEqual(scan_segment(data), ([], [0]))
        self.assertEqual(scan_segment(bytes.fromhex('34127698')), ([], [0]))

    def test_truncated_control_or_code(self):
        for size in (0x24, CONTROL_SIZE - 1, CONTROL_SIZE, CONTROL_SIZE + 255):
            with self.assertRaises(ValueError):
                scan_segment(shader()[:size])

    def test_invalid_sizes_and_stage(self):
        for off, value in [(0x700, 0), (0x700, 0x300), (0x704, 0xffffffff), (0x714, 9), (0x708, 0)]:
            data = shader(); struct.pack_into('<I', data, off, value)
            with self.assertRaises(ValueError): scan_segment(data)

    def test_sph_stage_disagrees_with_control(self):
        data = shader(); struct.pack_into('<I', data, CONTROL_SIZE + 0x30, 1 << 10)
        with self.assertRaises(ValueError): scan_segment(data)

    def test_multiple_shaders_and_magic_inside_constants(self):
        a = shader(0, 256); a[CONTROL_SIZE + 0x104:CONTROL_SIZE + 0x108] = bytes.fromhex('34127698')
        rows, rejected = scan_segment(b'pad' + a + shader(5), 10)
        self.assertEqual([r['stage'] for r in rows], ['vs', 'cs'])
        self.assertEqual(rows[1]['control_address'], 13 + len(a))
        self.assertEqual(rejected, [])

    def test_existing_output_not_overwritten(self):
        rows, rejected = scan_segment(shader())
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'out'
            m = write_outputs(output, dict(file_sha256='test', build_id='test'), rows, rejected)
            self.assertFalse(m['translation_ready'])
            self.assertFalse(m['graphics_verified'])
            marker = output / 'marker'; marker.write_text('keep')
            with self.assertRaises(FileExistsError):
                write_outputs(output, dict(file_sha256='test', build_id='test'), rows, rejected)
            self.assertEqual(marker.read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
