# 回归覆盖验证器错误过滤 TSD 页客体写入的问题，使用人工数值，不含游戏代码。
# Regression coverage for incorrectly filtered guest writes to the TSD page, using synthetic values without game code.
import unittest

from equiv_compare import visible_patch_writes


class WriteComparisonTests(unittest.TestCase):
    def test_guest_write_in_tsd_page_remains_visible(self):
        guest = (0x20098E5, 4, 0xD3FDD2)
        writes = [(0x7FFFF0, 8, 123), (0x7FFFF8, 8, 456), guest, (0x2000960, 8, 789)]
        self.assertEqual(visible_patch_writes(writes, [guest], 0x800000, {0x2000960}), [guest])

    def test_extra_write_in_tsd_page_is_a_difference(self):
        extra = (0x20098E5, 4, 1)
        self.assertEqual(visible_patch_writes([extra], [], 0x800000, {0x2000960}), [extra])

    def test_guest_write_to_scratch_is_not_hidden(self):
        guest = (0x7FFFF0, 8, 99)
        self.assertEqual(visible_patch_writes([guest], [guest], 0x800000, set()), [guest])

    def test_guest_write_to_registered_slot_is_not_hidden(self):
        guest = (0x2000960, 8, 99)
        self.assertEqual(visible_patch_writes([guest], [guest], 0x800000, {guest[0]}), [guest])

    def test_size_value_and_order_are_preserved(self):
        original = [(0x1000, 4, 1), (0x2000, 8, 2)]
        changed = [(0x2000, 4, 3), (0x1000, 8, 4)]
        self.assertEqual(visible_patch_writes(changed, original, 0x800000, set()), changed)
        self.assertNotEqual(changed, original)


if __name__ == "__main__":
    unittest.main()
