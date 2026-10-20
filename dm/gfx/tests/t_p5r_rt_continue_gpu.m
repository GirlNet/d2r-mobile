// 通过公开命令录制验证 P5R 同目标续用；独立读回颜色、深度、模板及行尾保护字节，不使用游戏内容。
// Verify P5R same-target continuation through public recording; independently read color, depth, stencil and row guards, without game content.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"P5R continuation check failed at %d: %s\n",__LINE__,#x);return 1;}}while(0)

enum { SAME, CLEAR, BARRIER_BEFORE, BARRIER_AFTER, UNKNOWN_BEFORE, UNKNOWN_AFTER,
       COPY, VIEW_CHANGE, REGISTRY_CHANGE, SAMPLE_ATTACHMENT, CASE_COUNT };
static const char *names[]={"same","clear","barrier-before","barrier-after","unknown-before",
    "unknown-after","copy","view-change","registry-change","sample-attachment"};

static int read_planes(tex_t *color,tex_t *depth,int cleared,int sampled) {
    id<MTLBuffer> output[3];
    id<MTLCommandBuffer> cb=[g_q commandBuffer];
    id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
    for(int k=0;k<3;k++) {
        output[k]=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];
        memset(output[k].contents,0xa7,1024);
        if(!k)[bl copyFromTexture:tex_mtl(color) sourceSlice:0 sourceLevel:0
            sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1)
            toBuffer:output[k] destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
        else [bl copyFromTexture:tex_mtl(depth) sourceSlice:0 sourceLevel:0
            sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1)
            toBuffer:output[k] destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024
            options:k==1?MTLBlitOptionDepthFromDepthStencil:MTLBlitOptionStencilFromDepthStencil];
    }
    [bl endEncoding];[cb commit];[cb waitUntilCompleted];
    CHECK(cb.status==MTLCommandBufferStatusCompleted);
    for(int y=0;y<4;y++)for(int x=0;x<8;x++) {
        uint8_t *c=(uint8_t *)output[0].contents+y*256+x*4;
        int second=cleared||x>=4;
        const uint8_t want[]={second&&!sampled?0:255,second&&!sampled?255:0,0,255};
        CHECK(!memcmp(c,want,4));
        CHECK(*(float *)((uint8_t *)output[1].contents+y*256+x*4)==(second?.75f:.5f));
        CHECK(*((uint8_t *)output[2].contents+y*256+x)==(second?0x66:0x55));
    }
    for(int k=0;k<3;k++)for(int y=0;y<4;y++)for(int x=k==2?8:32;x<256;x++)
        CHECK(*((uint8_t *)output[k].contents+y*256+x)==0xa7);
    return 0;
}

