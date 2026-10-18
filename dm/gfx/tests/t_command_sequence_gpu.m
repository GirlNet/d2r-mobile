// Public thunks -> command arrays -> queue submission, including repeated
// internal fences and a report consumed by a later GPU copy in the same list.
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
static PFNNVNDEVICEGETPROCADDRESSPROC gpa;
static void *proc(const char *name){void *p=(void *)gpa(NULL,name);if(!p)abort();return p;}
#define P(name) ((NVNT_##name)proc(#name))
#define CHECK(x) do{if(!(x)){fprintf(stderr,"sequence check failed at %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(int argc,char **argv){@autoreleasepool{
    if(argc==2 && !strcmp(argv[1],"--bad-instances")){h_nvnCommandBufferDrawArraysInstanced(NULL,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3,0,-1);return 1;}
    if(argc==2 && !strcmp(argv[1],"--bad-point")){h_nvnCommandBufferSetPointSize(NULL,NAN);return 1;}
    if(argc==2 && !strcmp(argv[1],"--bad-sync")){NVNsync s={0};h_nvnCommandBufferWaitSync(NULL,&s);return 1;}
    if(argc==2 && !strcmp(argv[1],"--long-label")){char label[4098];memset(label,'x',4097);label[4097]=0;h_nvnCommandBufferPushDebugGroup(NULL,label);return 1;}
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();gpa=h_nvnBootstrapLoader("nvnDeviceGetProcAddress");
    state_reset();
    if(argc==2) {
        if(!strcmp(argv[1],"--wide-line")){S.dynamic.line_width=2;draw(&(p_draw){.prim=NVN_DRAW_PRIMITIVE_LINES,.count=2},NULL);}
        if(!strcmp(argv[1],"--point-size")){S.dynamic.point_size=2;draw(&(p_draw){.prim=NVN_DRAW_PRIMITIVE_POINTS,.count=1},NULL);}
        if(!strcmp(argv[1],"--subpixel")){S.dynamic.subpixel[0]=1;draw(&(p_draw){.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3},NULL);}
        if(!strcmp(argv[1],"--swizzle")){S.dynamic.swizzle[0]=1;draw(&(p_draw){.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3},NULL);}
        if(!strcmp(argv[1],"--report-range"))replay_report_value(&(p_report_value){.address=UINT64_MAX-15,.value=1});
        return 1;
    }
    NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "vertex float4 v(uint vid[[vertex_id]],uint iid[[instance_id]],device atomic_uint *seen[[buffer(16)]]){"
      "atomic_fetch_or_explicit(seen+iid,1u<<vid,memory_order_relaxed);"
      "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[vid%3],.5,1);}\n"
      "vertex float4 q(uint vid[[vertex_id]],uint iid[[instance_id]],device atomic_uint *seen[[buffer(16)]]){"
      "atomic_fetch_or_explicit(seen+iid,1u<<vid,memory_order_relaxed);"
      "float2 p[4]={float2(-1,-1),float2(1,-1),float2(1,1),float2(-1,1)};return float4(p[vid%4],.5,1);}\n"
      "fragment float4 f(){return float4(1,0,0,1);}";
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    prog_t programs[2]={{.serial=1800000},{.serial=1800001}};
    for(unsigned q=0;q<2;q++){NvProg *native=[NvProg new];native->sh[0]=[NvShader new];native->sh[0]->fn=[library newFunctionWithName:q?@"q":@"v"];
        native->sh[1]=[NvShader new];native->sh[1]->fn=[library newFunctionWithName:@"f"];native->sh[1]->stage=1;serial_put(programs[q].serial,native);}
    const struct{int first,count,instances,base,quad,disabled;} cases[]={
        {3,3,2,4,0,0},{0,3,0,2,0,0},{0,4,3,1,1,0},{0,0,4,0,0,0},{6,3,1,9,0,0},{0,3,2,0,0,1}};
    for(unsigned c=0;c<sizeof cases/sizeof *cases;c++) {
        void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),131072));memset(memory,0,131072);
        pool_t pool={.mem=memory,.size=131072};mtl_pool_add(memory,131072);
        uint32_t *seen=(uint32_t *)((uint8_t *)memory+16384);uint8_t *report=(uint8_t *)memory+32768,*output=(uint8_t *)memory+36864;
        memset(report-16,0xa7,64);memset(output-16,0xa7,64);
        void *native_buffer=NULL;uint64_t offset=0,gpu=0;
        CHECK(!mtl_addr(UINT64_MAX-15,16,&native_buffer,&offset));CHECK(!mtl_gpu_addr(UINT64_MAX-15,32,&native_buffer,&offset,&gpu));
        tex_t colour={.serial=1800100+c};colour.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=1};
        NVNqueueBuilder qb={0};NVNqueue queue;P(nvnQueueBuilderSetDefaults)(&qb);CHECK(P(nvnQueueInitialize)(&queue,&qb));
        NVNsync ready,finished;CHECK(P(nvnSyncInitialize)(&ready,NULL));CHECK(P(nvnSyncInitialize)(&finished,NULL));
        NVNcommandBuffer cb;CHECK(P(nvnCommandBufferInitialize)(&cb,NULL));P(nvnCommandBufferAddCommandMemory)(&cb,(const NVNmemoryPool *)&pool,65536,65536);
        P(nvnCommandBufferBeginRecording)(&cb);
        char dynamic_group[]="dynamic.scope",legacy_group[]="legacy.scope",marker[]="copied.marker";
        P(nvnCommandBufferPushDebugGroupStatic)(&cb,7,"static.scope");P(nvnCommandBufferPushDebugGroupDynamic)(&cb,7,dynamic_group);
        P(nvnCommandBufferPushDebugGroup)(&cb,legacy_group);
        P(nvnCommandBufferInsertDebugMarkerStatic)(&cb,3,"upload");P(nvnCommandBufferInsertDebugMarkerDynamic)(&cb,7,"draw");
        P(nvnCommandBufferInsertDebugMarker)(&cb,marker);
        const NVNtexture *targets[]={(const NVNtexture *)&colour};P(nvnCommandBufferSetRenderTargets)(&cb,1,targets,NULL,NULL,NULL);
        P(nvnCommandBufferClearColor)(&cb,0,(float[]){0,0,0,1},15);P(nvnCommandBufferSetViewports)(&cb,0,1,(float[]){0,0,8,4});
        P(nvnCommandBufferSetScissors)(&cb,0,1,(int[]){0,0,8,4});P(nvnCommandBufferSetDepthRanges)(&cb,0,1,(float[]){0,1});
        NVNcolorState colour_state;P(nvnColorStateSetDefaults)(&colour_state);
        P(nvnColorStateSetLogicOp)(&colour_state,NVN_LOGIC_OP_XOR);P(nvnColorStateSetAlphaTest)(&colour_state,NVN_ALPHA_FUNC_NEVER);
        P(nvnCommandBufferBindColorState)(&cb,&colour_state);
        P(nvnColorStateSetLogicOp)(&colour_state,NVN_LOGIC_OP_COPY);P(nvnColorStateSetAlphaTest)(&colour_state,NVN_ALPHA_FUNC_ALWAYS);
        P(nvnCommandBufferBindColorState)(&cb,&colour_state);
        P(nvnCommandBufferSetPointSize)(&cb,2);P(nvnCommandBufferSetLineWidth)(&cb,3);P(nvnCommandBufferSetAlphaRef)(&cb,.375f);
        P(nvnCommandBufferSetConservativeRasterDilate)(&cb,.25f);P(nvnCommandBufferSetSubpixelPrecisionBias)(&cb,1,1);
        P(nvnCommandBufferSetSubpixelPrecisionBias)(&cb,0,0);
        NVNviewportSwizzle swizzles[4]={1,2,4,6};P(nvnCommandBufferSetViewportSwizzles)(&cb,0,1,swizzles);
        swizzles[0]=0;P(nvnCommandBufferSetViewportSwizzles)(&cb,0,1,swizzles);swizzles[0]=7;
        P(nvnCommandBufferSetViewportSwizzles)(&cb,16,0,NULL);
        P(nvnCommandBufferSetTiledCacheTileSize)(&cb,32,32);
        for(int action=1;action<=6;action++)P(nvnCommandBufferSetTiledCacheAction)(&cb,(NVNtiledCacheAction)action);
        P(nvnCommandBufferBindProgram)(&cb,(const NVNprogram *)&programs[cases[c].quad],3);
        P(nvnCommandBufferBindVertexBuffers)(&cb,0,1,&(NVNbufferRange){(uintptr_t)seen,64});
        P(nvnCommandBufferSetRenderEnable)(&cb,cases[c].disabled?0:1);
        P(nvnCommandBufferDrawArraysInstanced)(&cb,cases[c].quad?NVN_DRAW_PRIMITIVE_QUADS:NVN_DRAW_PRIMITIVE_TRIANGLES,
            cases[c].first,cases[c].count,cases[c].base,cases[c].instances);
        P(nvnCommandBufferDrawElementsInstanced)(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,NVN_INDEX_TYPE_UNSIGNED_INT,3,UINT64_MAX,0,0,0);
        P(nvnCommandBufferSetRenderEnable)(&cb,1);P(nvnCommandBufferSetTiledCacheAction)(&cb,NVN_TILED_CACHE_ACTION_FLUSH);
        P(nvnCommandBufferReportValue)(&cb,0xf1234000u+c,(uintptr_t)report);
        P(nvnCommandBufferCopyBufferToBuffer)(&cb,(uintptr_t)report,(uintptr_t)output,16,0);
        P(nvnCommandBufferFenceSync)(&cb,&ready,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,1);
        P(nvnCommandBufferWaitSync)(&cb,&ready);
        P(nvnCommandBufferFenceSync)(&cb,&finished,NVN_SYNC_CONDITION_GRAPHICS_WORLD_SPACE_COMPLETE,0);
        NVNcommandHandle handle=P(nvnCommandBufferEndRecording)(&cb);
        memset(dynamic_group,'x',sizeof dynamic_group-1);memset(legacy_group,'x',sizeof legacy_group-1);memset(marker,'x',sizeof marker-1);
        CHECK(P(nvnSyncWait)(&finished,0)==NVN_SYNC_WAIT_RESULT_TIMEOUT_EXPIRED);
        state_reset();memset(&R,0,sizeof R);P(nvnQueueSubmitCommands)(&queue,1,&handle);P(nvnQueueFinish)(&queue);
        CHECK(!mtl_last_commit_error());CHECK(P(nvnSyncWait)(&finished,5000000000ull)!=NVN_SYNC_WAIT_RESULT_TIMEOUT_EXPIRED);
        CHECK(((sync_t *)&ready)->fence<((sync_t *)&finished)->fence);
        CHECK(([(g_debug_groups[@7]) isEqualToArray:@[@"static.scope",@"dynamic.scope"]]));
        CHECK([(g_debug_groups[@0]) isEqualToArray:@[@"legacy.scope"]]);CHECK([g_debug_marker containsString:@"copied.marker"]);
        CHECK(S.dynamic.alpha_ref==.375f && S.dynamic.conservative_dilate==.25f && S.dynamic.tile_size[0]==32);
        CHECK(S.color.logic_op==NVN_LOGIC_OP_COPY && S.color.alpha_func==NVN_ALPHA_FUNC_ALWAYS);
        for(unsigned i=0;i<16;i++) {
            uint32_t expected=0;
            if(!cases[c].disabled && cases[c].count && i>=cases[c].base && i<cases[c].base+cases[c].instances)
                for(int v=cases[c].first;v<cases[c].first+cases[c].count;v++)expected|=1u<<v;
            CHECK(seen[i]==expected);
        }
        uint64_t value,timestamp;memcpy(&value,report,8);memcpy(&timestamp,report+8,8);
        CHECK(value==0xf1234000u+c && timestamp>0);CHECK(!memcmp(report,output,16));
        for(int i=-16;i<48;i++)if(i<0 || i>=16)CHECK(report[i]==0xa7 && output[i]==0xa7);
        id<MTLBuffer> pixels=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];memset(pixels.contents,0xa7,1024);
        id<MTLCommandBuffer> read=[g_q commandBuffer];id<MTLBlitCommandEncoder> blit=[read blitCommandEncoder];
        [blit copyFromTexture:tex_mtl(&colour) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1)
            toBuffer:pixels destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
        [blit endEncoding];[read commit];[read waitUntilCompleted];CHECK(read.status==MTLCommandBufferStatusCompleted);
        int visible=!cases[c].disabled && cases[c].count && cases[c].instances;
        for(int y=0;y<4;y++)for(int x=0;x<256;x++) {
            uint8_t got=((uint8_t *)pixels.contents)[y*256+x];
            CHECK(got==(x>=32?0xa7:x%4==3 || (visible && x%4==0)?255:0));
        }
        P(nvnCommandBufferBeginRecording)(&cb);P(nvnCommandBufferPopDebugGroupId)(&cb,7);P(nvnCommandBufferPopDebugGroupId)(&cb,7);
        P(nvnCommandBufferPopDebugGroup)(&cb);P(nvnCommandBufferInsertDebugMarkerStatic)(&cb,3,"sequence.complete");
        handle=P(nvnCommandBufferEndRecording)(&cb);P(nvnQueueSubmitCommands)(&queue,1,&handle);P(nvnQueueFinish)(&queue);
        CHECK(!g_debug_groups.count && strstr(cctx_snap(),"sequence.complete"));
        P(nvnCommandBufferFinalize)(&cb);P(nvnSyncFinalize)(&ready);P(nvnSyncFinalize)(&finished);P(nvnQueueFinalize)(&queue);
        mtl_pool_del(memory);free(memory);
    }
    puts("COMMAND SEQUENCE GPU OK: six instancing/empty/conditional cases; 20 API extensions, repeated fences, report-to-GPU copy, copied debug scopes and byte guards");return 0;
}}
