// 根据 NVN 累计采样语义，在提交末尾把 Metal 可见性槽折叠到不可变的 GPU 前缀。
// 不在 CPU 上等待读回；ReportCounter 的完成回调读取其持有的前缀及本次报告的槽。
// Fold Metal visibility slots into an immutable GPU prefix at submit end, following NVN cumulative samples.
// Avoid a CPU readback wait; each ReportCounter callback reads its retained prefix and current report's slots.
static void vis_encode_prefix(void) {
    static id<MTLComputePipelineState> pipeline;
    static id<MTLBuffer> zero;
    if(!pipeline) {
        NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
          "kernel void fold_visibility(device const ulong *samples[[buffer(0)]],device const ulong *prefix[[buffer(1)]],"
          "device ulong *total[[buffer(2)]],constant uint *slots[[buffer(3)]],constant ulong2 &p[[buffer(4)]]){"
          "ulong sum=p.x+prefix[0];for(uint i=0;i<uint(p.y);i++)sum+=samples[slots[i]];total[0]=sum;}";
        NSError *error=nil;id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];
        pipeline=library?[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"fold_visibility"] error:&error]:nil;
        if(!pipeline)MDIE("Cannot compile visibility prefix: %s",error.localizedDescription.UTF8String);
        uint64_t value=0;zero=[g_dev newBufferWithBytes:&value length:sizeof value options:MTLResourceStorageModeShared];
        if(!zero)MDIE("Cannot allocate visibility prefix zero");res_add(zero);
    }
    NvVisPrefix *next=[NvVisPrefix new];next->buf=[g_dev newBufferWithLength:8 options:MTLResourceStorageModeShared];
    if(!next->buf)MDIE("Cannot allocate visibility prefix");res_add(next->buf);
    id<MTLBuffer> previous=g_vis_prefix?g_vis_prefix->buf:zero;
    uint64_t base=g_vis_base;
    // 同一提交通常只用一块槽缓冲；溢出时逐块折叠，每块之间保留后端的完整依赖屏障。
    // Normally one slot buffer is used per submit; fold overflow buffers separately with full backend barriers.
    for(int first=0;first<g_nvs;) {
        id<MTLBuffer> samples=(__bridge id<MTLBuffer>)g_vs[first].buf;
        int end=first+1;while(end<g_nvs && g_vs[end].buf==g_vs[first].buf)end++;
        id<MTLBuffer> indices,parameters;size_t io=arena_alloc((size_t)(end-first)*4,&indices),po=arena_alloc(16,&parameters);
        for(int i=first;i<end;i++)((uint32_t *)((uint8_t *)indices.contents+io))[i-first]=g_vs[i].slot;
        uint64_t values[]={base,(uint64_t)(end-first)};memcpy((uint8_t *)parameters.contents+po,values,sizeof values);
        CENC encoder=pg_compute();enc_c_pso(encoder,pipeline);
        enc_c_args(encoder,samples.gpuAddress,0);enc_c_args(encoder,previous.gpuAddress,1);
        enc_c_args(encoder,next->buf.gpuAddress,2);enc_c_args(encoder,indices.gpuAddress+io,3);enc_c_args(encoder,parameters.gpuAddress+po,4);
        enc_c_dispatch(encoder,MTLSizeMake(1,1,1),MTLSizeMake(1,1,1));enc_c_end(encoder);
        defer_obj_unref(samples);previous=next->buf;base=0;first=end;
    }
    // 前缀可能在本次编码后失去最后一份 CPU 引用，GPU 读完之前仍须保活。
    // The previous prefix may lose its last CPU reference after encoding; keep it alive until its GPU read finishes.
    defer_obj_unref(g_vis_prefix);
    vis_clear();g_vis_prefix=next;
}
