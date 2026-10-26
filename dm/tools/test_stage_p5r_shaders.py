# Synthetic provenance chains test cache staging without game content or GPU claims.
import json
from pathlib import Path
import struct
import tempfile
import unittest

from stage_p5r_shaders import digest, stage_bundle


class ShaderBundleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.make_inputs('cs')

    def make_inputs(self, stage):
        self.prep = self.root / stage / 'prep'
        self.diag = self.root / stage / 'diag'
        self.out = self.root / stage / 'candidate'
        for base, folders in ((self.prep, ('code', 'control')), (self.diag, ('msl', 'spirv', 'reflection-plans', 'metal-iphoneos'))):
            for folder in folders:
                (base / folder).mkdir(parents=True)
        control = bytearray(0x850)
        struct.pack_into('<6I', control, 0, 0x98761234, 1, 15, 0x120, 11, 0x848)
        struct.pack_into('<I', control, 32, 0x850)
        code = b'synthetic code!!'
        if stage != 'cs':
            code = struct.pack('<I', (1 if stage == 'vs' else 5) << 10) + bytes(0x50 - 4) + code
        self.c1 = b'constant data'
        prefix = 0 if stage == 'cs' else 0x30
        struct.pack_into('<3I', control, 0x700, len(code) + prefix, len(code) + prefix + len(self.c1), prefix)
        struct.pack_into('<I', control, 0x714, {'vs':0, 'ps':1, 'cs':5}[stage])
        struct.pack_into('<3I', control, 0x748, 1, 1, 1)
        self.key = digest(control)[:16]
        self.source = dict(key=self.key, stage=stage, control_sha256=digest(control), code_sha256=digest(code),
                           c1_sha256=digest(self.c1), c1_size=len(self.c1), code_size=len(code) + prefix, control_size=len(control), compute_workgroup=[1, 1, 1] if stage == 'cs' else None)
        self.source_report = dict(schema_version=2, source_sha256='synthetic-module', shaders=[self.source])
        self.job = dict(key=self.key, stage=stage, c1=self.c1.hex(), local=self.source['compute_workgroup'])
        (self.prep / 'control' / (self.key + '.bin')).write_bytes(control)
        (self.prep / 'code' / (self.key + '.bin')).write_bytes(code)
        msl = b'#include <metal_stdlib>\nusing namespace metal;\nkernel void main0() {}\n'
        if stage != 'cs':
            msl = (('vertex' if stage == 'vs' else 'fragment') + ' float4 main0() { return float4(0); }').encode()
        artifacts = {}
        for folder, suffix, blob in (('msl', '.metal', msl), ('spirv', '.spv', b'synthetic spirv'), ('spirv', '.res.json', b'{}')):
            name = self.key + suffix
            (self.diag / folder / name).write_bytes(blob)
            artifacts[name] = digest(blob)
        library = b'MTLB synthetic native library'
        (self.diag / 'metal-iphoneos' / (self.key + '.metallib')).write_bytes(library)
        self.plan = dict(key=self.key, stage=stage, profile='p5r', route='B', diagnostic_only=True,
            runtime_ready=False, resource_facts_verified=False, binding_coverage_complete=True,
            bindings=[], missing_descriptors=[], vertex_inputs=[], fragment_outputs=[],
            source={name: self.source[name] for name in ('control_sha256', 'code_sha256', 'c1_sha256')},
            threadgroup_size=self.source['compute_workgroup'], compute_memory_audit=dict(memory_unused_proven=True),
            msl_sha256=digest(msl), artifacts=artifacts, blockers=['Unverified game state'])
        self.plan['query_audit']=dict(entries=[])
        self.plan['texture_resource_constraints']=dict(bindings=[])
        self.row = dict(key=self.key, stage=stage, status='diagnostic_passed', reflection_plan={}, metal=[dict(
            sdk='iphoneos', target='air64-apple-ios18.0', strict_float=True, diagnostic_only=True,
            source_sha256=digest(msl), sha256=digest(library), path='ignored/report-supplied/path')])
        self.report = dict(source_sha256='synthetic-module', status='diagnostic_passed', diagnostic_only=True, shaders=[self.row])
        self.write_inputs()

    def write_inputs(self):
        for name, value in (('shader-preparation.json', self.source_report), ('diagnostic-jobs.json', [self.job])):
            (self.prep / name).write_text(json.dumps(value))
        plan_path = self.diag / 'reflection-plans' / (self.key + '.plan.json')
        plan_path.write_text(json.dumps(self.plan))
        self.row['reflection_plan']['sha256'] = digest(plan_path.read_bytes())
        (self.diag / 'diagnostic-report.json').write_text(json.dumps(self.report))

    def stage(self):
        return stage_bundle(self.prep, self.diag, self.out, '0123456789ab')

    def test_cache_mapping_c1_and_provenance_preserve_nonready_state(self):
        result = self.stage()
        self.assertEqual(result['status'], 'staged_unverified')
        self.assertEqual(result['shaders'], 1)
        cache = self.out / 'msl/b-0123456789ab'
        reflection = json.loads((cache / (self.key + '_b.json')).read_text())
        self.assertEqual(reflection['entry'], 'main0')
        self.assertEqual(reflection['c1'], self.c1.hex())
        self.assertEqual(reflection['chain'], '0123456789ab')
        self.assertTrue(reflection['diagnostic_only'])
        self.assertFalse(reflection['resource_facts_verified'])
        self.assertFalse(reflection['runtime_ready'])
        self.assertFalse(result['game_launch_enabled'])
        self.assertIn('计算\t' + self.key, (self.out / 'dm/shader_map.tsv').read_text(encoding='utf-8'))
        self.assertEqual((self.out / 'dm/c1_full.tsv').read_text(), '# chain b-0123456789ab\n' + self.key + '\n')
        for name, expected in result['shader_records'][0]['artifacts'].items():
            self.assertEqual(digest((cache / name).read_bytes()), expected)

    def test_native_library_corruption_fails_with_nonready_report(self):
        (self.diag / 'metal-iphoneos' / (self.key + '.metallib')).write_bytes(b'tamper')
        with self.assertRaisesRegex(ValueError, 'Native library digest'):
            self.stage()
        result = json.loads((self.out / 'bundle-report.json').read_text())
        self.assertEqual(result['status'], 'staging_failed')
        self.assertFalse(result['runtime_ready'])
        self.assertFalse((self.out / 'dm/shader_map.tsv').exists())

    def test_c1_source_cannot_be_changed(self):
        self.job['c1'] = b'different'.hex()
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, 'Constant segment'):
            self.stage()

    def test_compute_memory_evidence_is_required(self):
        self.plan['compute_memory_audit']['memory_unused_proven'] = False
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, 'compute memory'):
            self.stage()

    def test_guarded_candidate_is_explicit_and_does_not_claim_verification(self):
        result=stage_bundle(self.prep,self.diag,self.out,'0123456789ab',guarded=True)
        self.assertEqual(result['status'],'guarded_candidate')
        self.assertTrue(result['experimental_launch_allowed']);self.assertFalse(result['runtime_ready'])
        reflection=json.loads((self.out/'msl/b-0123456789ab'/(self.key+'_b.json')).read_text())
        self.assertFalse(reflection['diagnostic_only']);self.assertFalse(reflection['resource_facts_verified'])
        self.assertEqual(reflection['runtime_contract']['resources'],'per_binding')

    def test_graphics_code_size_includes_removed_prefix(self):
        for stage in ('vs', 'ps'):
            self.make_inputs(stage)
            result = self.stage()
            self.assertEqual(result['status'], 'staged_unverified')
            reflection = json.loads((self.out / 'msl/b-0123456789ab' / (self.key + '_b.json')).read_text())
            self.assertEqual(reflection['stage'], stage)
            self.assertEqual(reflection['msl_entry_kind'], 'vertex' if stage == 'vs' else 'fragment')

    def test_no_ready_plan_or_unverified_driver_binding(self):
        self.plan['runtime_ready'] = True
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, 'unverified P5R'):
            self.stage()

    def test_driver_banks_are_rejected_instead_of_zero_filled(self):
        self.plan['bindings'] = [dict(kind='drvcb', bank=0, arg_id=0, slot_mapping_verified=True)]
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, 'runtime binding'):
            self.stage()

    def test_all_inputs_must_cover_identical_unique_keys(self):
        self.report['shaders'] = []
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, 'coverage'):
            self.stage()
        self.assertFalse(self.out.exists())

    def test_local_only_destination_and_stale_outputs(self):
        with self.assertRaisesRegex(ValueError, 'outside repository'):
            stage_bundle(self.prep, self.diag, self.diag / 'output', '0123456789ab')
        self.stage()
        with self.assertRaises(FileExistsError):
            self.stage()

    def test_entry_stage_mismatch_even_with_matching_digests(self):
        msl = b'vertex float4 main0() { return float4(0); }'
        (self.diag / 'msl' / (self.key + '.metal')).write_bytes(msl)
        self.plan['msl_sha256'] = digest(msl)
        self.plan['artifacts'][self.key + '.metal'] = digest(msl)
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, 'entry point'):
            self.stage()


if __name__ == '__main__':
    unittest.main()
