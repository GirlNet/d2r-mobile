// Discard disables rasterization while retaining real vertex execution.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"raster discard check failed at %d\n",__LINE__);return 1;}}while(0)
int main(void){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "struct V {float4 p[[position]];};\nvertex V v(uint n[[vertex_id]],device atomic_uint *seen[[buffer(16)]]){"
      "atomic_fetch_or_explicit(seen,1u<<n,memory_order_relaxed);float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};V out={float4(p[n],.5,1)};return out;}\n"
      "fragment float4 f(){return float4(1,0,0,1);}";
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    prog_t program={.serial=995000};NvProg *native=[NvProg new];native->sh[0]=[NvShader new];native->sh[0]->fn=[library newFunctionWithName:@"v"];
    native->sh[0]->vertex_source=source;native->sh[0]->vertex_entry=@"v";
    native->sh[1]=[NvShader new];native->sh[1]->fn=[library newFunctionWithName:@"f"];native->sh[1]->stage=1;serial_put(program.serial,native);
    tex_t colour={.serial=995001},depth={.serial=995002};colour.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=1};
    depth.d=colour.d;depth.d.format=NVN_FORMAT_DEPTH32F;
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));memset(memory,0,65536);pool_t pool={.mem=memory,.size=65536};mtl_pool_add(memory,65536);
    NVNcommandBuffer cb;CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,0,32768);h_nvnCommandBufferBeginRecording(&cb);
    const NVNtexture *colours[]={(const NVNtexture *)&colour};h_nvnCommandBufferSetRenderTargets(&cb,1,colours,NULL,(const NVNtexture *)&depth,NULL);
    const float black[]={0,0,0,1};h_nvnCommandBufferClearColor(&cb,0,black,15);h_nvnCommandBufferClearDepthStencil(&cb,.25,1,0,0);
    NVNdepthStencilState ds;h_nvnDepthStencilStateSetDefaults(&ds);h_nvnDepthStencilStateSetDepthTestEnable(&ds,1);
    h_nvnDepthStencilStateSetDepthWriteEnable(&ds,1);h_nvnDepthStencilStateSetDepthFunc(&ds,NVN_DEPTH_FUNC_ALWAYS);h_nvnCommandBufferBindDepthStencilState(&cb,&ds);
    h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,3);
    const uint32_t enabled[]={257,0,1};
    for(unsigned i=0;i<3;i++) {
        NVNbufferRange range={(uintptr_t)memory+32768+i*4,4};h_nvnCommandBufferBindVertexBuffers(&cb,0,1,&range);
        h_nvnCommandBufferSetRasterizerDiscard(&cb,enabled[i]);h_nvnCommandBufferSetScissor(&cb,i==1?4:0,0,4,4);
        h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
    }
    NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
    for(unsigned i=0;i<3;i++)CHECK(((uint32_t *)((uint8_t *)memory+32768))[i]==7);
    for(unsigned target=0;target<2;target++) {
        id<MTLBuffer> output=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];memset(output.contents,0xa7,1024);
        id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
        [encoder copyFromTexture:tex_mtl(target?&depth:&colour) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1)
           toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
        [encoder endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
        for(unsigned y=0;y<4;y++) {
            uint8_t *row=(uint8_t *)output.contents+y*256;
            for(unsigned x=32;x<256;x++)CHECK(row[x]==0xa7);
            for(unsigned x=0;x<8;x++)if(target){CHECK(*(float *)(row+x*4)==(x<4?.25f:.5f));}
            else for(unsigned k=0;k<4;k++)CHECK(row[x*4+k]==(k==3||(x>=4&&k==0)?255:0));
        }
    }
    mtl_pool_del(memory);free(memory);puts("RASTER DISCARD GPU OK: enabled/disabled/enabled transitions, vertex side effects, colour/depth and guards");return 0;
}}
