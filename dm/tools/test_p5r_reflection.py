# 用合成描述符和 MSL 验证反射草案的资源对应、候选槽及保守失败；不读取游戏数据。
# Synthetic descriptors and MSL test reflection-plan resource matching, candidate slots and conservative failures without game data.
import copy
import hashlib
import unittest

from p5r_reflection import reflection_plan


def job(stage='ps'):
    return dict(key='0123456789abcdef', stage=stage, diagnostic_only=True,
                resource_facts_verified=False, local=[32, 1, 1] if stage == 'cs' else None)


def resource(stage='ps', **items):
    return dict(key=job()['key'], stage=stage, cbufs=items.get('cbufs', []),
                sbufs=items.get('sbufs', []), textures=items.get('textures', []), images=items.get('images', []))


def msl(*members):
    return 'struct spvDescriptorSetBuffer0\n{\n' + '\n'.join(members) + '\n};\n'


def texture(handle=8, **changes):
    return dict(binding=2, handle=handle, cbuf_slot=-1, array=1, type=3,
                format='Unknown', separate=False, **changes)


class ReflectionPlanTests(unittest.TestCase):
    def plan(self, source, res=None, stage='ps'):
        return reflection_plan(job(stage), res or resource(stage), source)

    def test_vertex_input_locations_preserve_sparse_shader_slots(self):
        source='struct main0_in { float4 position [[attribute(0)]]; float2 joints [[attribute(7)]]; };'
        plan=self.plan(source,stage='vs')
        self.assertEqual(plan['vertex_inputs'],[dict(location=0,msl_type='float4',msl_name='position'),dict(location=7,msl_type='float2',msl_name='joints')])
        self.assertFalse(plan['vertex_input_state_verified'])
        self.assertFalse(plan['runtime_ready'])
        for source in ('half4 position [[attribute(0)]];', 'float4 a [[attribute(16)]];',
                       'float4 a [[attribute(0)]];float b [[attribute(0)]];'):
            with self.assertRaises(ValueError):self.plan(source,stage='vs')
        with self.assertRaises(ValueError):self.plan('float4 a [[attribute(0)]];',stage='ps')

    def test_combined_sampler_and_texture_use_independent_slot_domain(self):
        source = msl('texture2d<float> fp_t_tcb_8 [[id(7)]];', 'sampler fp_t_tcb_8Smplr [[id(3)]];')
        plan = self.plan(source, resource(textures=[texture()]))
        tex, samp = plan['bindings']
        self.assertEqual((tex['kind'], tex['reg'], tex['arg_id']), ('tex_combined', 0, 7))
        self.assertEqual((samp['kind'], samp['reg']), ('samp_combined', 0))
        self.assertTrue(tex['slot_mapping_verified'])
        self.assertFalse(tex['resource_type_verified'])
        self.assertTrue(plan['binding_coverage_complete'])
        self.assertFalse(plan['runtime_ready'])
        self.assertTrue(plan['diagnostic_only'])
        self.assertFalse(plan['resource_facts_verified'])
        self.assertEqual(plan['msl_sha256'], hashlib.sha256(source.encode()).hexdigest())

    def test_separate_sampler_handle_uses_distinct_register(self):
        handle = 0x10000000 | (0x570 // 4 << 14) | 0x170 // 4
        name = f'fp_t_cb2_{handle:X}'
        item = texture(handle); item['cbuf_slot'] = 2
        plan = self.plan(msl(f'texture2d<float> {name} [[id(0)]];', f'sampler {name}Smplr [[id(1)]];'),
                         resource(textures=[item]))
        self.assertEqual([(b['kind'], b['reg']) for b in plan['bindings']], [('tex', 1), ('samp', 1)])

    def test_storage_uses_descriptor_slot_not_binding_sort_order(self):
        res = resource('cs', sbufs=[dict(binding=12, slot=0, cb_slot=0, cb_offset=196, flags=1),
                                   dict(binding=4, slot=1, cb_slot=0, cb_offset=200, flags=0)])
        plan = self.plan(msl('device _21* cp_s1 [[id(0)]];', 'device _21* cp_s0 [[id(1)]];'), res, 'cs')
        self.assertEqual([(b['reg'], b['rw']) for b in plan['bindings']], [(1, False), (0, True)])
        self.assertTrue(all(b['slot_mapping_verified'] for b in plan['bindings']))
        self.assertEqual(plan['threadgroup_size'], [32, 1, 1])

    def test_uniform_pointer_and_unrecognized_driver_pointer(self):
        for bank, offset, expected in [(0, 0x210 // 4, 'ubo_ptr'), (0, 0x214 // 4, 'unresolved'),
                                       (2, 0x310 // 4, 'unresolved'), (0, 0x410 // 4, 'unresolved')]:
            res = resource('cs', sbufs=[dict(binding=1, slot=0, cb_slot=bank, cb_offset=offset, flags=0)])
            binding = self.plan(msl('device _21* cp_s0 [[id(0)]];'), res, 'cs')['bindings'][0]
            self.assertEqual(binding['kind'], expected)
            self.assertEqual(binding['slot_mapping_verified'], expected != 'unresolved')
            self.assertEqual(bool(binding['blockers']), expected == 'unresolved')

    def test_constants_driver_and_user_uniforms_keep_evidence_distinct(self):
        res = resource(cbufs=[dict(binding=i, slot=n) for i, n in enumerate((0, 1, 2, 3, 16, 17))])
        source = msl(*(f'constant _16* fp_c{n} [[id({i})]];' for i, n in enumerate((0, 1, 2, 3, 16, 17))))
        bs = self.plan(source, res)['bindings']
        self.assertEqual([b['kind'] for b in bs], ['drvcb', 'c1', 'drvcb', 'cbuf', 'cbuf', 'unresolved'])
        self.assertEqual([bs[i]['reg'] for i in (3, 4)], [0, 13])
        self.assertTrue(bs[1]['slot_mapping_verified'])
        self.assertTrue(bs[3]['slot_mapping_verified'])

    def test_compute_only_first_five_uniforms_are_direct_banks(self):
        for bank in range(3, 17):
            res = resource('cs', cbufs=[dict(binding=1, slot=bank)])
            binding = self.plan(msl(f'constant _16* cp_c{bank} [[id(0)]];'), res, 'cs')['bindings'][0]
            self.assertEqual(binding['slot_mapping_verified'], bank <= 7)
            self.assertEqual(binding['kind'], 'cbuf' if bank <= 7 else 'unresolved')

    def test_unknown_members_missing_resources_and_stage_mismatch_are_visible(self):
        res = resource(cbufs=[dict(binding=1, slot=3)])
        for source in ('kernel void main0() {}', msl('constant _16* vp_c3 [[id(0)]];')):
            plan = self.plan(source, res)
            self.assertFalse(plan['binding_coverage_complete'])
            self.assertEqual(plan['missing_descriptors'][0]['slot'], 3)

    def test_unsupported_resources_are_not_silently_mapped(self):
        for field, value in [('array', 2), ('separate', True), ('type', 0), ('handle', 0x568 // 4)]:
            item = texture(); item[field] = value
            plan = self.plan(msl(f'texture2d<float> fp_t_tcb_{item["handle"]:X} [[id(0)]];'), resource(textures=[item]))
            self.assertFalse(plan['binding_coverage_complete'])
            self.assertFalse(plan['runtime_ready'])
        item = texture()
        plan = self.plan(msl('texture2d<float> fp_i_tcb_8 [[id(0)]];'), resource(images=[item]))
        self.assertEqual(plan['bindings'][0]['kind'], 'unresolved')

    def test_argument_member_syntax_duplicates_and_types_fail_closed(self):
        for source in (msl('float unknown [[id(0)]];', 'float other [[id(0)]];'),
                       msl('float unknown [[id(0)]];', 'float unknown [[id(1)]];'),
                       msl('float unknown;'), msl('float unknown [[id(0)]];') * 2,
                       msl('device _16* support_buffer [[id(0)]];')):
            with self.assertRaises(ValueError): self.plan(source)
        res = resource(textures=[texture()])
        with self.assertRaises(ValueError):
            self.plan(msl('texture2d<float> fp_t_tcb_8Smplr [[id(0)]];'), res)

    def test_descriptor_duplicates_invalid_values_and_identity_rejected(self):
        res = resource(cbufs=[dict(binding=1, slot=3)])
        for item in (dict(binding=1, slot=4), dict(binding=2, slot=3), dict(binding=-1, slot=5)):
            changed = copy.deepcopy(res); changed['cbufs'].append(item)
            with self.assertRaises(ValueError): self.plan('', changed)
        for item in (dict(binding=1, slot=True), dict(binding=1, slot=-1)):
            with self.assertRaises(ValueError): self.plan('', resource(cbufs=[item]))
        with self.assertRaises(ValueError): self.plan('', resource('cs'))
        changed = job(); changed['diagnostic_only'] = False
        with self.assertRaises(ValueError): reflection_plan(changed, resource(), '')

    def test_support_and_argument_limit_do_not_grant_runtime_readiness(self):
        plan = self.plan(msl('constant _10* support_buffer [[id(64)]];'))
        self.assertEqual(plan['bindings'][0]['kind'], 'support')
        self.assertTrue(plan['bindings'][0]['blockers'])
        self.assertFalse(plan['runtime_ready'])


if __name__ == '__main__':
    unittest.main()
