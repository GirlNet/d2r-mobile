// Public multisample draw/clear -> production downsample -> independent pixels.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"downsample check failed at %d\n",__LINE__);return 1;}}while(0)
int main(void){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nstruct V {float4 p[[position]];};\n"
      "vertex V v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return {float4(p[n],.5,1)};}\n"
      "fragment float4 f(uint sample[[sample_id]]){return sample?float4(0,1,0,1):float4(1,0,0,1);}";
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    unsigned checked=0;
    for(unsigned samples=2;samples<=4;samples*=2)if([g_dev supportsTextureSampleCount:samples])for(unsigned clear=0;clear<2;clear++) {
        unsigned c=samples*2+clear;prog_t program={.serial=998000+c};NvProg *native=[NvProg new];
        native->sh[0]=[NvShader new];native->sh[0]->fn=[library newFunctionWithName:@"v"];
        native->sh[1]=[NvShader new];native->sh[1]->fn=[library newFunctionWithName:@"f"];native->sh[1]->stage=1;serial_put(program.serial,native);
        tex_t textures[3]={0};for(unsigned i=0;i<3;i++) {
            textures[i].serial=999000+c*3+i;textures[i].d=(nvn_texdesc){.target=i?NVN_TEXTURE_TARGET_2D:NVN_TEXTURE_TARGET_2D_MULTISAMPLE,
              .format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=i?1:samples};
        }
        void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));memset(memory,0,65536);pool_t pool={.mem=memory,.size=65536};mtl_pool_add(memory,65536);
        NVNcommandBuffer cb;CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,0,65536);h_nvnCommandBufferBeginRecording(&cb);
        const NVNtexture *colours[]={(const NVNtexture *)&textures[0]};h_nvnCommandBufferSetRenderTargets(&cb,1,colours,NULL,NULL,NULL);
        const float value[]={.25,.5,.75,1};h_nvnCommandBufferClearColor(&cb,0,value,15);
        if(!clear) {
            NVNmultisampleState state;h_nvnMultisampleStateSetDefaults(&state);h_nvnMultisampleStateSetMultisampleEnable(&state,1);h_nvnMultisampleStateSetSamples(&state,samples);
            h_nvnCommandBufferBindMultisampleState(&cb,&state);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,3);
            h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
        }
        h_nvnCommandBufferDownsample(&cb,(const NVNtexture *)&textures[0],(const NVNtexture *)&textures[1]);
        h_nvnCommandBufferDownsample(&cb,(const NVNtexture *)&textures[0],(const NVNtexture *)&textures[2]);
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        for(unsigned target=1;target<3;target++) {
            id<MTLBuffer> output=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];memset(output.contents,0xa7,1024);
            id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
            [encoder copyFromTexture:tex_mtl(&textures[target]) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1)
               toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
            [encoder endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
            const int drawn[]={(int)(256/samples),(int)(256-256/samples),0,255},cleared[]={64,128,191,255};
            for(unsigned y=0;y<4;y++) {
                uint8_t *row=(uint8_t *)output.contents+y*256;for(unsigned x=32;x<256;x++)CHECK(row[x]==0xa7);
                for(unsigned x=0;x<32;x++)CHECK(abs((int)row[x]-(clear?cleared:drawn)[x%4])<=1);
            }
            checked++;
        }
        mtl_pool_del(memory);free(memory);
    }
    CHECK(checked);printf("DOWNSAMPLE GPU OK: %u per-sample/clear resolves, preserved multisample source and row guards\n",checked);return 0;
}}
