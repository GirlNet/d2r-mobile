# 合成作业验证诊断阶段失败、来源完整性与输出隔离；苹果机器另编译合成 MSL。
# Synthetic jobs validate stage failures, provenance integrity and output isolation; Apple hosts also compile synthetic MSL.
import hashlib
import json
from pathlib import Path
import sys
import struct
import tempfile
import unittest
from unittest.mock import patch

from diagnose_p5r_shaders import audit_queries, audit_resources, compile_metal, diagnose, load_jobs, save_json, spirv_compute_workgroup
from prepare_p5r_shaders import scan_segment, write_outputs
from test_prepare_p5r_shaders import shader


MSL = '''#include <metal_stdlib>
using namespace metal;
kernel void synthetic(device uint* values [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    values[id] = id;
}
'''


def compute_spirv(group=(4, 2, 1)):
    words = [0x07230203, 0x10000, 0, 2, 0, (5 << 16) | 15, 5, 1, 0x6e69616d, 0,
             (6 << 16) | 16, 1, 17, *group]
    return struct.pack('<' + 'I' * len(words), *words)


def resources(job, handle=8):
    return dict(key=job['key'], stage=job['stage'], decoded_size=16 if job['stage'] == 'cs' else 0x60, cbufs=[], sbufs=[], images=[], notes=[],
                query_audit_schema=1, query_audit=[dict(query='sampler_type', handle=handle, cbuf_slot=-1,
                    value='Texture2D', source='missing_default')],
                textures=[dict(binding=1, handle=handle, cbuf_slot=-1, array=1, type=3, format='Unknown')])


