// Public recording/replay, GPU-produced indices, separated strips and a valid
// 65535 vertex with 16-bit primitive restart disabled. No game shaders.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"primitive restart check failed at %d\n",__LINE__);return 1;}}while(0)
int main(void){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));setenv("DM_NVN_TBDR","1",1);mtl_init();NSError *error=nil;
    id<MTLLibrary> library=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
      "vertex float4 v(uint i[[vertex_id]]){uint n=i==65535?7:i;float2 p[8]={float2(-1,-1),float2(-1,1),float2(-.25,-1),float2(-.25,1),float2(.25,-1),float2(.25,1),float2(1,-1),float2(1,1)};return float4(p[n],.5,1);}\n"
      "fragment float4 f(){return float4(1,0,0,1);}" options:nil error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    const struct { int type,enabled;uint32_t marker; } cases[]={{0,1,255},{0,1,9},{1,1,65535},{1,1,9},{2,1,65535},{2,1,UINT32_MAX},{1,0,65535},{2,0,UINT32_MAX}};
    for(unsigned c=0;c<sizeof cases/sizeof *cases;c++) {
        tex_t colour={.serial=930000+c};colour.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=1};
        prog_t program={.serial=940000+c};NvProg *native=[NvProg new];native->sh[0]=[NvShader new];native->sh[0]->fn=[library newFunctionWithName:@"v"];
        native->sh[1]=[NvShader new];native->sh[1]->fn=[library newFunctionWithName:@"f"];native->sh[1]->stage=1;serial_put(program.serial,native);
        void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));memset(memory,0x53,65536);pool_t pool={.mem=memory,.size=65536};mtl_pool_add(memory,65536);
        unsigned width=1u<<cases[c].type,count=cases[c].enabled?9:4;
        uint32_t indices[]={0,1,2,3,cases[c].marker,4,5,6,7};if(!cases[c].enabled){indices[0]=4;indices[1]=5;indices[2]=6;indices[3]=65535;}
        for(unsigned i=0;i<count;i++)memcpy((uint8_t *)memory+32768+i*width,&indices[i],width);
        NVNcommandBuffer cb;CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,0,16384);h_nvnCommandBufferBeginRecording(&cb);
        const NVNtexture *targets[]={(const NVNtexture *)&colour};h_nvnCommandBufferSetRenderTargets(&cb,1,targets,NULL,NULL,NULL);
        const float black[]={0,0,0,1};h_nvnCommandBufferClearColor(&cb,0,black,15);
        h_nvnCommandBufferCopyBufferToBuffer(&cb,(uintptr_t)memory+32768,(uintptr_t)memory+33792,count*width,0);
        h_nvnCommandBufferSetPrimitiveRestart(&cb,cases[c].enabled?257:0,(int)cases[c].marker);
        h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,3);
        h_nvnCommandBufferDrawElementsInstanced(&cb,NVN_DRAW_PRIMITIVE_TRIANGLE_STRIP,(NVNindexType)cases[c].type,count,(uintptr_t)memory+33792,0,0,1);
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        id<MTLBuffer> output=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];memset(output.contents,0xa7,1024);
        id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
        [encoder copyFromTexture:tex_mtl(&colour) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1)
           toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];[encoder endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
        for(unsigned y=0;y<4;y++)for(unsigned x=0;x<256;x++) {
            unsigned pixel=x/4,channel=x%4;BOOL red=pixel>=5 || (cases[c].enabled && pixel<3);
            uint8_t expected=x>=32?0xa7:channel==3?255:channel==0&&red?255:0;
            CHECK(((uint8_t *)output.contents)[y*256+x]==expected);
        }
        CHECK(((uint8_t *)memory)[33791]==0x53&&((uint8_t *)memory)[33792+count*width]==0x53);
        mtl_pool_del(memory);free(memory);
    }
    puts("PRIMITIVE RESTART GPU OK: eight 8/16/32-bit, custom/fixed/disabled cases, prior GPU copy and guards");return 0;
}}
