# 对真实出包反射函数使用合成 MSL/资源记录，核对 Ryujinx 的 Write 位与排序后的槽映射。
# Exercise the real packaging reflection function with synthetic MSL/resources, checking Ryujinx's Write bit and sorted slot mapping.
import ast
import hashlib
from pathlib import Path
import re
import unittest


def reflection_function():
    path = Path(__file__).resolve().parents[1] / 'gfx' / 'tools' / 'dmsh_build.py'
    tree = ast.parse(path.read_text(encoding='utf-8'))
    function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'reflect')
    namespace = {'re': re}
    exec(compile(ast.Module(body=[function], type_ignores=[]), str(path), 'exec'), namespace)
    return namespace['reflect']


class BufferReflectionTests(unittest.TestCase):
    def test_write_bit_and_sorted_metadata_select_the_correct_slot(self):
        msl = 'struct spvDescriptorSetBuffer0 {\n device _21* cp_s0 [[id(0)]];\n device _21* cp_s1 [[id(1)]];\n};'
        resource = dict(sbufs=[dict(binding=3, cb_slot=0, cb_offset=196, flags=1),
                              dict(binding=1, cb_slot=0, cb_offset=204, flags=0)])
        result = reflection_function()('synthetic', 'cs', msl, resource)
        self.assertEqual([(b['reg'], b['rw']) for b in result], [(2, False), (0, True)])

    def test_non_write_flags_and_unknown_banks_do_not_create_a_slot(self):
        msl = 'struct spvDescriptorSetBuffer0 {\n device _21* cp_s0 [[id(0)]];\n};'
        result = reflection_function()('synthetic', 'cs', msl,
                                       dict(sbufs=[dict(binding=1, cb_slot=7, cb_offset=196, flags=2)]))
        self.assertIsNone(result[0]['reg'])
        self.assertFalse(result[0]['rw'])

    def test_checked_in_chain_matches_canonical_sources(self):
        root = Path(__file__).resolve().parents[1] / 'gfx'
        tree = ast.parse((root / 'tools' / 'dmsh_chain.py').read_text(encoding='utf-8'))
        files = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                     and any(isinstance(target, ast.Name) and target.id == 'FILES' for target in node.targets))
        digest = hashlib.sha256()
        for name in files:
            digest.update(name.encode() + b'\0' + (root / name).read_text(encoding='utf-8').encode() + b'\0')
        digest.update(b'debug=True reduced=True')
        self.assertIn('"' + digest.hexdigest()[:12] + '"', (root / 'nvn' / 'dmsh_chain.h').read_text(encoding='utf-8'))


if __name__ == '__main__': unittest.main()
