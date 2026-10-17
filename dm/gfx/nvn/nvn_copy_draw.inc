// Adapted from seedds/nxnative, commit 280ead98ea731cb5138be6cd0e472cdc2341582d.
// Copyright (c) 2026 jhaizhou. MIT license: see repository LICENSE.
// Changes: Metal 3 binding, bounded regions/layers, preflight allocation, and
// strict stencil preservation (a missing stencil view never becomes a clear).
static int fmt_int_or_ds(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
        case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint:
        case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatDepth16Unorm: case MTLPixelFormatDepth32Float: case MTLPixelFormatStencil8:
        case MTLPixelFormatDepth32Float_Stencil8: case MTLPixelFormatX32_Stencil8: return 1;
        default: return 0;
    }
}
static int copy_t2t_draw(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror) {
    static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *pso; static id<MTLFunction> vf, ff, fd, fds; static id<MTLSamplerState> samp[2]; M4_ONLY(static id<MTL4ArgumentTable> at;) static id<MTLDepthStencilState> dss, dss_s; static int failed;
    if (failed || sr->width <= 0 || sr->height <= 0 || dr->width <= 0 || dr->height <= 0) return 0;
    int depth = (s.pixelFormat == MTLPixelFormatDepth32Float || s.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) && d.pixelFormat == s.pixelFormat, stencil = depth && d.pixelFormat == MTLPixelFormatDepth32Float_Stencil8;
    if (!depth && (fmt_int_or_ds(s.pixelFormat) || fmt_int_or_ds(d.pixelFormat))) return 0;
    if (!(d.usage & MTLTextureUsageRenderTarget) || s.sampleCount > 1 || d.sampleCount > 1) return 0;
    if ((s.textureType!=MTLTextureType2D && s.textureType!=MTLTextureType2DArray) ||
        (d.textureType!=MTLTextureType2D && d.textureType!=MTLTextureType2DArray) || s==d ||
        sl>=s.mipmapLevelCount || dl>=d.mipmapLevelCount || sr->xoffset<0 || sr->yoffset<0 || dr->xoffset<0 || dr->yoffset<0 ||
        sr->zoffset<0 || dr->zoffset<0) return 0;
    NSUInteger sw=MAX(s.width>>sl,1ul),sh=MAX(s.height>>sl,1ul),dw=MAX(d.width>>dl,1ul),dh=MAX(d.height>>dl,1ul);
    NSUInteger sn=s.textureType==MTLTextureType2DArray?s.arrayLength:1,dn=d.textureType==MTLTextureType2DArray?d.arrayLength:1;
    unsigned nz=sr->depth?sr->depth:1;
    if(sr->depth<0 || dr->depth<0 || nz!=(unsigned)(dr->depth?dr->depth:1) ||
       (NSUInteger)sr->xoffset>sw || (NSUInteger)sr->width>sw-sr->xoffset || (NSUInteger)sr->yoffset>sh || (NSUInteger)sr->height>sh-sr->yoffset ||
       (NSUInteger)dr->xoffset>dw || (NSUInteger)dr->width>dw-dr->xoffset || (NSUInteger)dr->yoffset>dh || (NSUInteger)dr->height>dh-dr->yoffset ||
       ss>sn || (NSUInteger)sr->zoffset>sn-ss || nz>sn-ss-sr->zoffset || ds>dn || (NSUInteger)dr->zoffset>dn-ds || nz>dn-ds-dr->zoffset) return 0;
    if (!pso) {
        static const char *src =
            "#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; };\n"
            "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); return o; }\n"
            // p[0] = source origin (texels) + source texels per destination texel, p[1] = destination origin + source level size
            "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float4 *p [[buffer(0)]]) {\n"
            "  float2 st = p[0].xy + (in.p.xy - p[1].xy) * p[0].zw; return t.sample(s, st / p[1].zw, level(0)); }\n"
            "struct D { float d [[depth(any)]]; };\n"
            "fragment D fsd(V in [[stage_in]], depth2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float4 *p [[buffer(0)]]) {\n"
            "  float2 st = p[0].xy + (in.p.xy - p[1].xy) * p[0].zw; D o; o.d = t.read(uint2(st)); return o; }\n"
            "struct DS { float d [[depth(any)]]; uint s [[stencil]]; };\n"
            "fragment DS fsds(V in [[stage_in]], depth2d<float> t [[texture(0)]], texture2d<uint> ts [[texture(1)]], constant float4 *p [[buffer(0)]]) {\n"
            "  float2 st = p[0].xy + (in.p.xy - p[1].xy) * p[0].zw; DS o; o.d = t.read(uint2(st)); o.s = ts.read(uint2(st)).r; return o; }\n";
        MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(src) options:options error:&e];
        vf = [lib newFunctionWithName:@"vs"]; ff = [lib newFunctionWithName:@"fs"]; fd = [lib newFunctionWithName:@"fsd"]; fds = [lib newFunctionWithName:@"fsds"];
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES; dss = [g_dev newDepthStencilStateWithDescriptor:dd];
        MTLStencilDescriptor *sd_ = [MTLStencilDescriptor new]; sd_.stencilCompareFunction = MTLCompareFunctionAlways; sd_.depthStencilPassOperation = MTLStencilOperationReplace;   // Replace writes the [[stencil]] output
        dd.frontFaceStencil = dd.backFaceStencil = sd_; dss_s = [g_dev newDepthStencilStateWithDescriptor:dd];
#if !DM_NVN_M3
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxTextureBindCount = 2; ad.maxSamplerStateBindCount = 1; ad.maxBufferBindCount = 1; at = [g_dev newArgumentTableWithDescriptor:ad error:&e];
#endif
        for (int i = 0; i < 2; i++) { MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = i ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
            sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge; sd.supportArgumentBuffers = YES; samp[i] = [g_dev newSamplerStateWithDescriptor:sd]; }
        if (!vf || !ff || !fd || !fds || !dss || !dss_s || M4_ONLY(!at ||) !samp[0] || !samp[1]) { failed = 1; MLOG("【红】换格式 / 缩放贴图拷贝的管线建不出：%s", e.localizedDescription.UTF8String); return 0; }
        pso = [NSMutableDictionary dictionary];
    }
    // Stencil export is mandatory for combined depth/stencil copies.
    id<MTLTexture> stv0 = stencil && s.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ? [s newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8 textureType:MTLTextureType2D levels:NSMakeRange(sl, 1) slices:NSMakeRange(ss + sr->zoffset, 1)] : nil;
    if(stencil && !stv0)return 0;
    int scopy = stencil;
    NSNumber *pk = @(d.pixelFormat * 2 + scopy);
    id<MTLRenderPipelineState> ps = pso[pk];
    if (!ps) {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = vf; pd.fragmentFunction = depth ? (scopy ? fds : fd) : ff;
        if (depth) { pd.depthAttachmentPixelFormat = d.pixelFormat; if (stencil) pd.stencilAttachmentPixelFormat = d.pixelFormat; } else pd.colorAttachments[0].pixelFormat = d.pixelFormat;
        NSError *e = nil; ps = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!ps) { RED_ONCE(48, "换格式 / 缩放贴图拷贝：目标格式 %lu 的管线建不出：%s", (unsigned long)d.pixelFormat, e.localizedDescription.UTF8String); return 0; }
        pso[pk] = ps;
    }
    NSMutableArray<id<MTLTexture>> *views=[NSMutableArray array],*stencils=[NSMutableArray array];
    for(unsigned z=0;z<nz;z++) {
        id<MTLTexture> sv=[s newTextureViewWithPixelFormat:s.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(sl,1) slices:NSMakeRange(ss+sr->zoffset+z,1)];
        id<MTLTexture> stv=stencil?(z?[s newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8 textureType:MTLTextureType2D levels:NSMakeRange(sl,1) slices:NSMakeRange(ss+sr->zoffset+z,1)]:stv0):nil;
        if(!sv || (stencil&&!stv))return 0;
        [views addObject:sv];if(stv)[stencils addObject:stv];
    }
    id<MTLBuffer> pb=[g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];if(!pb)return 0;
        float *p = pb.contents; p[0] = sr->xoffset; p[1] = sr->yoffset; p[2] = (float)sr->width / dr->width; p[3] = (float)sr->height / dr->height;
        if (mirror & NVN_COPY_FLAGS_MIRROR_X_BIT) { p[0] += sr->width; p[2] = -p[2]; }   // mirrored: walk the source region from its far edge
        if (mirror & NVN_COPY_FLAGS_MIRROR_Y_BIT) { p[1] += sr->height; p[3] = -p[3]; }
        p[4] = dr->xoffset; p[5] = dr->yoffset; p[6] = sw; p[7] = sh;
        res_add(pb);
    rp_end();if(g_blit){enc_b_end(g_blit);g_blit=nil;}
    for(unsigned z=0;z<nz;z++) {
        id<MTLTexture> sv=views[z],stv=stencil?stencils[z]:nil;
        RPD *rp = [RPD new];
        MTLRenderPassAttachmentDescriptor *a = depth ? (MTLRenderPassAttachmentDescriptor *)rp.depthAttachment : (MTLRenderPassAttachmentDescriptor *)rp.colorAttachments[0];
        a.texture = d; a.level = dl; a.slice = ds + dr->zoffset + z; a.loadAction = MTLLoadActionLoad; a.storeAction = MTLStoreActionStore;
        if (stencil) { MTLRenderPassStencilAttachmentDescriptor *st = rp.stencilAttachment; st.texture = d; st.level = dl; st.slice = a.slice; st.loadAction = MTLLoadActionLoad; st.storeAction = MTLStoreActionStore; }
        ser_gate(); RENC en = enc_r_begin(rp);
        if (depth) [en setDepthStencilState:scopy ? dss_s : dss];
#if DM_NVN_M3
        [en setFragmentTexture:sv atIndex:0];if(stv)[en setFragmentTexture:stv atIndex:1];
        [en setFragmentSamplerState:samp[!!linear&&!depth] atIndex:0];[en setFragmentBuffer:pb offset:0 atIndex:0];
#else
        [en setArgumentTable:at atStages:MTLRenderStageFragment];
        [at setTexture:sv.gpuResourceID atIndex:0]; if (stv) [at setTexture:stv.gpuResourceID atIndex:1]; [at setSamplerState:samp[!!linear && !depth].gpuResourceID atIndex:0]; [at setAddress:pb.gpuAddress atIndex:0];
#endif
        [en setViewport:(MTLViewport){dr->xoffset, dr->yoffset, dr->width, dr->height, 0, 1}];
        [en setScissorRect:(MTLScissorRect){(NSUInteger)dr->xoffset, (NSUInteger)dr->yoffset, (NSUInteger)dr->width, (NSUInteger)dr->height}];
        [en setRenderPipelineState:ps]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; enc_r_end(en);
        defer_obj_unref(sv); if (stv) defer_obj_unref(stv);   // released after this submission has run
    }
    defer_obj_release(pb);
    args_dirty_all(); g_pso_dirty = g_dss_dirty = 1;
    { static int once[2]; if (!once[depth]++) MLOG("换格式 / 缩放贴图拷贝：首例 %dx%d 格式 %lu → %dx%d 格式 %lu%s%s", sr->width, sr->height, (unsigned long)s.pixelFormat, dr->width, dr->height, (unsigned long)d.pixelFormat,
                                                    linear && !depth ? "（双线性）" : "", stencil ? "（深度 + 模板）" : ""); }
    return 1;
}
