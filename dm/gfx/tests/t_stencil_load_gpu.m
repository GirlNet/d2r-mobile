// Synthetic public draws/dispatches exercise the production stencil variant,
// descriptor snapshots, pipeline selection, argument reuse and exact bit reads.
#include "../nvn/nvn_mtl.m"
#include "../nvn/hle_nvn.c"
#include "nvn_gpu_test_device.h"
#include "../../host/guest_bootstrap.h"
uint64_t g_t0_ns;
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"stencil load GPU check failed at %d\n",__LINE__);return 1;}}while(0)
static int clear_aspects(id<MTLTexture> ds,unsigned stencil) {
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture=ds;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=.375;
    pass.stencilAttachment.texture=ds;pass.stencilAttachment.loadAction=MTLLoadActionClear;pass.stencilAttachment.storeAction=MTLStoreActionStore;pass.stencilAttachment.clearStencil=stencil;
    id<MTLCommandBuffer> command=[g_q commandBuffer];[[command renderCommandEncoderWithDescriptor:pass] endEncoding];[command commit];[command waitUntilCompleted];
    return command.status==MTLCommandBufferStatusCompleted;
}
int main(int argc,char **argv){@autoreleasepool{
    int available=nvn_gpu_test_device();if(available)return available;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();NSError *error=nil;
    mtl_guest_coordinates(NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT,NVN_DEPTH_MODE_NEAR_IS_ZERO);
    const char *failure=argc>1?argv[1]:"";
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "struct Args{texture2d<float> t[[id(0)]];device uint4 *out[[id(1)]];};\n"
      "vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],.5,1);}\n"
      "fragment float4 f(constant Args &a[[buffer(0)]],float4 pos[[position]]){if(all(uint2(pos.xy)==uint2(1,0))){"
      "uint2 size=uint2(a.t.get_width(),a.t.get_height());a.out[0]=as_type<uint4>(a.t.read(size-uint2(1),0));}return float4(1,0,0,1);}\n"
      "kernel void k(constant Args &a[[buffer(0)]]){a.out[0]=as_type<uint4>(a.t.read(uint2(0),0));}\n"
      "fragment float4 blue(){return float4(0,0,1,1);}";
    if(!strcmp(failure,"--sample"))source=[source stringByReplacingOccurrencesOfString:@"a.t.read(uint2(0),0)" withString:@"a.t.sample(sampler(coord::normalized),float2(.5))"];
    MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:options error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    NvProg *native=[NvProg new];prog_t program={.serial=1970000};
    NSString *entries[]={@"v",@"f",@"k"};unsigned stages[]={0,1,5};
    for(unsigned i=0;i<3;i++) {
        NvShader *shader=[NvShader new];shader->stage=stages[i];shader->fn=[library newFunctionWithName:entries[i]];CHECK(shader->fn);
        native->sh[stages[i]]=shader;if(!i)continue;
        NSDictionary *json=@{@"route":@"B",@"stage":i==1?@"ps":@"cs",@"threadgroup_size":@[@1,@1,@1],@"bindings":@[
          @{@"kind":@"tex_combined",@"reg":@0,@"arg_id":@0,@"msl_type":@"texture2d<float>"},
          @{@"kind":@"sbuf",@"reg":@0,@"arg_id":@1,@"rw":@YES}]};
        char reason[160];CHECK(!nvn_refl_from_json(json,&shader->rf,reason,sizeof reason));shader->rf.guarded_candidate=1;
        shader->ae=[shader->fn newArgumentEncoderWithBufferIndex:0];shader->arg_len=shader->ae.encodedLength;CHECK(shader->ae&&shader->arg_len==16);
        shader->resource_source=source;shader->resource_entry=entries[i];
        if(i==1){shader->fragment_source=source;shader->fragment_entry=entries[i];}
    }
    serial_put(program.serial,native);
    prog_t warm={.serial=1970003};NvProg *warm_native=[NvProg new];warm_native->sh[0]=native->sh[0];
    warm_native->sh[1]=[NvShader new];warm_native->sh[1]->stage=1;warm_native->sh[1]->fn=[library newFunctionWithName:@"blue"];CHECK(warm_native->sh[1]->fn);serial_put(warm.serial,warm_native);
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:2 height:2 mipmapped:NO];
    // The phone creates these without PixelFormatView. First sampling must
    // preserve their pixels through an on-demand GPU copy, before encoding use.
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    tex_t depth={.serial=1970001};depth.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_DEPTH32F_STENCIL8,.width=2,.height=2,.depth=1,.levels=1,.samples=1};
    tex_t target={.serial=1970002};target.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=2,.height=2,.depth=1,.levels=1,.samples=1};
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),131072));mtl_pool_add(memory,131072);memset(memory,0xa7,131072);
    pool_t pool={.magic=MAGIC('P','O','O','L'),.mem=memory,.size=131072};NVNcommandBuffer cb;
    CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,65536,65536);
    state_reset();memset(&R,0,sizeof R);const unsigned values[]={93,1,0,255};unsigned cases=0;
    for(unsigned mode=0;mode<2;mode++)for(unsigned n=0;n<8;n++) {
        if(!n){id<MTLTexture> fresh=[g_dev newTextureWithDescriptor:d];CHECK(fresh);res_add(fresh);serial_put(depth.serial,fresh);}
        unsigned stencil=values[n/2];int aspect=(n%2)==0;CHECK(clear_aspects(tex_mtl(&depth),stencil));
        // RRR1 matches the real guest descriptor; its alpha must contain uint
        // bits 1, not the floating-point representation of numeric 1.0.
        view_t view={.set_depth_mode=1,.depth_mode=aspect,.set_swizzle=1,.swizzle={2,2,2,1}};
        mtl_reg_tex(315,&depth,&view);view.depth_mode=!aspect;view.swizzle[0]=0; // snapshot must survive caller mutation
        h_nvnCommandBufferBeginRecording(&cb);
        if(!cases)h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,NVN_SHADER_STAGE_VERTEX_BIT|NVN_SHADER_STAGE_FRAGMENT_BIT|NVN_SHADER_STAGE_COMPUTE_BIT);
        unsigned stage=mode?5:1;h_nvnCommandBufferBindTexture(&cb,(NVNshaderStage)stage,0,nvn_combined_handle(315,0));
        h_nvnCommandBufferBindStorageBuffer(&cb,(NVNshaderStage)stage,0,(uintptr_t)memory+cases*32,16);
        if(mode)h_nvnCommandBufferDispatchCompute(&cb,1,1,1);
        else {
            const NVNtexture *targets[]={(const NVNtexture *)&target};h_nvnCommandBufferSetRenderTargets(&cb,1,targets,NULL,NULL,NULL);
            h_nvnCommandBufferSetViewport(&cb,0,0,2,2);
            if(!cases) {
                // Leave a live render encoder before first sampling upgrades
                // the source. Its left column must survive the encoder split.
                h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&warm,NVN_SHADER_STAGE_VERTEX_BIT|NVN_SHADER_STAGE_FRAGMENT_BIT);
                h_nvnCommandBufferSetScissor(&cb,0,0,1,2);h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
                h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,NVN_SHADER_STAGE_VERTEX_BIT|NVN_SHADER_STAGE_FRAGMENT_BIT);
            }
            h_nvnCommandBufferSetScissor(&cb,!cases?1:0,0,!cases?1:2,2);
            h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
        }
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        uint32_t *out=(uint32_t *)((uint8_t *)memory+cases*32);
        if(aspect)CHECK(out[0]==stencil&&out[1]==stencil&&out[2]==stencil&&out[3]==1);
        else CHECK(out[0]==0x3ec00000); // 0.375 depth bits, with no stale stencil variant
        for(unsigned i=4;i<8;i++)CHECK(out[i]==0xa7a7a7a7);cases++;
        if(cases==1) {
            id<MTLBuffer> pixels=[g_dev newBufferWithLength:512 options:MTLResourceStorageModeShared];memset(pixels.contents,0xa7,512);
            id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
            [blit copyFromTexture:tex_mtl(&target) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(2,2,1)
                toBuffer:pixels destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:512];
            [blit endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
            const uint8_t expected[8]={0,0,255,255,255,0,0,255};
            for(unsigned y=0;y<2;y++) {
                const uint8_t *row=(const uint8_t *)pixels.contents+y*256;
                printf("PREPARATION PIXELS row=%u rgba=%u,%u,%u,%u;%u,%u,%u,%u passes=%llu draws=%llu\n",y,row[0],row[1],row[2],row[3],row[4],row[5],row[6],row[7],(unsigned long long)g_stat_pass,(unsigned long long)g_stat_draw);
                CHECK(!memcmp(row,expected,8));for(unsigned x=8;x<256;x++)CHECK(row[x]==0xa7);
            }
        }
    }
    CHECK(native->sh[1]->rf.b[0].dpf==NVN_DPF_FLOAT&&native->sh[5]->rf.b[0].dpf==NVN_DPF_FLOAT);
    CHECK(native->sh[1]->resource_variants.count==1&&native->sh[5]->resource_variants.count==1);
    CHECK(g_pfv_upgrades==2);
    for(unsigned i=cases*8;i<65536/4;i++)CHECK(((uint32_t *)memory)[i]==0xa7a7a7a7);
    mtl_pool_del(memory);free(memory);
    printf("STENCIL LOAD GPU OK: %u public draw/dispatch cases, 0/1/93/255 exact bits, RRR1 swizzle, depth rebinding, variant cache and output guards\n",cases);
    puts("TEXTURE PREPARATION GPU OK: two on-demand view upgrades before draw/dispatch, active-pass split preserves pixels and row guards");return 0;
}}
