# 合成壳、模块及诊断文件验证 IPA 内容、来源散列、越界输入与未就绪标记；不包含游戏数据。
# Synthetic shells, modules and diagnostics test IPA contents, source digests, invalid inputs and non-ready markers without game data.
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

from p5r_pack import MODULES, package


def digest(data): return hashlib.sha256(data).hexdigest()


class P5RPackTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup); self.root = Path(tmp.name)
        self.shell = self.root / 'shell.ipa'; self.prep = self.root / 'prep'; self.diag = self.root / 'diag'
        self.out = self.root / 'delivery/game.ipa'
        self.shell_files = {'dm/p5r-shell.json':json.dumps(dict(profile='p5r',game_content_included=False,shader_chain='synthetic')).encode(),
                            'Info.plist':plistlib.dumps(dict(CFBundleIdentifier='org.p5r.test')),
                            'P5RMobile':struct.pack('<IiiIIIII',0xfeedfacf,0x100000c,0,2,0,0,0,0)}
        self.write_shell()
        rewritten = self.prep / 'rewritten'; rewritten.mkdir(parents=True)
        outputs = {}
        for name in MODULES:
            image = bytes(0xc010); outputs[name] = digest(image)
            (rewritten / (name + '.patched.bin')).write_bytes(image)
            fields = dict(TEXT_END='0x2000',RO_OFF='0x4000',DATA_OFF='0x4000',KEY_PAGE_OFF='0x8000',KEY_PAGE_SIZE='0x4000',PATCH_OFF='0xc000')
            fields.update({'KEY_' + k + '_IDX':str(i) for i,k in enumerate(('K18','KTLS','KTLR','KGATE','KRES0','KRES1','KASPECT','KASPECTUI'))})
            (rewritten / (name + '.fixups.tsv')).write_text(''.join(f'# {k}\t{v}\n' for k,v in fields.items()))
            (rewritten / (name + '.gates.tsv')).write_bytes(b'')
        self.prep_report = dict(status='equivalence_passed',outputs=outputs,inputs=dict(main='synthetic-source'))
        (self.prep / 'port-preparation.json').write_text(json.dumps(self.prep_report))
        self.key = '0123456789abcdef'
        for folder in ('spirv','msl','reflection-plans'): (self.diag / folder).mkdir(parents=True)
        artifacts = {}
        for suffix,folder in (('.spv','spirv'),('.res.json','spirv'),('.metal','msl')):
            blob = b'synthetic'; name = self.key + suffix; artifacts[name] = digest(blob)
            (self.diag / folder / name).write_bytes(blob)
        plan = dict(key=self.key,stage='cs',diagnostic_only=True,runtime_ready=False,artifacts=artifacts)
        self.plan_path = self.diag / 'reflection-plans' / (self.key + '.plan.json')
        self.plan_path.write_text(json.dumps(plan))
        self.diag_report = dict(status='diagnostic_passed',diagnostic_only=True,source_sha256='synthetic-source',shaders=[dict(
            key=self.key,stage='cs',status='diagnostic_passed',reflection_plan=dict(sha256=digest(self.plan_path.read_bytes())))])
        self.write_diagnostic_report()

    def write_shell(self, extra=None):
        with zipfile.ZipFile(self.shell,'w') as archive:
            for name,data in self.shell_files.items(): archive.writestr('Payload/P5RMobile.app/' + name,data)
            if extra: archive.writestr(extra,b'bad')

    def write_diagnostic_report(self):
        (self.diag / 'diagnostic-report.json').write_text(json.dumps(self.diag_report))

    def pack(self): return package(self.shell,self.prep,self.diag,self.out)

    def test_full_package_contains_all_modules_and_preserves_not_ready(self):
        result = self.pack(); self.assertTrue(result['host_linked']); self.assertFalse(result['runtime_ready'])
        self.assertFalse(result['signed']); self.assertEqual(result['diagnostic_shaders'],1)
        with zipfile.ZipFile(self.out) as archive:
            base = 'Payload/P5RMobile.app/'
            guest = archive.read(base + 'Frameworks/Guest.framework/Guest')
            self.assertEqual(struct.unpack_from('<IiiI',guest),(0xfeedfacf,0x100000c,0,6))
            for name in MODULES:
                self.assertIn(('__dm'+name+'x0').encode(),guest)
                self.assertIn(('__DM'+name+'W').encode(),guest)
                self.assertEqual(archive.read(base+'dm/'+name+'.fixups.tsv'),(self.prep/'rewritten'/(name+'.fixups.tsv')).read_bytes())
            info = archive.getinfo(base+'Frameworks/Guest.framework/Guest')
            self.assertTrue(info.external_attr >> 16 & 0o111)
            manifest = json.loads(archive.read(base+'dm/p5r-package.json'))
            self.assertFalse(manifest['runtime_ready']); self.assertFalse(manifest['graphics_verified'])
            self.assertIsNone(archive.testzip())
        self.assertEqual(result['archive_sha256'],digest(self.out.read_bytes()))

    def test_corrupted_module_is_rejected_before_writing(self):
        (self.prep/'rewritten/main.patched.bin').write_bytes(b'bad')
        with self.assertRaisesRegex(ValueError,'digest'): self.pack()
        self.assertFalse(self.out.exists())

    def test_diagnostic_artifact_or_plan_tampering_is_rejected(self):
        path = self.diag/'msl'/(self.key+'.metal'); original=path.read_bytes();path.write_bytes(b'tamper')
        with self.assertRaisesRegex(ValueError,'artifact digest'): self.pack()
        path.write_bytes(original);self.plan_path.write_bytes(b'tamper')
        with self.assertRaisesRegex(ValueError,'plan digest'): self.pack()

    def test_shader_source_and_equivalence_must_match(self):
        self.diag_report['source_sha256']='other';self.write_diagnostic_report()
        with self.assertRaisesRegex(ValueError,'source mismatch'): self.pack()
        self.diag_report['source_sha256']='synthetic-source';self.write_diagnostic_report()
        self.prep_report['status']='running';(self.prep/'port-preparation.json').write_text(json.dumps(self.prep_report))
        with self.assertRaisesRegex(ValueError,'equivalence'): self.pack()

    def test_unsafe_shell_paths_and_wrong_profile_are_rejected(self):
        for name in ('../escape','Payload/../escape','Payload/P5RMobile.app/../escape','Payload/P5RMobile.app/Frameworks/Guest.framework/Guest'):
            self.write_shell(name)
            with self.assertRaises(ValueError): self.pack()
        self.shell_files['dm/p5r-shell.json']=json.dumps(dict(profile='d2r',game_content_included=False)).encode();self.write_shell()
        with self.assertRaisesRegex(ValueError,'P5R shell'): self.pack()

    def test_private_cuts_and_invalid_key_layout_are_rejected(self):
        cut=self.prep/'rewritten/main.cuts.tsv';cut.write_text('0x1234 private-hook\n')
        with self.assertRaisesRegex(ValueError,'private cuts'): self.pack()
        cut.unlink(); path=self.prep/'rewritten/main.fixups.tsv'; path.write_text(path.read_text().replace('KEY_KGATE_IDX\t3','KEY_KGATE_IDX\t0'))
        with self.assertRaisesRegex(ValueError,'thread-key'): self.pack()

    def test_existing_output_and_source_tree_are_preserved(self):
        self.out.parent.mkdir();self.out.write_bytes(b'keep')
        with self.assertRaises(FileExistsError): self.pack()
        self.assertEqual(self.out.read_bytes(),b'keep')
        with self.assertRaises(ValueError): package(self.shell,self.prep,self.diag,self.prep/'bad.ipa')

    def make_shader_bundle(self):
        chain='0123456789ab';directory=self.root/'staged';cache=directory/'msl'/('b-'+chain);cache.mkdir(parents=True)
        self.shell_files['dm/p5r-shell.json']=json.dumps(dict(profile='p5r',game_content_included=False,shader_chain=chain)).encode();self.write_shell()
        plan=json.loads(self.plan_path.read_text());plan.update(bindings=[],source=dict(c1_sha256=digest(b'')),msl_sha256=digest(b'synthetic'))
        self.plan_path.write_text(json.dumps(plan));self.diag_report['shaders'][0]['reflection_plan']['sha256']=digest(self.plan_path.read_bytes())
        self.diag_report['shaders'][0]['metal']=[dict(sdk='iphoneos',target='air64-apple-ios18.0',strict_float=True,
            sha256=digest(b'MTLB native synthetic'),source_sha256=digest(b'synthetic'))];self.write_diagnostic_report()
        reflection=dict(key=self.key+'_b',dm_ctl=self.key,chain=chain,profile='p5r',route='B',stage='cs',
            bindings=[],c1='',diagnostic_only=True,runtime_ready=False,resource_facts_verified=False)
        hashes={}
        for suffix,data in (('.metallib',b'MTLB native synthetic'),('.metal',b'synthetic'),('.json',json.dumps(reflection).encode())):
            name=self.key+'_b'+suffix;(cache/name).write_bytes(data);hashes[name]=digest(data)
        report=dict(schema_version=1,profile='p5r',status='staged_unverified',shader_chain=chain,source_sha256='synthetic-source',
            diagnostic_only=True,runtime_ready=False,graphics_verified=False,game_launch_enabled=False,shaders=1,
            shader_records=[dict(key=self.key,stage='cs',artifacts=hashes)])
        (directory/'bundle-report.json').write_text(json.dumps(report))
        return directory,cache,report

    def test_staged_native_libraries_mapping_and_c1_are_packaged_without_enabling_launch(self):
        directory,cache,_=self.make_shader_bundle()
        result=package(self.shell,self.prep,self.diag,self.out,shader_bundle=directory)
        self.assertEqual(result['staged_native_shaders'],1);self.assertFalse(result['staged_shader_bundle_ready'])
        self.assertFalse(result['runtime_ready'])
        with zipfile.ZipFile(self.out) as archive:
            base='Payload/P5RMobile.app/'
            self.assertEqual(archive.read(base+'msl/b-0123456789ab/'+self.key+'_b.metallib'),b'MTLB native synthetic')
            self.assertIn(self.key,archive.read(base+'dm/shader_map.tsv').decode())
            self.assertEqual(archive.read(base+'dm/c1_full.tsv').decode(),'# chain b-0123456789ab\n'+self.key+'\n')
            reflection=json.loads(archive.read(base+'msl/b-0123456789ab/'+self.key+'_b.json'))
            self.assertTrue(reflection['diagnostic_only']);self.assertFalse(reflection['runtime_ready'])

    def test_corrupt_native_bundle_cannot_leave_a_complete_package(self):
        directory,cache,_=self.make_shader_bundle();(cache/(self.key+'_b.metallib')).write_bytes(b'tamper')
        with self.assertRaisesRegex(ValueError,'Staged shader artifact digest'):
            package(self.shell,self.prep,self.diag,self.out,shader_bundle=directory)
        self.assertFalse(self.out.exists());self.assertFalse(self.out.with_suffix('.ipa.tmp').exists())

    def test_staged_bundle_cannot_change_chain_source_or_ready_markers(self):
        directory,_,report=self.make_shader_bundle()
        for field,value in (('shader_chain','000000000000'),('source_sha256','different'),('runtime_ready',True)):
            changed=dict(report);changed[field]=value;(directory/'bundle-report.json').write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError,'source-matched unverified'):
                package(self.shell,self.prep,self.diag,self.out,shader_bundle=directory)
            self.assertFalse(self.out.exists())


if __name__=='__main__': unittest.main()