class DiagnosticTests(unittest.TestCase):
    def test_checkpoint_retries_transient_sharing_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'report.json';path.write_text('{"old":true}')
            replace=Path.replace;attempts=[]
            def locked(source,destination):
                attempts.append(1)
                if len(attempts)<3:
                    self.assertEqual(json.loads(path.read_text()),dict(old=True))
                    raise PermissionError('synthetic Windows sharing lock')
                return replace(source,destination)
            with patch.object(Path,'replace',locked), patch('diagnose_p5r_shaders.time.sleep'):
                save_json(path,dict(new=True))
            self.assertEqual(len(attempts),3)
            self.assertEqual(json.loads(path.read_text()),dict(new=True))
            with patch.object(Path,'replace',side_effect=PermissionError('permanent lock')), patch('diagnose_p5r_shaders.time.sleep'):
                with self.assertRaises(PermissionError):save_json(path,dict(not_saved=True))
            self.assertEqual(json.loads(path.read_text()),dict(new=True))

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
                (output / (job['key'] + '.spv')).write_bytes(compute_spirv(job['local']) if job['stage'] == 'cs' else b'synthetic SPIR-V')
                (output / (job['key'] + '.res.json')).write_text(json.dumps(resources(job)), encoding='utf-8')
        elif '--output' in command:
            stage = next(j['stage'] for j in json.loads((Path(command[-1]).parents[1] / 'jobs.json').read_text()))
            prefix = {'vs': 'vp', 'ps': 'fp', 'cs': 'cp'}[stage]
            Path(command[-1]).write_text(MSL + f'\nstruct spvDescriptorSetBuffer0\n{{\ntexture2d<float> {prefix}_t_tcb_8 [[id(0)]];\nsampler {prefix}_t_tcb_8Smplr [[id(1)]];\n}};\n', encoding='utf-8')
        elif '-o' in command:
            Path(command[-1]).write_bytes(b'MTLBsynthetic compiled output' if command[-1].endswith('.metallib') else b'synthetic AIR')

    def test_standalone_windows_compiler_uses_explicit_target_and_safe_path_arguments(self):
        tools=self.root/'Metal tools with spaces';tools.mkdir()
        for name in ('metal.exe','metallib.exe'):(tools/name).write_bytes(b'synthetic executable')
        source=self.root/'synthetic source.metal';source.write_text(MSL);calls=[]
        def runner(command,log,timeout=120):
            calls.append([str(c) for c in command]);self.runner(command,log,timeout)
        result=compile_metal(source,self.root/'metal output','iphoneos',runner=runner,metal_tools=tools)
        self.assertEqual(calls[0][:3],[str(tools/'metal.exe'),'-target','air64-apple-ios18.0'])
        self.assertIn('-fno-fast-math',calls[0]);self.assertIn(str(source),calls[0])
        cache=self.root/'metal output'/'module-cache'
        self.assertIn('-fmodules-cache-path='+str(cache),calls[0]);self.assertTrue(cache.is_dir())
        self.assertEqual(calls[1][0],str(tools/'metallib.exe'))
        self.assertEqual(result['source_sha256'],hashlib.sha256(source.read_bytes()).hexdigest())
        self.assertTrue(result['strict_float']);self.assertFalse(result['gpu_output_verified'])
        with self.assertRaises(FileExistsError):compile_metal(source,self.root/'metal output','iphoneos',runner=runner,metal_tools=tools)

    def test_metal_missing_objects_and_invalid_libraries_do_not_pass(self):
        source=self.root/'synthetic.metal';source.write_text(MSL)
        def empty(command,log,timeout=120):log.write_text('no artifact')
        with self.assertRaisesRegex(RuntimeError,'AIR'):compile_metal(source,self.root/'empty','iphoneos',runner=empty)
        def invalid(command,log,timeout=120):Path(command[-1]).write_bytes(b'not a Metal library')
        with self.assertRaisesRegex(RuntimeError,'MTLB'):compile_metal(source,self.root/'invalid','iphoneos',runner=invalid)
        with self.assertRaises(ValueError):compile_metal(source,self.root/'bad sdk','bad',runner=empty)
        with self.assertRaises(ValueError):compile_metal(source,self.root/'missing','iphoneos',runner=empty,metal_tools=self.root)

    def test_standalone_compiler_fingerprints_do_not_invalidate_spirv_reuse(self):
        old=self.root/'previous';self.run_diagnostic(output=old)
        tools=self.root/'standalone';tools.mkdir()
        for name in ('metal.exe','metallib.exe'):(tools/name).write_bytes(b'synthetic executable')
        report=diagnose(self.preparation,self.root/'standalone-output',self.tool,self.tool,self.tool,
                        sdks=('iphoneos',),runner=self.runner,reuse_diagnostics=old,metal_tools=tools)
        self.assertEqual(report['status'],'diagnostic_passed');self.assertEqual(report['summary']['reused_validation_and_msl'],1)
        self.assertEqual(set(report['standalone_metal_tools']),{'metal.exe','metallib.exe'})
        self.assertFalse(report['runnable_verified'])

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
        self.assertEqual(report['summary']['accessor_default_calls'], 1)
        self.assertEqual(report['summary']['shaders_using_accessor_defaults'], 1)
        self.assertEqual(report['shaders'][0]['audit']['handles'][0]['texture_byte_offset'], 32)
        self.assertEqual(report['shaders'][0]['audit']['handles'][0]['handle_source']['texture'], dict(kind='tex_combined', reg=0))
        self.assertEqual(report['summary']['shaders_with_unresolved_handles'], 0)
        self.assertEqual([x['sdk'] for x in report['shaders'][0]['metal']], ['macosx', 'iphoneos'])
        self.assertEqual(report['tools']['translator']['source_sha16'], '0123456789abcdef')
        self.assertFalse(any('_b.' in p.name for p in (self.root / 'out').rglob('*')))
        self.assertEqual(report['summary']['reflection_plans_with_complete_binding_coverage'], 1)
        plan_meta = report['shaders'][0]['reflection_plan']; plan_path = Path(plan_meta['path'])
        self.assertEqual(plan_meta['sha256'], hashlib.sha256(plan_path.read_bytes()).hexdigest())
        plan = json.loads(plan_path.read_text())
        self.assertFalse(plan['runtime_ready'])
        self.assertEqual(plan['query_audit']['calls_by_query'], {'sampler_type': 1})
        self.assertFalse(plan['query_audit']['resource_facts_verified'])
        self.assertTrue(plan['diagnostic_only'])
        self.assertEqual(plan['bindings'][0]['kind'], 'tex_combined')
        self.assertTrue(plan['source']['control_sha256'].startswith(self.jobs[0]['key']))
        self.assertEqual(len(plan['artifacts']), 3)
        for name, digest in plan['artifacts'].items():
            directory = 'msl' if name.endswith('.metal') else 'spirv'
            self.assertEqual(digest, hashlib.sha256((self.root / 'out' / directory / name).read_bytes()).hexdigest())

    def test_extraction_is_not_modified(self):
        before = {p: p.read_bytes() for p in self.preparation.rglob('*') if p.is_file()}
        self.run_diagnostic()
        self.assertEqual(before, {p: p.read_bytes() for p in self.preparation.rglob('*') if p.is_file()})

    def test_reuse_requires_identical_validated_artifacts_and_keeps_source_read_only(self):
        old=self.root/'previous';self.run_diagnostic(output=old)
        before={p:p.read_bytes() for p in old.rglob('*') if p.is_file()}
        calls=[]
        def runner(command,log,timeout=120):
            calls.append([str(x) for x in command]);return self.runner(command,log,timeout)
        def reuse(name):
            return diagnose(self.preparation,self.root/name,self.tool,self.tool,self.tool,
                            runner=runner,reuse_diagnostics=old)
        report=reuse('reused')
        self.assertEqual(report['status'],'diagnostic_passed')
        self.assertEqual(report['summary']['reused_validation_and_msl'],1)
        self.assertFalse(any('--target-env' in c or '--output' in c for c in calls))
        self.assertEqual(before,{p:p.read_bytes() for p in old.rglob('*') if p.is_file()})
        for i,path in enumerate((old/'msl'/(self.jobs[0]['key']+'.metal'),
                                  old/'reflection-plans'/(self.jobs[0]['key']+'.plan.json'))):
            original=path.read_bytes();path.write_bytes(b'tampered');calls.clear()
            report=reuse('corrupt'+str(i));path.write_bytes(original)
            self.assertEqual(report['status'],'diagnostic_passed')
            self.assertEqual(report['summary']['reused_validation_and_msl'],0)
            self.assertTrue(any('--target-env' in c for c in calls))
            self.assertTrue(any('--output' in c for c in calls))
        report_path=old/'diagnostic-report.json';original=report_path.read_text()
        for field,value in (('msl_options',[]),('source_sha256','other'),('validation_options',[])):
            changed=json.loads(original);changed[field]=value;report_path.write_text(json.dumps(changed))
            with self.assertRaises(ValueError):reuse('mismatch')
            self.assertFalse((self.root/'mismatch').exists())
        changed=json.loads(original);changed['tools']['validator']['sha256']='other';report_path.write_text(json.dumps(changed))
        report=reuse('wrong-tool');self.assertEqual(report['status'],'failed')
        self.assertIn('fingerprint mismatch',report['errors'][0]);report_path.write_text(original)

    def test_parallel_workers_preserve_order_failures_and_provenance(self):
        rows = []
        for value in range(4):
            data = shader(constants=256); data[0x40] = value
            rows.extend(scan_segment(data)[0])
        self.preparation = self.root / 'parallel'
        write_outputs(self.preparation, dict(file_sha256='test', build_id='test'), rows, [])
        failed = rows[1]['key']
        def runner(command, log, timeout=120):
            if '--target-env' in command and Path(command[-1]).stem == failed:
                raise RuntimeError('synthetic validation failure')
            return self.runner(command, log, timeout)
        report = diagnose(self.preparation, self.root / 'parallel-out', self.tool, self.tool, self.tool,
                          runner=runner, workers=3)
        self.assertEqual([row['key'] for row in report['shaders']], [row['key'] for row in rows])
        self.assertEqual(report['summary']['passed'], 3)
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['shaders'][1]['completed'], ['translated'])
        for row in report['shaders']:
            if row['status'] == 'diagnostic_passed':
                plan = json.loads(Path(row['reflection_plan']['path']).read_text())
                self.assertTrue(plan['source']['control_sha256'].startswith(row['key']))
        for workers in (0, 33, True):
            with self.assertRaises(ValueError):
                diagnose(self.preparation, self.root / 'invalid', self.tool, self.tool, self.tool, workers=workers)

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

    def use_compute_job(self):
        self.preparation = self.root / 'compute'
        rows, rejected = scan_segment(shader(5))
        write_outputs(self.preparation, dict(file_sha256='test', build_id='test'), rows, rejected)

    def test_compute_dimensions_checked_through_spirv(self):
        self.use_compute_job()
        report = self.run_diagnostic()
        self.assertEqual(report['status'], 'diagnostic_passed')
        row = report['shaders'][0]
        self.assertEqual(row['spirv_compute_workgroup'], [4, 2, 1])
        self.assertTrue(row['audit']['compute_workgroup_verified'])
        self.assertFalse(row['audit']['compute_configuration_verified'])
        self.assertFalse(row['compute_memory_audit']['memory_unused_proven'])

    def test_old_translator_missing_decode_extent_is_rejected(self):
        self.use_compute_job()
        def runner(command, log, timeout=120):
            self.runner(command, log, timeout)
            if len(command) == 3:
                for path in Path(command[2]).glob('*.res.json'):
                    res = json.loads(path.read_text()); res.pop('decoded_size'); path.write_text(json.dumps(res))
        report = self.run_diagnostic(runner)
        self.assertEqual(report['status'], 'failed')
        self.assertIn('rebuild the translator', report['shaders'][0]['error'])

    def test_compute_dimensions_or_control_tampering_rejected(self):
        self.use_compute_job()
        path = self.preparation / 'diagnostic-jobs.json'; original = path.read_text(encoding='utf-8')
        jobs = json.loads(original); jobs[0]['local'] = [1, 1, 1]
        path.write_text(json.dumps(jobs), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'workgroup'): self.run_diagnostic()
        path.write_text(original, encoding='utf-8')
        control = next((self.preparation / 'control').glob('*.bin')); data = bytearray(control.read_bytes()); data[0x748] ^= 1; control.write_bytes(data)
        with self.assertRaisesRegex(ValueError, 'Control digest'): self.run_diagnostic()

    def test_wrong_spirv_local_size_fails_before_msl(self):
        self.use_compute_job()
        def runner(command, log, timeout=120):
            self.runner(command, log, timeout)
            if len(command) == 3:
                for path in Path(command[2]).glob('*.spv'): path.write_bytes(compute_spirv((1, 1, 1)))
        report = self.run_diagnostic(runner)
        self.assertEqual(report['status'], 'failed')
        self.assertIn('LocalSize', report['shaders'][0]['error'])
        self.assertEqual(list((self.root / 'out' / 'msl').iterdir()), [])

    def test_spirv_local_size_structure_is_not_assumed(self):
        path = self.root / 'compute.spv'
        for blob in (b'bad', compute_spirv()[:20], compute_spirv() + b'\0' * 4,
                     compute_spirv() + compute_spirv()[40:], compute_spirv()[:-4]):
            path.write_bytes(blob)
            with self.assertRaises(ValueError): spirv_compute_workgroup(path)

    def test_schema_one_requires_new_extraction(self):
        path = self.preparation / 'shader-preparation.json'; manifest = json.loads(path.read_text(encoding='utf-8')); manifest['schema_version'] = 1
        path.write_text(json.dumps(manifest), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'rerun'): self.run_diagnostic()

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

    def test_unsupported_msl_member_stops_plan_and_metal_compilation(self):
        def runner(command, log, timeout=120):
            self.runner(command, log, timeout)
            if '--output' in command:
                Path(command[-1]).write_text('struct spvDescriptorSetBuffer0 {\nfloat unknown;\n};')
        report = self.run_diagnostic(runner, sdks=('iphoneos',))
        self.assertEqual(report['status'], 'failed')
        self.assertIn('member declaration', report['shaders'][0]['error'])
        self.assertEqual(list((self.root / 'out' / 'reflection-plans').iterdir()), [])
        self.assertFalse((self.root / 'out' / 'metal-iphoneos').exists())

    def test_metal_failure_preserves_completed_stages(self):
        def runner(command, log, timeout=120):
            if 'metallib' in command: raise RuntimeError('synthetic link failure')
            self.runner(command, log, timeout)
        report = self.run_diagnostic(runner, sdks=('iphoneos',))
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['shaders'][0]['completed'], ['translated', 'spirv_validated', 'msl_generated', 'reflection_planned'])

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

    def test_query_audit_distinguishes_defaults_and_inputs_without_granting_verification(self):
        res = resources(self.jobs[0])
        res['query_audit'] += [dict(query='compute_local_size_x', value=32, source='job_local'),
                              dict(query='texture_format', value='R32Uint', source='job_img', handle=8, cbuf_slot=2)]
        audit = audit_queries(res)
        self.assertEqual(audit['calls'], 3)
        self.assertEqual(audit['default_calls'], 1)
        self.assertFalse(audit['resource_facts_verified'])
        res['query_audit'] = []
        self.assertEqual(audit_queries(res)['default_calls'], 0)
        self.assertFalse(audit_queries(res)['resource_facts_verified'])

    def test_query_audit_rejects_missing_schema_unknown_sources_and_malformed_answers(self):
        res = resources(self.jobs[0])
        for field, value in [('query', 'unknown'), ('source', 'verified'), ('handle', True),
                             ('cbuf_slot', -2), ('value', None), ('value', '')]:
            changed = dict(res, query_audit=[dict(res['query_audit'][0], **{field: value})])
            with self.assertRaises(ValueError): audit_queries(changed)
        for rows in (None, {}, [None], [dict(query='compute_local_size_x', value=True, source='job_local')]):
            with self.assertRaises(ValueError): audit_queries(dict(res, query_audit=rows))
        for schema in (None, 0, 2):
            with self.assertRaisesRegex(ValueError, 'rebuild'): audit_queries(dict(res, query_audit_schema=schema))

    def test_old_translator_missing_query_audit_is_rejected_before_validation(self):
        def runner(command, log, timeout=120):
            self.runner(command, log, timeout)
            if len(command) == 3:
                for path in Path(command[2]).glob('*.res.json'):
                    res = json.loads(path.read_text()); res.pop('query_audit_schema'); path.write_text(json.dumps(res))
        report = self.run_diagnostic(runner)
        self.assertEqual(report['status'], 'failed')
        self.assertIn('rebuild the translator', report['shaders'][0]['error'])
        self.assertFalse(report['shaders'][0]['completed'])


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
