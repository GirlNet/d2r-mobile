# 合成作业验证诊断阶段失败、来源完整性与输出隔离；苹果机器另编译合成 MSL。
# Synthetic jobs validate stage failures, provenance integrity and output isolation; Apple hosts also compile synthetic MSL.
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

from diagnose_p5r_shaders import audit_resources, compile_metal, diagnose, load_jobs
from prepare_p5r_shaders import scan_segment, write_outputs
from test_prepare_p5r_shaders import shader


MSL = '''#include <metal_stdlib>
using namespace metal;
kernel void synthetic(device uint* values [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    values[id] = id;
}
'''


def resources(job, handle=8):
    return dict(key=job['key'], stage=job['stage'], cbufs=[], sbufs=[], images=[], notes=[],
                textures=[dict(binding=1, handle=handle, cbuf_slot=-1, array=1, type=3, format='Unknown')])


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.preparation = self.root / 'preparation'
        rows, rejected = scan_segment(shader(constants=256))
        write_outputs(self.preparation, dict(file_sha256='test', build_id='test'), rows, rejected)
        self.jobs = json.loads((self.preparation / 'diagnostic-jobs.json').read_text(encoding='utf-8'))
        self.tool = self.root / 'tool'; self.tool.write_bytes(b'synthetic tool')

    def runner(self, command, log, timeout=120):
        command = [str(c) for c in command]
        log.write_text('', encoding='utf-8')
        if command[-1] == '--source-sha':
            log.write_text('0123456789abcdef\n', encoding='utf-8')
        elif len(command) == 3:
            for job in json.loads(Path(command[1]).read_text(encoding='utf-8')):
                output = Path(command[2])
                (output / (job['key'] + '.spv')).write_bytes(b'synthetic SPIR-V')
                (output / (job['key'] + '.res.json')).write_text(json.dumps(resources(job)), encoding='utf-8')
        elif '--output' in command:
            Path(command[-1]).write_text(MSL, encoding='utf-8')
        elif '-o' in command:
            Path(command[-1]).write_bytes(b'synthetic compiled output')

    def run_diagnostic(self, runner=None, output=None, sdks=()):
        return diagnose(self.preparation, output or self.root / 'out', self.tool, self.tool, self.tool,
                        sdks=sdks, runner=runner or self.runner)

    def test_full_diagnostic_keeps_false_runtime_flags(self):
        report = self.run_diagnostic(sdks=('macosx', 'iphoneos'))
        self.assertEqual(report['status'], 'diagnostic_passed')
        self.assertEqual(report['summary']['passed'], 1)
        self.assertEqual(report['summary']['shaders_outside_d2r_texture_layout'], 1)
        self.assertFalse(report['resource_bindings_verified'])
        self.assertFalse(report['runnable_verified'])
        self.assertEqual(report['shaders'][0]['audit']['handles'][0]['texture_byte_offset'], 32)
        self.assertEqual(report['shaders'][0]['audit']['handles'][0]['handle_source']['texture'], dict(kind='tex_combined', reg=0))
        self.assertEqual(report['summary']['shaders_with_unresolved_handles'], 0)
        self.assertEqual([x['sdk'] for x in report['shaders'][0]['metal']], ['macosx', 'iphoneos'])
        self.assertEqual(report['tools']['translator']['source_sha16'], '0123456789abcdef')
        self.assertFalse(any('_b.' in p.name for p in (self.root / 'out').rglob('*')))

    def test_extraction_is_not_modified(self):
        before = {p: p.read_bytes() for p in self.preparation.rglob('*') if p.is_file()}
        self.run_diagnostic()
        self.assertEqual(before, {p: p.read_bytes() for p in self.preparation.rglob('*') if p.is_file()})

    def test_tampered_code_constants_or_stage_rejected_before_output(self):
        path = self.preparation / 'diagnostic-jobs.json'
        original = path.read_text(encoding='utf-8')
        for field, value in [('c1', '00' * 256), ('stage', 'cs'), ('resource_facts_verified', True), ('debug', False)]:
            jobs = json.loads(original); jobs[0][field] = value
            path.write_text(json.dumps(jobs), encoding='utf-8')
            with self.assertRaises(ValueError): self.run_diagnostic()
            self.assertFalse((self.root / 'out').exists())
        path.write_text(original, encoding='utf-8')
        Path(self.jobs[0]['code']).write_bytes(b'tampered')
        with self.assertRaises(ValueError): self.run_diagnostic()

    def test_older_extraction_missing_constant_digest_rejected(self):
        path = self.preparation / 'shader-preparation.json'
        manifest = json.loads(path.read_text(encoding='utf-8')); manifest['shaders'][0].pop('c1_sha256')
        path.write_text(json.dumps(manifest), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'rerun'): load_jobs(self.preparation)

    def test_code_path_escape_and_unknown_keys_rejected(self):
        path = self.preparation / 'diagnostic-jobs.json'
        for field, value in [('code', str(self.tool)), ('key', '../escape')]:
            jobs = [dict(self.jobs[0], **{field: value})]
            path.write_text(json.dumps(jobs), encoding='utf-8')
            with self.assertRaises(ValueError): load_jobs(self.preparation)

    def test_output_is_new_and_outside_sources_and_repo(self):
        for path in (self.preparation / 'out', self.root, Path(__file__).resolve().parents[2] / 'diagnostic-test-out'):
            with self.assertRaises(ValueError): self.run_diagnostic(output=path)
        output = self.root / 'out'; output.mkdir(); marker = output / 'keep'; marker.write_text('keep')
        with self.assertRaises(FileExistsError): self.run_diagnostic(output=output)
        self.assertEqual(marker.read_text(), 'keep')

    def test_validation_failure_stops_msl_and_preserves_report(self):
        def runner(command, log, timeout=120):
            if '--target-env' in command: raise RuntimeError('synthetic validation failure')
            self.runner(command, log, timeout)
        report = self.run_diagnostic(runner)
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['shaders'][0]['completed'], ['translated'])
        self.assertEqual(list((self.root / 'out' / 'msl').iterdir()), [])
        saved = json.loads((self.root / 'out' / 'diagnostic-report.json').read_text(encoding='utf-8'))
        self.assertEqual(saved['status'], 'failed')

    def test_partial_translation_failure_is_not_success(self):
        def runner(command, log, timeout=120):
            self.runner(command, log, timeout)
            if len(command) == 3: raise RuntimeError('partial translation failure')
        report = self.run_diagnostic(runner)
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['summary']['passed'], 1)
        self.assertTrue(report['errors'])

    def test_metal_failure_preserves_completed_stages(self):
        def runner(command, log, timeout=120):
            if 'metallib' in command: raise RuntimeError('synthetic link failure')
            self.runner(command, log, timeout)
        report = self.run_diagnostic(runner, sdks=('iphoneos',))
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['shaders'][0]['completed'], ['translated', 'spirv_validated', 'msl_generated'])

    def test_resource_identity_and_packed_handle_validation(self):
        job = self.jobs[0]
        resource = resources(job); resource['key'] = 'bad'
        with self.assertRaises(ValueError): audit_resources(job, resource)
        with self.assertRaises(ValueError): audit_resources(job, resources(job, -1))
        audit = audit_resources(dict(job, stage='cs'), resources(dict(job, stage='cs'), 0x168 // 4))
        self.assertTrue(audit['handles'][0]['d2r_texture_range_match'])
        self.assertFalse(audit['compute_configuration_verified'])
        self.assertFalse(audit['resource_bindings_verified'])
        array_resource = resources(job); array_resource['textures'][0]['array'] = 2
        self.assertIsNone(audit_resources(job, array_resource)['handles'][0]['handle_source'])


@unittest.skipUnless(sys.platform == 'darwin', 'Apple Metal tools require macOS')
class NativeMetalTests(unittest.TestCase):
    def test_synthetic_msl_compiles_for_mac_and_ios(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); msl = root / 'synthetic.metal'; msl.write_text(MSL, encoding='utf-8')
            for sdk in ('macosx', 'iphoneos'):
                result = compile_metal(msl, root / sdk, sdk)
                self.assertEqual(result['sha256'], hashlib.sha256(Path(result['path']).read_bytes()).hexdigest())
                self.assertFalse(result['gpu_output_verified'])


if __name__ == '__main__':
    unittest.main()
