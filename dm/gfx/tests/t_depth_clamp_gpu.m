// Public command recording -> production state replay/draw -> independent
// colour/depth readback for clipped and clamped near/far triangles.
#include "../nvn/nvn_mtl.m"
#include "../nvn/hle_nvn.c"
#include "nvn_gpu_test_device.h"
uint64_t g_t0_ns;
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"depth clamp check failed at %d\n",__LINE__);return 1;}}while(0)
static int readback(id<MTLTexture> texture,int colour,float depth) {
    id<MTLBuffer> buffer=[g_dev newBufferWithLength:256*6 options:MTLResourceStorageModeShared];
    memset(buffer.contents,0xa7,256*6);id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,6,1)
       toBuffer:buffer destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*6];
    [blit endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
    for(int y=0;y<6;y++)for(int x=0;x<256;x++) {
        uint8_t *row=(uint8_t *)buffer.contents+y*256;
        if(x>=32){CHECK(row[x]==0xa7);continue;}
        if(colour>=0){int channel=x%4;uint8_t expected=channel==3?255:channel==0&&colour?255:0;CHECK(row[x]==expected);}
        else if(x%4==0)CHECK(*(float *)(row+x)==depth);
    }
    return 0;
}
int main(void){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    setenv("DM_NVN_TBDR","0",1);mtl_init();NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "float4 pos(uint n,float z){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],z,1);}\n"
        "vertex float4 nearv(uint n[[vertex_id]]){return pos(n,-1);}\n"
        "vertex float4 midv(uint n[[vertex_id]]){return pos(n,.5);}\n"
        "vertex float4 farv(uint n[[vertex_id]]){return pos(n,2);}\n"
        "fragment float4 red(){return float4(1,0,0,1);}";
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    NSArray<NSString *> *names=@[@"nearv",@"midv",@"farv"];
    for(unsigned z=0;z<3;z++)for(unsigned clamp=0;clamp<2;clamp++) {
        uint64_t serial=920000+z*10+clamp*2;
        tex_t colour={.serial=serial},depth={.serial=serial+1};
        colour.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=6,.depth=1,.levels=1,.samples=1};
        depth.d=colour.d;depth.d.format=NVN_FORMAT_DEPTH32F;
        prog_t program={.serial=serial+100};NvProg *native=[NvProg new];
        native->sh[0]=[NvShader new];native->sh[0]->fn=[library newFunctionWithName:names[z]];
        native->sh[1]=[NvShader new];native->sh[1]->fn=[library newFunctionWithName:@"red"];native->sh[1]->stage=1;serial_put(program.serial,native);
        void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));memset(memory,0,65536);
        pool_t pool={.mem=memory,.size=65536};mtl_pool_add(memory,65536);NVNcommandBuffer cb;
        CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,0,65536);
        h_nvnCommandBufferBeginRecording(&cb);const NVNtexture *targets[]={(const NVNtexture *)&colour};
        h_nvnCommandBufferSetRenderTargets(&cb,1,targets,NULL,(const NVNtexture *)&depth,NULL);
        const float black[]={0,0,0,1};h_nvnCommandBufferClearColor(&cb,0,black,15);h_nvnCommandBufferClearDepthStencil(&cb,.25,1,0,0);
        NVNdepthStencilState ds;h_nvnDepthStencilStateSetDefaults(&ds);h_nvnDepthStencilStateSetDepthTestEnable(&ds,1);
        h_nvnDepthStencilStateSetDepthWriteEnable(&ds,1);h_nvnDepthStencilStateSetDepthFunc(&ds,NVN_DEPTH_FUNC_ALWAYS);h_nvnCommandBufferBindDepthStencilState(&cb,&ds);
        h_nvnCommandBufferSetDepthClamp(&cb,clamp?257:0);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,3);
        h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);
        state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        int visible=clamp||z==1;float expected=visible?(z==0?0:z==1?.5:1):.25;
        CHECK(!readback(tex_mtl(&colour),visible,0));CHECK(!readback(tex_mtl(&depth),-1,expected));
        mtl_pool_del(memory);free(memory);
    }
    puts("DEPTH CLAMP GPU OK: six public-command colour/depth cases and row guards");return 0;
}}
