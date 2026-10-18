// Independent colour/depth pixels for public batch setters, including input
// mutation after recording, edge clipping, empty scissors and empty updates.
#include "../nvn/nvn_mtl.m"
#include "../nvn/hle_nvn.c"
#include "nvn_gpu_test_device.h"
#include "../../host/guest_bootstrap.h"
#include <limits.h>
uint64_t g_t0_ns;
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"viewport batch check failed at %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(int argc,char **argv){@autoreleasepool{
    if(argc==2) {
        int rectangles[8]={0,0,8,6,1,0,8,6};float ranges[4]={0,1,.25f,1};
        if(!strcmp(argv[1],"--nonuniform-scissors"))h_nvnCommandBufferSetScissors(NULL,0,2,rectangles);
        else if(!strcmp(argv[1],"--nonuniform-depth"))h_nvnCommandBufferSetDepthRanges(NULL,0,2,ranges);
        else if(!strcmp(argv[1],"--nonzero-scissor"))h_nvnCommandBufferSetScissors(NULL,1,1,rectangles);
        else if(!strcmp(argv[1],"--invalid-count"))h_nvnCommandBufferSetScissors(NULL,0,INT_MAX,rectangles);
        else if(!strcmp(argv[1],"--null-range"))h_nvnCommandBufferSetDepthRanges(NULL,0,1,NULL);
        return 1;
    }
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],.5,1);}\n"
      "fragment float4 f(){return float4(1,0,0,1);}";
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    prog_t program={.serial=1700000};NvProg *native=[NvProg new];
    native->sh[0]=[NvShader new];native->sh[0]->fn=[library newFunctionWithName:@"v"];
    native->sh[1]=[NvShader new];native->sh[1]->fn=[library newFunctionWithName:@"f"];native->sh[1]->stage=1;serial_put(program.serial,native);
    const struct {int n,r[4];float range[2],expected;} cases[]={
        {1,{0,0,8,6},{0,1},.5f},{2,{2,1,3,2},{.25f,.5f},.375f},
        {16,{-2,-1,5,4},{.5f,1},.75f},{1,{7,5,4,4},{.25f,.75f},.5f},
        {1,{0,0,0,6},{0,1},.5f}};
    for(unsigned c=0;c<sizeof cases/sizeof *cases;c++) {
        tex_t colour={.serial=1700100+c*2},depth={.serial=1700101+c*2};
        colour.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=6,.depth=1,.levels=1,.samples=1};
        depth.d=colour.d;depth.d.format=NVN_FORMAT_DEPTH32F;
        void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));memset(memory,0,65536);
        pool_t pool={.mem=memory,.size=65536};mtl_pool_add(memory,65536);NVNcommandBuffer cb;
        CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,0,65536);
        h_nvnCommandBufferBeginRecording(&cb);const NVNtexture *targets[]={(const NVNtexture *)&colour};
        h_nvnCommandBufferSetRenderTargets(&cb,1,targets,NULL,(const NVNtexture *)&depth,NULL);
        const float black[]={0,0,0,1};h_nvnCommandBufferClearColor(&cb,0,black,15);h_nvnCommandBufferClearDepthStencil(&cb,.125f,1,0,0);
        NVNdepthStencilState ds;h_nvnDepthStencilStateSetDefaults(&ds);h_nvnDepthStencilStateSetDepthTestEnable(&ds,1);
        h_nvnDepthStencilStateSetDepthWriteEnable(&ds,1);h_nvnDepthStencilStateSetDepthFunc(&ds,NVN_DEPTH_FUNC_ALWAYS);h_nvnCommandBufferBindDepthStencilState(&cb,&ds);
        h_nvnCommandBufferSetViewports(&cb,0,1,(float[]){0,0,8,6});
        int rectangles[16][4];float ranges[16][2];
        for(int i=0;i<cases[c].n;i++){memcpy(rectangles[i],cases[c].r,16);memcpy(ranges[i],cases[c].range,8);}
        h_nvnCommandBufferSetScissors(&cb,0,cases[c].n,rectangles[0]);h_nvnCommandBufferSetDepthRanges(&cb,0,cases[c].n,ranges[0]);
        h_nvnCommandBufferSetScissors(&cb,16,0,NULL);h_nvnCommandBufferSetDepthRanges(&cb,16,0,NULL);
        memset(rectangles,0,sizeof rectangles);memset(ranges,0,sizeof ranges);
        h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,3);h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        for(unsigned target=0;target<2;target++) {
            id<MTLBuffer> output=[g_dev newBufferWithLength:256*6 options:MTLResourceStorageModeShared];memset(output.contents,0xa7,256*6);
            id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
            [encoder copyFromTexture:tex_mtl(target?&depth:&colour) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,6,1)
               toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*6];
            [encoder endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
            for(int y=0;y<6;y++) {
                uint8_t *row=(uint8_t *)output.contents+y*256;
                for(int x=32;x<256;x++)CHECK(row[x]==0xa7);
                for(int x=0;x<8;x++) {
                    int inside=x>=cases[c].r[0] && y>=cases[c].r[1] && x<cases[c].r[0]+cases[c].r[2] && y<cases[c].r[1]+cases[c].r[3];
                    if(target)CHECK(*(float *)(row+x*4)==(inside?cases[c].expected:.125f));
                    else for(int k=0;k<4;k++)CHECK(row[x*4+k]==(k==3||(inside&&k==0)?255:0));
                }
            }
        }
        mtl_pool_del(memory);free(memory);
    }
    puts("VIEWPORT BATCH GPU OK: five colour/depth cases, snapshot mutation, empty updates and row guards");return 0;
}}
