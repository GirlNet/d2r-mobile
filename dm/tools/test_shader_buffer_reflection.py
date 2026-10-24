# 对真实出包反射函数使用合成 MSL/资源记录，核对 Ryujinx 的 Write 位与排序后的槽映射。
# Exercise the real packaging reflection function with synthetic MSL/resources, checking Ryujinx's Write bit and sorted slot mapping.
import ast
import hashlib
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch


def reflection_function():
    path = Path(__file__).resolve().parents[1] / 'gfx' / 'tools' / 'dmsh_build.py'
    tree = ast.parse(path.read_text(encoding='utf-8'))
    function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'reflect')
    namespace = {'re': re}
    exec(compile(ast.Module(body=[function], type_ignores=[]), str(path), 'exec'), namespace)
    return namespace['reflect']


class BufferReflectionTests(unittest.TestCase):
    def driver_functions(self):
        path = Path(__file__).resolve().parents[1] / 'gfx/tools/dmsh_build.py'
        tree = ast.parse(path.read_text(encoding='utf-8'))
        nodes = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in ('drv_reads', 'unfillable'))
                 or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in ('DRV_STORAGE', 'DRV_TEXTURE') for t in n.targets))]
        namespace = {'re': re}; exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec'), namespace)
        return namespace['drv_reads'], namespace['unfillable']

    def test_driver_reads_cover_all_stages_and_dynamic_indices(self):
        reads, _ = self.driver_functions()
        for prefix in ('vp', 'fp', 'cp', 'gp'):
            result = reads(f'(*spvDescriptorSet0.{prefix}_c0)._m0[33u]; (*spvDescriptorSet0.{prefix}_c2)._m0[i];')
            self.assertEqual(result['0'], dict(vec4_offsets=[0x210], dynamic=False))
            self.assertTrue(result['2']['dynamic'])

    def test_driver_ranges_follow_current_stage_and_full_vectors(self):
        _, unfillable = self.driver_functions()
        def read(bank, offset, stage):
            return unfillable({str(bank):dict(vec4_offsets=[offset], dynamic=False)}, stage)
        self.assertEqual(read(0, 0x210, 'cs'), [])
        self.assertTrue(read(0, 0x210, 'vs'))
        self.assertTrue(read(0, 0x310, 'ps'))
        self.assertEqual(read(0, 0x510, 'ps'), [])
        self.assertTrue(read(0, 0x110, 'gs'))
        self.assertEqual(read(2, 0x20, 'ps'), [])
        self.assertEqual(read(2, 0x110, 'ps'), [])
        self.assertTrue(read(2, 0x120, 'ps'))
        self.assertTrue(read(2, 0x160, 'ps'))
        self.assertEqual(read(2, 0x560, 'ps'), [])
        self.assertTrue(read(2, 0x960, 'ps'))

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

    def test_active_chain_matches_canonical_sources(self):
        root = Path(__file__).resolve().parents[1] / 'gfx'
        tree = ast.parse((root / 'tools' / 'dmsh_chain.py').read_text(encoding='utf-8'))
        files = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                     and any(isinstance(target, ast.Name) and target.id == 'FILES' for target in node.targets))
        digest = hashlib.sha256()
        for name in files:
            digest.update(name.encode() + b'\0' + (root / name).read_text(encoding='utf-8').encode() + b'\0')
        digest.update(b'debug=True reduced=True')
        self.assertIn('"' + digest.hexdigest()[:12] + '"', (root / 'nvn' / 'dmsh_chain.h').read_text(encoding='utf-8'))

    def test_cache_version_ignores_checkout_line_endings_but_tracks_source_changes(self):
        path = Path(__file__).resolve().parents[1] / 'gfx/tools/dmsh_chain.py'
        tree = ast.parse(path.read_text(encoding='utf-8'))
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in ('version', 'options')]
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, XLATE_DEBUG='1', XLATE_REDUCED='1'):
            namespace = dict(os=os, hashlib=hashlib, GFX=directory, FILES=['fixture.cs'])
            exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec'), namespace)
            fixture = Path(directory) / 'fixture.cs'
            fixture.write_bytes(b'alpha\nbeta\n')
            expected = hashlib.sha256(b'fixture.cs\0alpha\nbeta\n\0debug=True reduced=True').hexdigest()[:12]
            self.assertEqual(namespace['version'](), expected)
            fixture.write_bytes(b'alpha\r\nbeta\r\n')
            self.assertEqual(namespace['version'](), expected)
            fixture.write_bytes(b'alpha\r\nchanged\r\n')
            self.assertNotEqual(namespace['version'](), expected)


if __name__ == '__main__': unittest.main()
