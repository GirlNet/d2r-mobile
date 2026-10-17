# 合成 Maxwell TXQ 核对实际查询、回答来源及组合句柄缺省，避免用生成的纹理类型自证。
# Synthetic Maxwell TXQ checks actual queries, answer provenance and combined-handle defaults without using generated types as evidence.
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

from diagnose_p5r_shaders import audit_queries, query_requirements
from test_maxwell_memory_audit import encoding


@unittest.skipUnless(os.environ.get('P5R_TRANSLATOR'), 'Set P5R_TRANSLATOR to test the native translator')
class NativeQueryAuditTests(unittest.TestCase):
    def translate(self, handle=None, **facts):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code = root / 'code.bin'
            instructions = [0]
            if handle is not None:
                instructions.append(encoding('Txq') | (7 << 16) | (255 << 8) | (1 << 22) | (1 << 31) | (handle << 36))
            instructions.append(0xe30000000007000f)
            code.write_bytes(struct.pack('<' + 'Q' * len(instructions), *instructions) + bytes(64))
            job = dict(key='synthetic', stage='cs', code=str(code), local=[32, 1, 1], debug=True, reduced=False, **facts)
            jobs = root / 'jobs.json'; jobs.write_text(json.dumps([job]))
            subprocess.run([os.environ['P5R_TRANSLATOR'], str(jobs), str(root)], check=True, capture_output=True)
            return audit_queries(json.loads((root / 'synthetic.res.json').read_text()))

    def test_exit_has_control_dimensions_but_no_texture_query(self):
        audit = self.translate()
        names = audit['calls_by_query']
        self.assertNotIn('sampler_type', names)
        self.assertTrue(all(names.get('compute_local_size_' + a, 0) for a in 'xyz'))
        self.assertFalse(audit['resource_facts_verified'])

    def test_combined_slot_is_not_answered_with_a_separate_slot_fact(self):
        audit = self.translate(8, tex={'0': 'cube'})
        types = [q for q in audit['entries'] if q['query'] == 'sampler_type']
        self.assertEqual(types, [dict(query='sampler_type', value='Texture2D', source='missing_default', handle=8, cbuf_slot=-1)])

    def test_explicit_and_invalid_job_facts_have_distinct_sources(self):
        for facts, source, value in [({'tex': {'0': 'cube'}}, 'job_tex', 'TextureCube'),
                                     ({'img': {'0': {'type': '3d'}}}, 'job_img', 'Texture3D'),
                                     ({'tex': {'0': 'bad'}}, 'invalid_default', 'Texture2D')]:
            audit = self.translate(0x168 // 4, **facts)
            types = [q for q in audit['entries'] if q['query'] == 'sampler_type']
            self.assertEqual(len(types), 1)
            self.assertEqual((types[0]['source'], types[0]['value']), (source, value))
            self.assertFalse(audit['resource_facts_verified'])


class QueryRequirementTests(unittest.TestCase):
    def test_groups_calls_without_merging_handle_domains_or_job_answers(self):
        row = dict(query='sampler_type', value='Texture2D', source='missing_default', handle=8, cbuf_slot=-1)
        shaders = [dict(key='a', query_audit=dict(entries=[row, row, dict(row, cbuf_slot=2)])),
                   dict(key='b', query_audit=dict(entries=[row, dict(row, source='job_tex')]))]
        groups = query_requirements(shaders)
        self.assertEqual(len(groups), 2)
        self.assertEqual(groups[0]['calls'], 3)
        self.assertEqual(groups[0]['shaders'], ['a', 'b'])
        self.assertEqual(groups[1]['calls'], 1)


if __name__ == '__main__': unittest.main()
