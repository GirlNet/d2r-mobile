// 合成背景经过公开 NVN 绘制反复扭曲，验证颜色反馈副本、透明度、视图与有界复用；不含游戏像素或着色器。
// Repeatedly distort synthetic backgrounds through public NVN draws, checking color feedback snapshots, alpha, views and bounded reuse; no game pixels or shaders.
#include "../nvn/nvn_mtl.m"
#include "../nvn/hle_nvn.c"
#include "nvn_gpu_test_device.h"
#include "../../host/guest_bootstrap.h"
#include <math.h>
uint64_t g_t0_ns;
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"color feedback check failed at %d: %s\n",__LINE__,#x);return 1;}}while(0)

static id<MTLLibrary> library;
static unsigned case_count;
static float quantize(float value,int half){return half?value:roundf(value*255)/255;}
static void initial(float result[4],unsigned x,unsigned y,int clear,int half) {
    const float background[]={.25,.5,.75,.125};
    float pattern[]={(x%8+1)/16.f,(y%4+1)/8.f,.25,.5};
    for(int k=0;k<4;k++)result[k]=quantize(clear?background[k]:pattern[k],half);
}
static int read_pixels(id<MTLTexture> texture,unsigned selected_level,unsigned selected_slice,
                       int swizzle,int clear,int separate) {
    int half=texture.pixelFormat==MTLPixelFormatRGBA16Float,bgra=texture.pixelFormat==MTLPixelFormatBGRA8Unorm;
    unsigned bpp=half?8:4;
    for(unsigned layer=0;layer<texture.arrayLength;layer++)for(unsigned level=0;level<texture.mipmapLevelCount;level++) {
        unsigned width=MAX(texture.width>>level,1u),height=MAX(texture.height>>level,1u);
        unsigned pitch=((width*bpp+255)/256+1)*256;
        id<MTLBuffer> output=[g_dev newBufferWithLength:(NSUInteger)pitch*height+32 options:MTLResourceStorageModeShared];CHECK(output);
        memset(output.contents,0xa7,output.length);
        id<MTLCommandBuffer> cb=[g_q commandBuffer];id<MTLBlitCommandEncoder> encoder=[cb blitCommandEncoder];
        [encoder copyFromTexture:texture sourceSlice:layer sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(width,height,1) toBuffer:output destinationOffset:0 destinationBytesPerRow:pitch
            destinationBytesPerImage:(NSUInteger)pitch*height];
        [encoder endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(cb.status==MTLCommandBufferStatusCompleted);
        for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++) {
            float expected[4];for(int k=0;k<4;k++)expected[k]=quantize(.875,half);
            if(layer==selected_slice && level==selected_level) {
                initial(expected,(x+(separate?1:3))%width,y,clear,half);
                if(swizzle){float swap[4];memcpy(swap,expected,sizeof swap);for(int k=0;k<4;k++)expected[k]=swap[3-k];}
            }
            const uint8_t *bytes=(const uint8_t *)output.contents+y*pitch+x*bpp;
            for(int k=0;k<4;k++) {
                float actual=half?(float)((const __fp16 *)bytes)[k]:bytes[bgra&&k<3?2-k:k]/255.f;
                if(!isfinite(actual)||fabsf(actual-expected[k])>.002f) {
                    fprintf(stderr,"case%u layer%u level%u pixel%u,%u c%d got%g expected%g\n",case_count,layer,level,x,y,k,actual,expected[k]);return 1;
                }
            }
        }
        const uint8_t *bytes=output.contents;
        for(unsigned y=0;y<height;y++)for(unsigned x=width*bpp;x<pitch;x++)CHECK(bytes[y*pitch+x]==0xa7);
        for(unsigned i=0;i<32;i++)CHECK(bytes[(NSUInteger)pitch*height+i]==0xa7);
    }
    return 0;
}
static void record_target(NVNcommandBuffer *command,tex_t *texture,unsigned level,unsigned slice) {
    NVNtextureView view;h_nvnTextureViewSetDefaults(&view);h_nvnTextureViewSetLevels(&view,level,1);h_nvnTextureViewSetLayers(&view,slice,1);
    const NVNtexture *targets[]={(const NVNtexture *)texture};const NVNtextureView *views[]={&view};
    h_nvnCommandBufferSetRenderTargets(command,1,targets,views,NULL,NULL);
    h_nvnCommandBufferSetViewport(command,0,0,MAX(texture->d.width>>level,1u),MAX(texture->d.height>>level,1u));
}
static int one_case(int format,MTLPixelFormat metal,unsigned width,unsigned height,unsigned level,unsigned slice,int swizzle,int clear,int separate) {
    case_count++;
    NvProg *producer=[NvProg new],*effect=[NvProg new];
    producer->sh[0]=[NvShader new];producer->sh[0]->stage=0;producer->sh[0]->fn=[library newFunctionWithName:@"v"];
    producer->sh[1]=[NvShader new];producer->sh[1]->stage=1;producer->sh[1]->fn=[library newFunctionWithName:@"pattern"];
    effect->sh[0]=producer->sh[0];effect->sh[1]=[NvShader new];NvShader *fragment=effect->sh[1];
    fragment->stage=1;fragment->fn=[library newFunctionWithName:@"distort"];
    CHECK(producer->sh[0]->fn && producer->sh[1]->fn && fragment->fn);
    NSDictionary *reflection=@{@"route":@"B",@"stage":@"ps",@"bindings":@[
        @{@"kind":@"tex_combined",@"reg":@0,@"arg_id":@0,@"msl_type":@"texture2d<float>"},
        @{@"kind":@"tex_combined",@"reg":@1,@"arg_id":@1,@"msl_type":@"texture2d<float>"}]};
    char error[160];CHECK(!nvn_refl_from_json(reflection,&fragment->rf,error,sizeof error));
    fragment->ae=[fragment->fn newArgumentEncoderWithBufferIndex:0];CHECK(fragment->ae);fragment->arg_len=fragment->ae.encodedLength;
    prog_t pp={.serial=2100000+case_count*4},ep={.serial=2100001+case_count*4};serial_put(pp.serial,producer);serial_put(ep.serial,effect);
    tex_t source={.serial=2100002+case_count*4},destination={.serial=2100003+case_count*4};
    source.d=(nvn_texdesc){.target=slice?NVN_TEXTURE_TARGET_2D_ARRAY:NVN_TEXTURE_TARGET_2D,.format=format,
        .width=width,.height=height,.depth=slice?3:1,.levels=level?2:1,.samples=1};destination.d=source.d;
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:metal width:width height:height mipmapped:level!=0];
    d.textureType=slice?MTLTextureType2DArray:MTLTextureType2D;d.arrayLength=source.d.depth;d.mipmapLevelCount=source.d.levels;
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
    id<MTLTexture> base=[g_dev newTextureWithDescriptor:d];CHECK(base);res_add(base);serial_put(source.serial,base);
    id<MTLTexture> output=separate?[g_dev newTextureWithDescriptor:d]:base;CHECK(output);
    if(separate){res_add(output);serial_put(destination.serial,output);}
    view_t view={.set_levels=1,.base_level=level,.nlevels=1,.set_layers=1,.min_layer=slice,.nlayers=1,
        .set_target=1,.target=NVN_TEXTURE_TARGET_2D};
    if(swizzle){view.set_swizzle=1;view.swizzle[0]=5;view.swizzle[1]=4;view.swizzle[2]=3;view.swizzle[3]=2;}
    mtl_reg_tex(1600,&source,&view);
    pthread_mutex_lock(&g_rmu);id<MTLTexture> sampled=tex_by_id(1600);pthread_mutex_unlock(&g_rmu);CHECK(sampled);
    CHECK(color_feedback_overlap(sampled,base,level,slice));
    if(level)CHECK(!color_feedback_overlap(sampled,base,0,slice));
    if(slice)CHECK(!color_feedback_overlap(sampled,base,level,0));
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));memset(memory,0,65536);mtl_pool_add(memory,65536);
    pool_t pool={.magic=MAGIC('P','O','O','L'),.mem=memory,.size=65536};NVNcommandBuffer command;
    CHECK(h_nvnCommandBufferInitialize(&command,NULL));h_nvnCommandBufferAddCommandMemory(&command,(NVNmemoryPool *)&pool,0,65536);
    state_reset();memset(&R,0,sizeof R);h_nvnCommandBufferBeginRecording(&command);
    const float guard[]={.875,.875,.875,.875},background[]={.25,.5,.75,.125};
    for(int target=0;target<=separate;target++)for(unsigned sl=0;sl<source.d.depth;sl++)for(unsigned lv=0;lv<source.d.levels;lv++) {
        record_target(&command,target?&destination:&source,lv,sl);h_nvnCommandBufferClearColor(&command,0,guard,15);
    }
    record_target(&command,&source,level,slice);
    if(clear)h_nvnCommandBufferClearColor(&command,0,background,15);
    else {h_nvnCommandBufferBindProgram(&command,(NVNprogram *)&pp,3);h_nvnCommandBufferDrawArrays(&command,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);}
    if(separate)record_target(&command,&destination,level,slice);
    h_nvnCommandBufferBindProgram(&command,(NVNprogram *)&ep,3);
    for(int slot=0;slot<2;slot++)h_nvnCommandBufferBindTexture(&command,NVN_SHADER_STAGE_FRAGMENT,slot,nvn_combined_handle(1600,0));
    for(int iteration=0;iteration<3;iteration++)h_nvnCommandBufferDrawArrays(&command,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
    NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&command);uint64_t before=g_color_feedback_copies;
    unsigned cached_before=0;for(unsigned i=0;i<16;i++)cached_before+=g_color_feedback_slots[i].texture!=nil;
    mtl_sub_begin();mtl_exec((const uint8_t *)handle);CHECK(mtl_wait(mtl_sub_commit(),10000000000ull));CHECK(!mtl_last_commit_error());
    CHECK(g_color_feedback_copies-before==(separate?0:3));
    CHECK(!read_pixels(output,level,slice,swizzle,clear,separate));
    unsigned cached=0;for(unsigned i=0;i<16;i++)cached+=g_color_feedback_slots[i].texture!=nil;
    CHECK(cached<=16 && cached<=cached_before+(separate?0:1));
    h_nvnCommandBufferFinalize(&command);mtl_pool_del(memory);free(memory);
    printf("COLOR_FEEDBACK case=%u format=%d size=%ux%u level=%u slice=%u swizzle=%d clear=%d separate=%d copies=%llu cached=%u pixels/alpha/guards=ok\n",
        case_count,format,width,height,level,slice,swizzle,clear,separate,(unsigned long long)(g_color_feedback_copies-before),cached);
    return 0;
}
int main(void){@autoreleasepool{
    int available=nvn_gpu_test_device();if(available)return available;CHECK(dm_guest_profile_select("p5r"));mtl_init();
    mtl_guest_coordinates(NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT,NVN_DEPTH_MODE_NEAR_IS_ZERO);
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct A{texture2d<float> first[[id(0)]];texture2d<float> second[[id(1)]];};\n"
        "vertex float4 v(uint i[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],0,1);}\n"
        "fragment float4 pattern(float4 p[[position]]){return float4((uint(p.x)%8+1)/16.f,(uint(p.y)%4+1)/8.f,.25,.5);}\n"
        "fragment float4 distort(float4 p[[position]],constant A &a[[buffer(0)]]){uint2 q((uint(p.x)+1)%a.first.get_width(),uint(p.y));return .5*(a.first.read(q)+a.second.read(q));}";
    NSError *error=nil;MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;
    library=[g_dev newLibraryWithSource:source options:options error:&error];if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    CHECK(!one_case(NVN_FORMAT_RGBA8,MTLPixelFormatRGBA8Unorm,32,16,0,0,0,0,0));
    CHECK(!one_case(NVN_FORMAT_RGBA16F,MTLPixelFormatRGBA16Float,1440,810,0,0,0,0,0));
    CHECK(!one_case(NVN_FORMAT_RGBA16F,MTLPixelFormatRGBA16Float,32,16,1,1,0,0,0));
    CHECK(!one_case(NVN_FORMAT_BGRA8,MTLPixelFormatBGRA8Unorm,32,16,0,0,1,0,0));
    CHECK(!one_case(NVN_FORMAT_RGBA8,MTLPixelFormatRGBA8Unorm,32,16,0,0,0,1,0));
    CHECK(!one_case(NVN_FORMAT_RGBA8,MTLPixelFormatRGBA8Unorm,32,16,0,0,0,0,1));
    puts("COLOR FEEDBACK GPU OK: six public draw cases, repeated background offsets, HDR/alpha, mip/layer/swizzle, pending clears, duplicate binding isolation, nonalias fast path and bounded scratch reuse");return 0;
}}
