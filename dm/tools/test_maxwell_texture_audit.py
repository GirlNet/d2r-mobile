# 合成指令验证同句柄旁证、图形头/调度字偏移、冲突及 1D/缓冲歧义保留。
# Synthetic instructions test same-handle corroboration, graphics headers/schedules, conflicts and retained 1D/buffer ambiguity.
import struct
import unittest

from maxwell_texture_audit import audit_texture_queries, audit_texture_resources
from test_maxwell_memory_audit import encoding


def instruction(name='Tlds', handle=8, target=2):
    word = encoding(name)
    return (word & ~((15 << 53) | (0x1fff << 36))) | (target << 53) | (handle << 36)


class TextureQueryConstraintTests(unittest.TestCase):
    def audit(self, *words, stage='cs', bank=-1, handle=8, value='Texture2D'):
        blob = struct.pack('<' + 'Q' * (len(words) + 1), 0, *words)
        if stage != 'cs': blob = bytes(0x50) + blob
        job = dict(stage=stage)
        resource = dict(decoded_size=len(blob), query_audit=[dict(query='sampler_type', handle=handle,
            cbuf_slot=bank, value=value, source='missing_default')])
        return audit_texture_queries(job, resource, blob)

    def test_same_handle_2d_opcode_corroborates_without_becoming_verified(self):
        result = self.audit(instruction())
        query = result['queries'][0]
        self.assertTrue(query['answer_corroborated'])
        self.assertEqual(query['candidate_types'], ['Texture2D'])
        self.assertFalse(query['resource_object_verified'])
        self.assertFalse(result['resource_facts_verified'])
        self.assertFalse(result['auto_applied'])

    def test_other_handles_and_banks_cannot_supply_evidence(self):
        for args in (dict(handle=10), dict(bank=2)):
            result = self.audit(instruction(), **args)['queries'][0]
            self.assertFalse(result['answer_corroborated'])
            self.assertEqual(result['evidence'], [])

    def test_conflicting_unknown_or_1d_buffer_types_are_not_confirmed(self):
        for words in ((instruction(), instruction(target=7)), (instruction(target=0),),
                      (instruction(target=15),), (instruction(), 0)):
            self.assertFalse(self.audit(*words)['queries'][0]['answer_corroborated'])

    def test_graphics_header_schedule_and_decoded_extent_are_respected(self):
        result = self.audit(instruction(), encoding('Exit'), encoding('Nop'), instruction(target=7), stage='ps')
        query = result['queries'][0]
        self.assertTrue(query['answer_corroborated'])
        self.assertEqual([i['offset'] for i in query['evidence']], [0x58])
        blob = struct.pack('<QQQ', 0, instruction(), instruction(target=7))
        res = dict(decoded_size=16, query_audit=[dict(query='sampler_type', handle=8, cbuf_slot=-1,
                                                   value='Texture2D', source='missing_default')])
        self.assertTrue(audit_texture_queries(dict(stage='cs'), res, blob)['queries'][0]['answer_corroborated'])

    def test_invalid_extents_are_rejected(self):
        for extent in (None, True, 8, 17, 40):
            with self.assertRaises(ValueError):
                audit_texture_queries(dict(stage='cs'), dict(decoded_size=extent), bytes(32))

    def test_texs_types_arrays_shadow_and_cube_are_preserved(self):
        for target, value in ((1, 'Texture2D'), (4, 'Texture2D, Shadow'), (7, 'Texture2D, Array'),
                              (9, 'Texture2D, Array, Shadow'), (12, 'TextureCube')):
            self.assertTrue(self.audit(instruction('Texs', target=target), value=value)['queries'][0]['answer_corroborated'])


class TextureResourceShapeTests(unittest.TestCase):
    def audit(self, *words, stage='cs', bank=-1, handle=8, ty=3, array=1, separate=False):
        blob = struct.pack('<' + 'Q' * (len(words) + 1), 0, *words)
        if stage != 'cs': blob = bytes(0x50) + blob
        resource = dict(decoded_size=len(blob), textures=[dict(binding=4, handle=handle,
            cbuf_slot=bank, type=ty, array=array, separate=separate)])
        return audit_texture_resources(dict(stage=stage), resource, blob)

    def test_direct_instructions_corroborate_shape_without_promoting_runtime(self):
        for name in ('Texs', 'TexsF16', 'Tlds', 'TldsF16'):
            word = instruction(name, target=1 if name.startswith('Texs') else 2)
            result = self.audit(word, stage='ps')
            self.assertTrue(result['all_shader_shapes_corroborated'])
            self.assertEqual(result['bindings'][0]['evidence'][0]['offset'], 0x58)
            self.assertFalse(result['runtime_ready'])
            self.assertFalse(result['resource_facts_verified'])
            self.assertFalse(result['bindings'][0]['bound_resource_verified'])
            self.assertFalse(result['bindings'][0]['sample_format_verified'])

    def test_tex_dimensions_and_depth_compare_are_independent_of_msl(self):
        for dimension, ty in ((0, 1), (1, 0x101), (2, 3), (3, 0x103), (4, 4), (6, 5), (7, 0x105)):
            for shadow in (0, 1):
                word = encoding('Tex') | (8 << 36) | (dimension << 28) | (shadow << 50)
                self.assertTrue(self.audit(word, ty=ty | (shadow << 10))['all_shader_shapes_corroborated'])

    def test_1d_buffer_unknown_bindless_and_conflicting_types_are_retained(self):
        cases = [(instruction(target=0),), (instruction(target=15),),
                 (instruction(), instruction(target=7)), (instruction(), 0),
                 (instruction(), encoding('TexB'))]
        for words in cases:
            self.assertFalse(self.audit(*words)['all_shader_shapes_corroborated'])
        self.assertFalse(self.audit(encoding('Tld') | (8 << 36))['all_shader_shapes_corroborated'])

    def test_queries_alone_and_different_banks_or_handles_cannot_prove_shapes(self):
        self.assertFalse(self.audit(encoding('Txq') | (8 << 36))['all_shader_shapes_corroborated'])
        for args in (dict(bank=0), dict(handle=9), dict(array=2), dict(separate=True), dict(ty=4)):
            self.assertFalse(self.audit(instruction(), **args)['all_shader_shapes_corroborated'])

    def test_multisample_bit_does_not_get_misread_as_shadow(self):
        word = encoding('Tld') | (8 << 36) | (2 << 28) | (1 << 50)
        self.assertTrue(self.audit(word, ty=3 | 0x200)['all_shader_shapes_corroborated'])
        self.assertFalse(self.audit(word, ty=3 | 0x400)['all_shader_shapes_corroborated'])


if __name__ == '__main__': unittest.main()
