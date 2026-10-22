// Reproduce simultaneous public submissions while another thread owns the
// backend, then check queue-local state with independent GPU pixels/counters.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"queue concurrency check failed at %d: %s\n",__LINE__,#x);return 1;}}while(0)
enum { WORKERS=4, ROUNDS=16 };
typedef struct { NVNqueue *queue,*other;NVNcommandHandle handle;NVNsync done;_Atomic int returned; } worker;
static void *submit_worker(void *arg){@autoreleasepool{
    worker *w=arg;
    for(int i=0;i<ROUNDS;i++) {
        P(nvnQueueSubmitCommands)(w->queue,1,&w->handle);
        P(nvnQueueFenceSync)(w->queue,&w->done,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
        if(!P(nvnQueueWaitSync)(w->other,&w->done))abort();
    }
    P(nvnQueueFinish)(w->queue);atomic_store(&w->returned,1);return NULL;
}}
// GPU 被外部事件挡住时，带遮挡计数的提交也必须能返回；退出前无条件解除事件并回收线程。
// A visibility-counting submit must return while an external event blocks the GPU; always unblock and join before exit.
typedef struct { NVNqueue *queue;NVNcommandHandle handle;_Atomic int returned; } gated_submit;
static void *gated_submit_worker(void *arg){@autoreleasepool{
    gated_submit *w=arg;P(nvnQueueSubmitCommands)(w->queue,1,&w->handle);atomic_store(&w->returned,1);return NULL;
}}
static int submit_behind_gate(NVNqueue *queue,NVNcommandHandle handle) {
    id<MTLSharedEvent> gate=[g_dev newSharedEvent];CHECK(gate);
#if DM_NVN_M3
    id<MTLCommandBuffer> command=[g_q commandBuffer];[command encodeWaitForEvent:gate value:1];[command commit];
#else
    [g_q4 waitForEvent:gate value:1];
#endif
    gated_submit w={.queue=queue,.handle=handle};pthread_t thread;
    int started=!pthread_create(&thread,NULL,gated_submit_worker,&w);
    int returned=0;
    if(started) {
        for(int i=0;i<5000;i++){returned=atomic_load(&w.returned);if(returned)break;usleep(1000);}
    }
    gate.signaledValue=1;
    if(started)pthread_join(thread,NULL);
    CHECK(started);CHECK(returned);
    puts("ASYNC VISIBILITY SUBMIT OK: public submit returned before blocked GPU was released");return 0;
}
static int concurrent_submit(void) {
    size_t size=1024*1024;uint8_t *memory=NULL;CHECK(!posix_memalign((void **)&memory,getpagesize(),size));memset(memory,0xa7,size);
    pool_t pool={.magic=MAGIC('P','O','O','L'),.flags=0x22,.mem=memory,.size=size};mtl_pool_add(memory,size);
    _Alignas(8) NVNdevice device={0};((dev_t_ *)&device)->magic=MAGIC('D','E','V',0);
    _Alignas(8) NVNbuffer address_views[WORKERS];
    NVNqueueBuilder qb={0};NVNqueue queues[2];P(nvnQueueBuilderSetDefaults)(&qb);
    for(int i=0;i<2;i++)CHECK(P(nvnQueueInitialize)(&queues[i],&qb));
    NSError *error=nil;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],.5,1);}\nfragment float4 f(){return float4(1,0,0,1);}" options:nil error:&error];CHECK(lib);
    prog_t program={.serial=1900030};NvProg *native=[NvProg new];native->sh[0]=[NvShader new];native->sh[0]->fn=[lib newFunctionWithName:@"v"];
    native->sh[1]=[NvShader new];native->sh[1]->fn=[lib newFunctionWithName:@"f"];native->sh[1]->stage=1;serial_put(program.serial,native);
    tex_t textures[WORKERS]={0};
    NVNcommandBuffer commands[WORKERS];NVNsync internal[WORKERS];worker workers[WORKERS]={0};pthread_t threads[WORKERS];
    for(int i=0;i<WORKERS;i++) {
        uint8_t *src=memory+i*4096,*dst=src+1024,*report=src+2048;
        for(int j=0;j<256;j++)src[j]=(uint8_t)(i*31+j*17+9);
        memcpy(src+512,(uint16_t[]){0,1,2},6);
        _Alignas(8) NVNbufferBuilder builder={0};P(nvnBufferBuilderSetDefaults)(&builder);P(nvnBufferBuilderSetDevice)(&builder,&device);
        P(nvnBufferBuilderSetStorage)(&builder,(NVNmemoryPool *)&pool,i*4096+512,0);
        CHECK(P(nvnBufferInitialize)(&address_views[i],&builder));
        NVNbufferAddress index_address=P(nvnBufferGetAddress)(&address_views[i]);
        CHECK(index_address==(uintptr_t)(src+512) && P(nvnBufferGetSize)(&address_views[i])==0);
        P(nvnBufferFlushMappedRange)(&address_views[i],0,6);
        textures[i].serial=1900040+i;textures[i].d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=1};
        CHECK(P(nvnCommandBufferInitialize)(&commands[i],NULL));P(nvnCommandBufferAddCommandMemory)(&commands[i],(const NVNmemoryPool *)&pool,65536+i*65536,65536);
        CHECK(P(nvnSyncInitialize)(&internal[i],NULL));CHECK(P(nvnSyncInitialize)(&workers[i].done,NULL));
        workers[i].queue=&queues[i%2];workers[i].other=&queues[(i+1)%2];
        P(nvnCommandBufferBeginRecording)(&commands[i]);
        const NVNtexture *targets[]={(const NVNtexture *)&textures[i]};P(nvnCommandBufferSetRenderTargets)(&commands[i],1,targets,NULL,NULL,NULL);
        P(nvnCommandBufferSetScissor)(&commands[i],0,0,8,4);P(nvnCommandBufferSetViewport)(&commands[i],0,0,8,4);
        P(nvnCommandBufferClearColor)(&commands[i],0,(float[]){0,0,0,1},15);P(nvnCommandBufferBindProgram)(&commands[i],(const NVNprogram *)&program,3);
        P(nvnCommandBufferDrawArraysInstanced)(&commands[i],NVN_DRAW_PRIMITIVE_TRIANGLES,0,3,0,2);
        P(nvnCommandBufferDrawElementsInstanced)(&commands[i],NVN_DRAW_PRIMITIVE_TRIANGLES,NVN_INDEX_TYPE_UNSIGNED_SHORT,3,index_address,0,0,2);
        P(nvnCommandBufferCopyBufferToBuffer)(&commands[i],(uintptr_t)src,(uintptr_t)dst,256,0);
        P(nvnCommandBufferReportValue)(&commands[i],0xcafe0000u+i,(uintptr_t)report);
        P(nvnCommandBufferFenceSync)(&commands[i],&internal[i],NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
        P(nvnCommandBufferWaitSync)(&commands[i],&internal[i]);
        workers[i].handle=P(nvnCommandBufferEndRecording)(&commands[i]);
    }
    // Deterministic overlap: all four public calls reach gfx_enter while this
    // thread holds an active Metal encoding scope. They must wait, not abort.
    queue_api_enter();mtl_sub_begin();mtl_sub_copy((uintptr_t)memory,(uintptr_t)(memory+32768),256);
    for(int i=0;i<WORKERS;i++)CHECK(!pthread_create(&threads[i],NULL,submit_worker,&workers[i]));
    uint64_t deadline=bp_now()+5000000000ull;int entered=0;
    do {pthread_mutex_lock(&g_susp_mu);entered=g_inflight_api;pthread_mutex_unlock(&g_susp_mu);if(entered==WORKERS)break;usleep(1000);}while(bp_now()<deadline);
    CHECK(entered==WORKERS);for(int i=0;i<WORKERS;i++)CHECK(!atomic_load(&workers[i].returned));
    CHECK(g_cb && on_sub_thread());mtl_sub_commit();CHECK(!atomic_load(&g_sub_owner));queue_api_leave();
    for(int i=0;i<WORKERS;i++)CHECK(!pthread_join(threads[i],NULL));
    CHECK(!mtl_last_commit_error() && !atomic_load(&g_sub_owner));CHECK(!memcmp(memory,memory+32768,256));
    for(int i=0;i<WORKERS;i++) {
        uint8_t *src=memory+i*4096,*dst=src+1024,*report=src+2048;uint64_t value,time;
        memcpy(&value,report,8);memcpy(&time,report+8,8);CHECK(value==0xcafe0000u+i && time>0);CHECK(!memcmp(src,dst,256));
        for(int j=-16;j<272;j++)if(j<0 || j>=256)CHECK(dst[j]==0xa7);
        for(int j=-16;j<32;j++)if(j<0 || j>=16)CHECK(report[j]==0xa7);
        CHECK(((sync_t *)&workers[i].done)->fenced && atomic_load(&workers[i].returned));
        id<MTLBuffer> output=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];memset(output.contents,0xa7,1024);
        id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> b=[command blitCommandEncoder];
        [b copyFromTexture:tex_mtl(&textures[i]) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1) toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
        [b endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
        for(int y=0;y<4;y++)for(int x=0;x<256;x++)CHECK(((uint8_t *)output.contents)[y*256+x]==(x>=32?0xa7:x%4==0 || x%4==3?255:0));
        P(nvnCommandBufferFinalize)(&commands[i]);P(nvnSyncFinalize)(&internal[i]);P(nvnSyncFinalize)(&workers[i].done);
        P(nvnBufferFinalize)(&address_views[i]);
    }
    for(int i=0;i<2;i++){CHECK(((queue_t *)&queues[i])->submits==2*ROUNDS);P(nvnQueueFinalize)(&queues[i]);CHECK(!((queue_t *)&queues[i])->replay_state);}
    for(int i=0;i<WORKERS;i++)mtl_tex_release(&textures[i]);mtl_prog_release(&program);
    mtl_pool_del(memory);free(memory);return 0;
}
static int queue_state_pixels(void) {
    NSError *error=nil;NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],.5,1);}\n"
      "fragment float4 red(){return float4(1,0,0,1);}\nfragment float4 green(){return float4(0,1,0,1);}";
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:source options:nil error:&error];CHECK(lib);
    uint8_t *memory=NULL;CHECK(!posix_memalign((void **)&memory,getpagesize(),262144));memset(memory,0xa7,262144);
    pool_t pool={.magic=MAGIC('P','O','O','L'),.flags=0x22,.mem=memory,.size=262144};mtl_pool_add(memory,262144);
    NVNqueueBuilder qb={0};NVNqueue queues[2];NVNcommandBuffer cb[2];prog_t programs[2]={{.serial=1900001},{.serial=1900002}},vertex={.serial=1900003};tex_t textures[2]={0};
    NvProg *vertexNative=[NvProg new];vertexNative->sh[0]=[NvShader new];vertexNative->sh[0]->fn=[lib newFunctionWithName:@"v"];serial_put(vertex.serial,vertexNative);
    P(nvnQueueBuilderSetDefaults)(&qb);
    for(int i=0;i<2;i++) {
        NvProg *native=[NvProg new];
        native->sh[1]=[NvShader new];native->sh[1]->fn=[lib newFunctionWithName:i?@"green":@"red"];native->sh[1]->stage=1;serial_put(programs[i].serial,native);
        textures[i].serial=1900010+i;textures[i].d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=1};
        CHECK(P(nvnQueueInitialize)(&queues[i],&qb));CHECK(P(nvnCommandBufferInitialize)(&cb[i],NULL));P(nvnCommandBufferAddCommandMemory)(&cb[i],(const NVNmemoryPool *)&pool,65536+i*65536,65536);
        P(nvnCommandBufferBeginRecording)(&cb[i]);P(nvnCommandBufferPushDebugGroupStatic)(&cb[i],7,i?"queue.green":"queue.red");
        const NVNtexture *targets[]={(const NVNtexture *)&textures[i]};P(nvnCommandBufferSetRenderTargets)(&cb[i],1,targets,NULL,NULL,NULL);
        P(nvnCommandBufferClearColor)(&cb[i],0,(float[]){0,0,0,1},15);P(nvnCommandBufferSetViewport)(&cb[i],0,0,8,4);
        P(nvnCommandBufferSetScissor)(&cb[i],i*4,0,4,4);P(nvnCommandBufferBindProgram)(&cb[i],(const NVNprogram *)&vertex,1);
        P(nvnCommandBufferBindProgram)(&cb[i],(const NVNprogram *)&programs[i],2);
        P(nvnCommandBufferResetCounter)(&cb[i],NVN_COUNTER_TYPE_SAMPLES_PASSED);
        P(nvnCommandBufferDrawArrays)(&cb[i],NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
        P(nvnCommandBufferReportCounter)(&cb[i],NVN_COUNTER_TYPE_SAMPLES_PASSED,(uintptr_t)(memory+i*64));
        NVNcommandHandle h=P(nvnCommandBufferEndRecording)(&cb[i]);P(nvnQueueSubmitCommands)(&queues[i],1,&h);
    }
    for(int i=0;i<2;i++) {
        // No program, RT, viewport or scissor rebinding: all four must survive
        // another queue's intervening submission. Counter totals stay local.
        P(nvnCommandBufferBeginRecording)(&cb[i]);P(nvnCommandBufferDrawArrays)(&cb[i],NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
        P(nvnCommandBufferReportCounter)(&cb[i],NVN_COUNTER_TYPE_SAMPLES_PASSED,(uintptr_t)(memory+i*64+16));
        P(nvnCommandBufferPopDebugGroupId)(&cb[i],7);NVNcommandHandle h=P(nvnCommandBufferEndRecording)(&cb[i]);P(nvnQueueSubmitCommands)(&queues[i],1,&h);P(nvnQueueFinish)(&queues[i]);
        queue_api_enter();mtl_queue_restore(&((queue_t *)&queues[i])->replay_state);CHECK(!g_debug_groups.count);queue_api_leave();
    }
    // 不在每次提交后 Finish：跨两个队列、反复重用四块槽缓冲，覆盖只报告、报告后继续绘制及各自清零。
    // Do not Finish after every submit: alternate queues and reuse four slot buffers, including prefix-only reports, later draws and independent resets.
    enum { COUNTER_ROUNDS=18 };
    uint64_t totals[2]={32,32},expected[2][COUNTER_ROUNDS][2];
    for(int round=0;round<COUNTER_ROUNDS;round++)for(int i=0;i<2;i++) {
        P(nvnCommandBufferBeginRecording)(&cb[i]);
        if(round==(i?10:7)){P(nvnCommandBufferResetCounter)(&cb[i],NVN_COUNTER_TYPE_SAMPLES_PASSED);totals[i]=0;}
        if(round%3){P(nvnCommandBufferDrawArrays)(&cb[i],NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);totals[i]+=16;}
        uintptr_t report=(uintptr_t)(memory+1024+i*1024+round*32);
        P(nvnCommandBufferReportCounter)(&cb[i],NVN_COUNTER_TYPE_SAMPLES_PASSED,report);expected[i][round][0]=totals[i];
        if(round%4){P(nvnCommandBufferDrawArrays)(&cb[i],NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);totals[i]+=16;}
        P(nvnCommandBufferReportCounter)(&cb[i],NVN_COUNTER_TYPE_SAMPLES_PASSED,report+16);expected[i][round][1]=totals[i];
        NVNcommandHandle h=P(nvnCommandBufferEndRecording)(&cb[i]);
        if(round==1 && i==0 && p5r_async_visibility_on())CHECK(!submit_behind_gate(&queues[i],h));
        else P(nvnQueueSubmitCommands)(&queues[i],1,&h);
    }
    for(int i=0;i<2;i++)P(nvnQueueFinish)(&queues[i]);
    for(int i=0;i<2;i++)for(int round=0;round<COUNTER_ROUNDS;round++)for(int report=0;report<2;report++) {
        CHECK(*(uint64_t *)(memory+1024+i*1024+round*32+report*16)==expected[i][round][report]);
        CHECK(*(uint64_t *)(memory+1032+i*1024+round*32+report*16)!=UINT64_C(0xa7a7a7a7a7a7a7a7));
    }
    for(int i=0;i<65536;i++)if(!(i<32 || (i>=64 && i<96) || (i>=1024 && i<1024+COUNTER_ROUNDS*32) || (i>=2048 && i<2048+COUNTER_ROUNDS*32)))CHECK(memory[i]==0xa7);
    puts("VISIBILITY PREFIX GPU OK: 72 exact reports, independent resets, immutable snapshots and repeated ring reuse");
    for(int i=0;i<2;i++) {
        CHECK(*(uint64_t *)(memory+i*64)==16 && *(uint64_t *)(memory+i*64+16)==32);
        id<MTLBuffer> output=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];memset(output.contents,0xa7,1024);
        id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> b=[command blitCommandEncoder];
        [b copyFromTexture:tex_mtl(&textures[i]) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1) toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
        [b endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
        for(int y=0;y<4;y++)for(int x=0;x<256;x++){int lit=x<32 && ((x/4>=4)==i);uint8_t expected=x>=32?0xa7:x%4==3 || (lit && x%4==i)?255:0;CHECK(((uint8_t *)output.contents)[y*256+x]==expected);}
        P(nvnQueueFinalize)(&queues[i]);P(nvnCommandBufferFinalize)(&cb[i]);mtl_tex_release(&textures[i]);mtl_prog_release(&programs[i]);
    }
    mtl_prog_release(&vertex);mtl_pool_del(memory);free(memory);return 0;
}
int main(int argc,char **argv){@autoreleasepool{
    if(argc==2 && !strcmp(argv[1],"--recursive-api")){queue_api_enter();queue_api_enter();return 1;}
    if(argc==2 && !strcmp(argv[1],"--legacy-visibility"))setenv("DM_P5R_ASYNC_VISIBILITY","0",1);
    int available=nvn_gpu_test_device();if(available)return available;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();gpa=h_nvnBootstrapLoader("nvnDeviceGetProcAddress");
    CHECK(!concurrent_submit());CHECK(!queue_state_pixels());
    puts("QUEUE CONCURRENCY GPU OK: deterministic four-thread overlap, 64 submits on two queues, internal report/fence/wait splits, independent pixels/counters/state and byte guards");return 0;
}}