static int run_case(int scenario,prog_t *programs,int enabled) {
    tex_t color={.serial=2100100+scenario*3},depth={.serial=2100101+scenario*3};
    color.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,
        .width=8,.height=4,.depth=1,.levels=2,.samples=1};
    depth.d=color.d;depth.d.format=NVN_FORMAT_DEPTH32F_STENCIL8;depth.d.levels=1;
    CHECK(tex_mtl(&color)&&tex_mtl(&depth));
    // 提前建立资源，测试续用时的版本检查不受首次分配影响。
    // Materialize resources first so first allocation does not affect continuation version checks.
    mtl_reg_tex(1900,&color,NULL);
    if(scenario==SAMPLE_ATTACHMENT) {
        id<MTLTexture> t=tex_mtl(&color);
        id<MTLCommandBuffer> cb=[g_q commandBuffer];
        MTLRenderPassDescriptor *pd=[MTLRenderPassDescriptor renderPassDescriptor];
        pd.colorAttachments[0].texture=t;pd.colorAttachments[0].level=1;
        pd.colorAttachments[0].loadAction=MTLLoadActionClear;
        pd.colorAttachments[0].storeAction=MTLStoreActionStore;
        pd.colorAttachments[0].clearColor=MTLClearColorMake(1,0,0,1);
        [[cb renderCommandEncoderWithDescriptor:pd] endEncoding];[cb commit];[cb waitUntilCompleted];
        CHECK(cb.status==MTLCommandBufferStatusCompleted);
    }
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),131072));memset(memory,0,131072);
    pool_t pool={.mem=memory,.size=131072};mtl_pool_add(memory,131072);
    NVNcommandBuffer cmd;CHECK(h_nvnCommandBufferInitialize(&cmd,NULL));
    h_nvnCommandBufferAddCommandMemory(&cmd,(const NVNmemoryPool *)&pool,0,65536);
    h_nvnCommandBufferBeginRecording(&cmd);
    const NVNtexture *targets[]={(const NVNtexture *)&color};
    h_nvnCommandBufferSetRenderTargets(&cmd,1,targets,NULL,(const NVNtexture *)&depth,NULL);
    h_nvnCommandBufferClearColor(&cmd,0,(float[]){0,0,0,1},15);
    h_nvnCommandBufferClearDepthStencil(&cmd,.875,1,0x2d,255);
    NVNdepthStencilState ds;h_nvnDepthStencilStateSetDefaults(&ds);
    h_nvnDepthStencilStateSetDepthTestEnable(&ds,1);h_nvnDepthStencilStateSetDepthWriteEnable(&ds,1);
    h_nvnDepthStencilStateSetDepthFunc(&ds,NVN_DEPTH_FUNC_LESS);
    h_nvnDepthStencilStateSetStencilTestEnable(&ds,1);
    h_nvnDepthStencilStateSetStencilFunc(&ds,NVN_FACE_FRONT_AND_BACK,NVN_STENCIL_FUNC_ALWAYS);
    h_nvnDepthStencilStateSetStencilOp(&ds,NVN_FACE_FRONT_AND_BACK,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_REPLACE);
    h_nvnCommandBufferBindDepthStencilState(&cmd,&ds);
    h_nvnCommandBufferSetStencilRef(&cmd,NVN_FACE_FRONT_AND_BACK,0x55);
    h_nvnCommandBufferSetScissors(&cmd,0,1,(int[]){0,0,4,4});
    h_nvnCommandBufferBindProgram(&cmd,(const NVNprogram *)&programs[scenario==UNKNOWN_BEFORE?2:0],3);
    h_nvnCommandBufferDrawArrays(&cmd,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
    NVNcommandHandle first=h_nvnCommandBufferEndRecording(&cmd);
    h_nvnCommandBufferBeginRecording(&cmd);
    if(scenario==BARRIER_BEFORE)h_nvnCommandBufferBarrier(&cmd,1);
    if(scenario==COPY)h_nvnCommandBufferCopyTextureToBuffer(&cmd,(const NVNtexture *)&color,NULL,
        &(NVNcopyRegion){0,0,0,8,4,1},(uintptr_t)memory+65536,0);
    NVNtextureView view;h_nvnTextureViewSetDefaults(&view);
    h_nvnTextureViewSetLevels(&view,0,1);
    const NVNtextureView *views[]={&view};
    h_nvnCommandBufferSetRenderTargets(&cmd,1,targets,scenario==VIEW_CHANGE?views:NULL,(const NVNtexture *)&depth,NULL);
    if(scenario==BARRIER_AFTER)h_nvnCommandBufferBarrier(&cmd,1);
    h_nvnCommandBufferSetScissors(&cmd,0,1,(int[]){0,0,8,4});
    if(scenario==CLEAR) {
        h_nvnCommandBufferClearColor(&cmd,0,(float[]){0,0,1,1},15);
        h_nvnCommandBufferClearDepthStencil(&cmd,.875,1,0x2d,255);
    }
    h_nvnCommandBufferSetStencilRef(&cmd,NVN_FACE_FRONT_AND_BACK,0x66);
    int second_program=scenario==UNKNOWN_AFTER?3:scenario==SAMPLE_ATTACHMENT?4:1;
    h_nvnCommandBufferBindProgram(&cmd,(const NVNprogram *)&programs[second_program],3);
    if(scenario==SAMPLE_ATTACHMENT)h_nvnCommandBufferBindTexture(&cmd,NVN_SHADER_STAGE_FRAGMENT,0,1900);
    h_nvnCommandBufferDrawArrays(&cmd,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
    NVNcommandHandle second=h_nvnCommandBufferEndRecording(&cmd);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();
    uint64_t passes=g_stat_pass,draws=g_stat_draw,loads=g_bw_load,stores=g_bw_store;
    mtl_exec((const uint8_t *)first);
    CHECK(g_enc_mode==0);
    if(scenario==REGISTRY_CHANGE)mtl_reg_tex(1900,&color,NULL);
    mtl_exec((const uint8_t *)second);
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
    uint64_t want_passes=enabled&&scenario==SAME?1:2;
    CHECK(g_stat_pass-passes==want_passes);CHECK(g_stat_draw-draws==2);
    // 第一个通道用 Clear，续开的通道完整 Load；所有通道完整 Store。
    // The first pass uses Clear, reopened passes use full Load, and every pass uses full Store.
    CHECK(g_bw_store-stores==want_passes*8*4*9);
    CHECK(g_bw_load-loads==(scenario==CLEAR?0:(want_passes-1)*8*4*9));
    CHECK(!read_planes(&color,&depth,scenario==CLEAR,scenario==SAMPLE_ATTACHMENT));
    if(scenario==COPY)for(int y=0;y<4;y++)for(int x=0;x<8;x++) {
        const uint8_t expected[]={x<4?255:0,0,0,255};
        CHECK(!memcmp((uint8_t *)memory+65536+(y*8+x)*4,expected,4));
    }
    printf("P5R_CONTINUE case=%s enabled=%d passes=%llu pixels=ok\n",names[scenario],enabled,(unsigned long long)want_passes);
    h_nvnCommandBufferFinalize(&cmd);mtl_pool_del(memory);free(memory);
    return 0;
}

int main(void){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();
    mtl_guest_coordinates(NVN_WINDOW_ORIGIN_MODE_UPPER_LEFT,NVN_DEPTH_MODE_NEAR_IS_ZERO);
    int enabled=p5r_rt_continue_on();CHECK(!tbdr_on());
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],.5,1);}\n"
        "vertex float4 w(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],.75,1);}\n"
        "fragment float4 red(){return float4(1,0,0,1);}\nfragment float4 green(){return float4(0,1,0,1);}\n"
        "struct Args{texture2d<float> t[[id(0)]];};fragment float4 sampled(constant Args&a[[buffer(0)]]){return a.t.read(uint2(0),1);}\n";
    NSError *error=nil;id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error];
    if(!lib)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(lib);
    prog_t programs[5];
    for(int k=0;k<5;k++) {
        programs[k]=(prog_t){.serial=2100000+k};NvProg *p=[NvProg new];
        p->sh[0]=[NvShader new];p->sh[0]->fn=[lib newFunctionWithName:k==0||k==2?@"v":@"w"];
        p->sh[1]=[NvShader new];p->sh[1]->fn=[lib newFunctionWithName:k==4?@"sampled":k==0||k==2?@"red":@"green"];
        p->sh[1]->stage=1;p->sh[1]->rf.color_mask=1;
        // 测试着色器明确只读；两个负例故意保留未知元数据。
        // Test shaders are explicitly read-only; two negative cases deliberately leave metadata unknown.
        p->sh[0]->range_ro=p->sh[1]->range_ro=k!=2&&k!=3;
        if(k==4) {
            p->sh[1]->rf.nb=1;
            p->sh[1]->rf.b[0]=(nvn_rbind){.kind=NVN_RB_TEX,.dtt=MTLTextureType2D};
            p->sh[1]->ae=[p->sh[1]->fn newArgumentEncoderWithBufferIndex:0];
        }
        serial_put(programs[k].serial,p);
    }
    for(int k=0;k<CASE_COUNT;k++)CHECK(!run_case(k,programs,enabled));
    puts("P5R CONTINUATION GPU OK: 10 cases, full attachment stores, exact color/depth/stencil and row guards");
    return 0;
}}
