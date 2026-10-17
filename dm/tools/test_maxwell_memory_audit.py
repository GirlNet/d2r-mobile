# 合成 Maxwell 指令验证局部/共享内存审计与未知指令拒绝；编码来自仓内 InstTable。
# Synthetic Maxwell instructions test local/shared memory auditing and unknown-instruction rejection; encodings come from the vendored InstTable.
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import unittest

from maxwell_memory_audit import AMBIGUOUS, LOCAL, ROOT, SHARED, audit_compute_memory, instruction_table


def encoding(name):
    pattern = re.search(r'Add\("([01x]{64})", InstName\.' + name + r'\b', (ROOT / 'InstTable.cs').read_text()).group(1)
    return int(pattern.replace('x', '0'), 2)


class ComputeMemoryAuditTests(unittest.TestCase):
    def test_all_memory_families_block_unused_proof(self):
        for name in LOCAL | SHARED | AMBIGUOUS:
            code = struct.pack('<QQ', 0, encoding(name))
            result = audit_compute_memory(code, 16)
            self.assertFalse(result['memory_unused_proven'])
            category = 'local_memory_ops' if name in LOCAL else 'shared_memory_ops' if name in SHARED else 'ambiguous_memory_ops'
            self.assertIn(name, result[category])

    def test_schedule_words_and_padding_are_not_decoded_as_instructions(self):
        code = struct.pack('<QQQQQQ', encoding('Ldl'), encoding('Nop'), encoding('Exit'), encoding('Bra'), encoding('Sts'), encoding('Exit')) + bytes(32)
        result = audit_compute_memory(code, 48)
        self.assertTrue(result['memory_unused_proven'])
        self.assertEqual(result['instructions'], 4)

    def test_unknown_or_unreachable_memory_is_not_ignored(self):
        for word in (0, encoding('Ldl')):
            result = audit_compute_memory(struct.pack('<QQQ', 0, encoding('Exit'), word), 24)
            self.assertFalse(result['memory_unused_proven'])

    def test_invalid_extents_are_rejected(self):
        for extent in (None, True, 0, 8, 17, 40, -16):
            with self.assertRaises(ValueError): audit_compute_memory(bytes(32), extent)
        with self.assertRaises(ValueError): audit_compute_memory(bytes(17), 16)

    def test_specificity_matches_vendored_decoder_and_memory_features(self):
        table, _ = instruction_table()
        self.assertEqual(table[encoding('AtomsCas') >> 50], 'AtomsCas')
        source = (ROOT / 'Decoder.cs').read_text()
        for feature, expected in [('LocalMemory', LOCAL), ('SharedMemory', SHARED)]:
            block = re.search(r'((?:\s*case InstName\.\w+:)+)\s*context.SetUsedFeature\(FeatureFlags\.' + feature + r'\)', source).group(1)
            self.assertEqual(set(re.findall(r'InstName\.(\w+)', block)), expected)

    @unittest.skipUnless(os.environ.get('P5R_TRANSLATOR'), 'Set P5R_TRANSLATOR to test the native translator')
    def test_native_translator_reports_decoded_extent_for_synthetic_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); binary = root / 'code.bin'; jobs = root / 'jobs.json'
            binary.write_bytes(struct.pack('<QQ', 0, 0xe30000000007000f) + bytes(48))
            jobs.write_text(json.dumps([dict(key='synthetic', stage='cs', code=str(binary), local=[32,1,1], debug=True, reduced=False)]))
            subprocess.run([os.environ['P5R_TRANSLATOR'], str(jobs), str(root)], check=True, capture_output=True)
            resource = json.loads((root / 'synthetic.res.json').read_text())
            self.assertEqual(resource['decoded_size'], 16)
            self.assertTrue(audit_compute_memory(binary.read_bytes(), resource['decoded_size'])['memory_unused_proven'])


if __name__ == '__main__': unittest.main()
