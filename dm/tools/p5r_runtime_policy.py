"""Build an explicit, guarded execution contract without claiming game verification."""
import copy

CONTRACT = dict(version=1, pipeline='p5r_nvn11', resources='per_binding',
                coordinates='normalized', storage='exact_gpu_pointer')
FIXED = dict(transform_feedback_enabled=False,
    graphics_state='fixed_pipeline_defaults_with_job_attr_fout',
    constant_buffer_draw_parameters=False, texture_coord_normalized=True,
    compute_local_memory_size=4096, compute_shared_memory_size=0,
    unaligned_storage_buffer=False)
KINDS = {'support', 'c1', 'cbuf', 'sbuf', 'ubo_ptr', 'tex', 'tex_combined',
         'samp', 'samp_tex', 'samp_combined'}


def guarded_reflection(plan):
    if (plan.get('profile') != 'p5r' or plan.get('route') != 'B'
            or plan.get('diagnostic_only') is not True or plan.get('runtime_ready') is not False
            or plan.get('resource_facts_verified') is not False
            or plan.get('binding_coverage_complete') is not True or plan.get('missing_descriptors')):
        raise ValueError('Guarded runtime requires a complete unverified P5R plan')
    audit = plan.get('query_audit', {})
    if not isinstance(audit.get('entries'), list):
        raise ValueError('Missing translation query audit')
    query_constraints = plan.get('texture_query_constraints', {}).get('queries', [])
    for query in audit['entries']:
        name, value = query.get('query'), query.get('value')
        if not isinstance(name,str):
            raise ValueError('Invalid translation query name')
        if name == 'sampler_type':
            if value != 'Texture2D' or not any(
                item.get('handle') == query.get('handle') and item.get('cbuf_slot') == query.get('cbuf_slot')
                and item.get('answer') == value and item.get('answer_corroborated') is True
                for item in query_constraints):
                raise ValueError('Uncorroborated sampler-type query')
        elif name.startswith('compute_local_size_'):
            axis = {'compute_local_size_x':0, 'compute_local_size_y':1, 'compute_local_size_z':2}.get(name)
            if axis is None or plan.get('stage') != 'cs' or value != plan['threadgroup_size'][axis]:
                raise ValueError('Compute workgroup query mismatch')
        elif name not in FIXED or type(value) is not type(FIXED[name]) or value != FIXED[name]:
            raise ValueError('Unsupported translation query: ' + str(name))
    if plan.get('stage') == 'cs' and plan.get('compute_memory_audit', {}).get('memory_unused_proven') is not True:
        raise ValueError('Compute local/shared memory is not proven unused')
    constraints = plan.get('texture_resource_constraints', {})
    if constraints.get('unknown_instruction_offsets') or constraints.get('unsupported_texture_instructions'):
        raise ValueError('Unknown or unsupported texture instructions')
    textures = set()
    for binding in plan['bindings']:
        if binding.get('kind') not in KINDS or binding.get('slot_mapping_verified') is not True:
            raise ValueError('Unsupported guarded resource binding')
        if binding['kind'] in ('tex', 'tex_combined'):
            if binding.get('msl_type') not in ('texture2d<float>', 'texturecube<float>'):
                raise ValueError('Unsupported guarded texture declaration')
            textures.add(binding['descriptor']['binding'])
    evidence = constraints.get('bindings', [])
    if textures != {item['binding'] for item in evidence} or any(item.get('shader_shape_corroborated') is not True for item in evidence):
        raise ValueError('Texture instruction evidence does not cover the bindings')
    result = copy.deepcopy(plan)
    result.update(diagnostic_only=False, runtime_ready=False, resource_facts_verified=False,
                  runtime_contract=dict(CONTRACT), execution_mode='guarded_candidate')
    return result
