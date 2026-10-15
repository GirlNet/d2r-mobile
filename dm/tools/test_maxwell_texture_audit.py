# 合成指令验证同句柄旁证、图形头/调度字偏移、冲突及 1D/缓冲歧义保留。
# Synthetic instructions test same-handle corroboration, graphics headers/schedules, conflicts and retained 1D/buffer ambiguity.
import struct
import unittest

from maxwell_texture_audit import audit_texture_queries
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


if __name__ == '__main__': unittest.main()
