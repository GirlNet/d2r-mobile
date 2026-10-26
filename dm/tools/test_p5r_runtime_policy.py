import copy
import unittest
from p5r_runtime_policy import guarded_reflection


class RuntimePolicyTests(unittest.TestCase):
    def setUp(self):
        self.plan=dict(profile='p5r',route='B',stage='ps',diagnostic_only=True,runtime_ready=False,
            resource_facts_verified=False,binding_coverage_complete=True,missing_descriptors=[],bindings=[],
            query_audit=dict(entries=[dict(query='graphics_state',value='fixed_pipeline_defaults_with_job_attr_fout')]),
            texture_resource_constraints=dict(bindings=[]))

    def test_guarded_mode_retains_unverified_flags_and_input(self):
        before=copy.deepcopy(self.plan);result=guarded_reflection(self.plan)
        self.assertEqual(self.plan,before);self.assertFalse(result['runtime_ready'])
        self.assertFalse(result['resource_facts_verified']);self.assertFalse(result['diagnostic_only'])
        self.assertEqual(result['execution_mode'],'guarded_candidate')

    def test_unknown_queries_and_changed_defaults_fail(self):
        for query,value in [('future_query',False),('texture_coord_normalized',False),('transform_feedback_enabled',True),('texture_coord_normalized',1)]:
            self.plan['query_audit']['entries']=[dict(query=query,value=value)]
            with self.assertRaises(ValueError):guarded_reflection(self.plan)

    def test_sampler_query_requires_same_handle_and_bank_evidence(self):
        self.plan['query_audit']['entries']=[dict(query='sampler_type',value='Texture2D',handle=8,cbuf_slot=-1)]
        with self.assertRaisesRegex(ValueError,'Uncorroborated'):guarded_reflection(self.plan)
        self.plan['texture_query_constraints']=dict(queries=[dict(handle=8,cbuf_slot=-1,answer='Texture2D',answer_corroborated=True)])
        guarded_reflection(self.plan)

    def test_texture_binding_requires_instruction_shape_coverage(self):
        self.plan['bindings']=[dict(kind='tex_combined',slot_mapping_verified=True,msl_type='texture2d<float>',descriptor=dict(binding=1))]
        with self.assertRaisesRegex(ValueError,'evidence'):guarded_reflection(self.plan)
        self.plan['texture_resource_constraints']['bindings']=[dict(binding=1,shader_shape_corroborated=True)]
        guarded_reflection(self.plan)
        self.plan['bindings'][0]['msl_type']='texture2d<uint>'
        with self.assertRaisesRegex(ValueError,'declaration'):guarded_reflection(self.plan)

    def test_compute_local_shared_memory_and_workgroups_are_constrained(self):
        self.plan.update(stage='cs',threadgroup_size=[32,1,1],compute_memory_audit=dict(memory_unused_proven=False))
        with self.assertRaisesRegex(ValueError,'memory'):guarded_reflection(self.plan)
        self.plan['compute_memory_audit']['memory_unused_proven']=True
        self.plan['query_audit']['entries']=[dict(query='compute_local_size_x',value=64)]
        with self.assertRaisesRegex(ValueError,'workgroup'):guarded_reflection(self.plan)
        self.plan['query_audit']['entries'][0]['value']=32;guarded_reflection(self.plan)

    def test_driver_banks_and_images_cannot_bypass_contract(self):
        for kind in ('drvcb','img','unresolved'):
            self.plan['bindings']=[dict(kind=kind,slot_mapping_verified=True)]
            with self.assertRaisesRegex(ValueError,'binding'):guarded_reflection(self.plan)


if __name__=='__main__':unittest.main()
