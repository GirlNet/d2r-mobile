// Use production descriptor snapshots, view creation and cache invalidation with synthetic pixels.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"texture view GPU check failed at %d\n",__LINE__);return 1; } } while(0)

static id<MTLTexture> registered(int index) {
    pthread_mutex_lock(&g_rmu);id<MTLTexture> t=tex_by_id(index);pthread_mutex_unlock(&g_rmu);return t;
}
static int contract(id<MTLTexture> texture,unsigned type,unsigned numeric) {
    nvn_rbind binding={.kind=NVN_RB_TEX,.dtt=type,.dpf=numeric};
    return nvn_texture_binding_error(&binding,texture)==NULL;
}
static int read_pixel(id<MTLCommandQueue> q,id<MTLComputePipelineState> pipeline,id<MTLTexture> texture,float out[4]) {
    id<MTLBuffer> output=[g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    if (!output) return 0;
    float *values=output.contents;for(int i=0;i<8;i++)values[i]=-99;
    id<MTLCommandBuffer> command=[q commandBuffer];id<MTLComputeCommandEncoder> e=[command computeCommandEncoder];
    [e setComputePipelineState:pipeline];[e setTexture:texture atIndex:0];[e setBuffer:output offset:0 atIndex:0];
    [e dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[e endEncoding];[command commit];[command waitUntilCompleted];
    if (command.status!=MTLCommandBufferStatusCompleted) return 0;
    for(int i=4;i<8;i++)if(values[i]!=-99)return 0;
    memcpy(out,values,16);return 1;
}
int main(void) { @autoreleasepool {
    if (!MTLCreateSystemDefaultDevice()) return 77;
    mtl_init();id<MTLCommandQueue> q=[g_dev newCommandQueue];CHECK(q);
    NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "kernel void color(texture2d<float,access::read> t [[texture(0)]],device float4 *o [[buffer(0)]]) { o[0]=t.read(uint2(0),0); }\n"
      "kernel void depth(depth2d<float> t [[texture(0)]],device float4 *o [[buffer(0)]]) { o[0]=float4(t.read(uint2(0),0)); }\n"
      "kernel void stencil(texture2d<uint,access::read> t [[texture(0)]],device float4 *o [[buffer(0)]]) { o[0]=float4(t.read(uint2(0),0)); }";
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];
    if (!library) fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    id<MTLComputePipelineState> cp=[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"color"] error:&error];CHECK(cp);
    id<MTLComputePipelineState> dp=[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"depth"] error:&error];CHECK(dp);
    id<MTLComputePipelineState> sp=[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"stencil"] error:&error];CHECK(sp);
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:2 height:2 mipmapped:YES];
    d.textureType=MTLTextureType2DArray;d.arrayLength=2;d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
    id<MTLTexture> base=[g_dev newTextureWithDescriptor:d];CHECK(base);
    float pixels[16];for(int i=0;i<16;i++)pixels[i]=-7;
    for(int slice=0;slice<2;slice++) {
        [base replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 slice:slice withBytes:pixels bytesPerRow:32 bytesPerImage:64];
        const float last[4]={11,13,17,19};
        [base replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:1 slice:slice withBytes:last bytesPerRow:16 bytesPerImage:16];
    }
    tex_t t={.serial=800001};t.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D_ARRAY,.format=NVN_FORMAT_RGBA32F,.width=2,.height=2,.depth=2,.levels=2};
    t.sampling=(tex_sampling_t){.swizzle={4,3,2,1},.has_swizzle=1};serial_put(t.serial,base);
    view_t v={.set_levels=1,.base_level=1,.nlevels=1,.set_layers=1,.min_layer=1,.nlayers=1,.set_target=1,.target=NVN_TEXTURE_TARGET_2D};
    float out[4];mtl_reg_tex(9,&t,&v);
    CHECK(read_pixel(q,cp,registered(9),out));CHECK(out[0]==17 && out[1]==13 && out[2]==11 && out[3]==1);
    const float expected[6]={0,1,11,13,17,19};unsigned cases=0;
    for(unsigned r=0;r<6;r++)for(unsigned g=0;g<6;g++)for(unsigned b=0;b<6;b++)for(unsigned a=0;a<6;a++) { @autoreleasepool {
        v.set_swizzle=1;v.swizzle[0]=r;v.swizzle[1]=g;v.swizzle[2]=b;v.swizzle[3]=a;
        mtl_reg_tex(9,&t,&v);id<MTLTexture> sampled=registered(9);CHECK(sampled);
        CHECK(registered(9)==sampled);CHECK(read_pixel(q,cp,sampled,out));
        CHECK(out[0]==expected[r] && out[1]==expected[g] && out[2]==expected[b] && out[3]==expected[a]);cases++;
    } }
    // Registration snapshots the caller's view; later writes cannot change the descriptor.
    v.swizzle[0]=0;CHECK(read_pixel(q,cp,registered(9),out));CHECK(out[0]==19);
    // Replacing the base serial invalidates cached views and keeps the selected subresource.
    id<MTLTexture> replacement=[g_dev newTextureWithDescriptor:d];CHECK(replacement);
    const float changed[4]={23,29,31,37};[replacement replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:1 slice:1 withBytes:changed bytesPerRow:16 bytesPerImage:16];
    serial_put(t.serial,replacement);CHECK(read_pixel(q,cp,registered(9),out));CHECK(out[0]==37);
    d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
    id<MTLTexture> noalpha=[g_dev newTextureWithDescriptor:d];CHECK(noalpha);const uint8_t rgba[4]={1,2,3,7};[noalpha replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:rgba bytesPerRow:4];
    tex_t rgbx={.serial=800003};rgbx.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBX8,.width=1,.height=1,.depth=1,.levels=1};serial_put(rgbx.serial,noalpha);
    mtl_reg_tex(11,&rgbx,NULL);CHECK(read_pixel(q,cp,registered(11),out));CHECK(out[0]>0 && out[3]==1);
    view_t noalpha_view={.set_swizzle=1,.swizzle={5,2,0,1}};mtl_reg_tex(11,&rgbx,&noalpha_view);CHECK(read_pixel(q,cp,registered(11),out));CHECK(out[0]==1 && out[1]>0 && out[2]==0 && out[3]==1);
    d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:1 height:1 mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget|MTLTextureUsagePixelFormatView;
    id<MTLTexture> ds=[g_dev newTextureWithDescriptor:d];CHECK(ds);
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture=ds;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=.375;
    pass.stencilAttachment.texture=ds;pass.stencilAttachment.loadAction=MTLLoadActionClear;pass.stencilAttachment.storeAction=MTLStoreActionStore;pass.stencilAttachment.clearStencil=93;
    id<MTLCommandBuffer> command=[q commandBuffer];[[command renderCommandEncoderWithDescriptor:pass] endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
    tex_t depth={.serial=800002};depth.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_DEPTH32F_STENCIL8,.width=1,.height=1,.depth=1,.levels=1};depth.sampling.depth_mode=1;serial_put(depth.serial,ds);
    view_t aspect={0};mtl_reg_tex(10,&depth,&aspect);CHECK(registered(10).pixelFormat==MTLPixelFormatX32_Stencil8);CHECK(read_pixel(q,sp,registered(10),out));CHECK(out[0]==93);
    CHECK(contract(registered(10),MTLTextureType2D,NVN_DPF_UINT));
    CHECK(!contract(registered(10),MTLTextureType2D,NVN_DPF_FLOAT));
    CHECK(!contract(registered(10),MTLTextureType2D,NVN_DPF_DEPTH));
    aspect.set_depth_mode=1;aspect.depth_mode=0;mtl_reg_tex(10,&depth,&aspect);CHECK(read_pixel(q,dp,registered(10),out));CHECK(out[0]==.375f);
    CHECK(contract(registered(10),MTLTextureType2D,NVN_DPF_DEPTH));
    CHECK(!contract(registered(10),MTLTextureTypeCube,NVN_DPF_DEPTH));
    aspect.depth_mode=1;depth.sampling.depth_mode=0;mtl_reg_tex(10,&depth,&aspect);CHECK(read_pixel(q,sp,registered(10),out));CHECK(out[0]==93);
    printf("texture views GPU: %u swizzles, builder inheritance, view override, mip/layer, snapshots, cache replacement, depth/stencil and output guards passed\n",cases);
    return 0;
} }
