# 合成描述符覆盖组合/分离句柄及未知模式，避免按 D2R 表误解码 P5R。
# Synthetic descriptors cover combined/separate handles and unknown modes, avoiding D2R-only decoding of P5R.
import unittest
from nvn_handle_layout import decode_handle


class HandleLayoutTests(unittest.TestCase):
    def test_combined_slots_and_same_handle_sampler(self):
        for index in (0, 1, 31):
            result = decode_handle((0x20 + index * 8) // 4)
            self.assertEqual(result, dict(texture=dict(kind='tex_combined', reg=index),
                                          sampler=dict(kind='samp_combined', reg=index)))

    def test_separate_texture_retains_existing_slot(self):
        for index in (0, 127):
            result = decode_handle((0x168 + index * 8) // 4)
            self.assertEqual(result, dict(texture=dict(kind='tex', reg=index), sampler=dict(kind='samp_tex', reg=index)))

    def test_explicit_separate_sampler(self):
        handle = 0x10000000 | (((0x568 + 8 * 127) // 4) << 14) | (0x20 // 4)
        result = decode_handle(handle, 2 | (3 << 16))
        self.assertEqual(result['texture'], dict(kind='tex_combined', reg=0))
        self.assertEqual(result['sampler'], dict(kind='samp', reg=127))

    def test_reserved_unaligned_and_outside_offsets_unresolved(self):
        for offset in (0, 0x1c, 0x24, 0x120, 0x160, 0x164, 0x16c, 0x568):
            self.assertIsNone(decode_handle(offset // 4))

    def test_unknown_bank_and_sampler_modes_unresolved(self):
        for banks in (0, 1, 3, 0x30003): self.assertIsNone(decode_handle(8, banks))
        for mode in (2, 3, 4, 7): self.assertIsNone(decode_handle((mode << 28) | 8))
        self.assertIsNone(decode_handle(0x10000008))

    def test_malformed_packed_fields_rejected(self):
        for handle in (-1, 0x80000000, '8', True):
            with self.assertRaises(ValueError): decode_handle(handle)
        with self.assertRaises(ValueError): decode_handle(8, -2)


if __name__ == '__main__': unittest.main()
