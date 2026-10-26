// 公共 NVN 录制与队列回归：验证合并任务的依赖、绑定变化、批次边界和写入范围。
// Public NVN recording/queue regression: verify batched dependencies, rebinding, boundaries and write guards.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"compute batch check failed at %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(void){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Args{device const uint *u[[id(0)]];device const uint *src[[id(1)]];device uint *dst[[id(2)]];};\n"
        "kernel void k(constant Args &a[[buffer(0)]],uint i[[thread_position_in_grid]]){a.dst[i]=a.src[i]*1664525u+a.u[0]+i;}";
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    NvShader *shader=[NvShader new];shader->fn=[library newFunctionWithName:@"k"];CHECK(shader->fn);
    shader->stage=5;shader->ae=[shader->fn newArgumentEncoderWithBufferIndex:0];CHECK(shader->ae);
    shader->arg_len=shader->ae.encodedLength;
    NSDictionary *json=@{@"route":@"B",@"stage":@"cs",@"threadgroup_size":@[@32,@1,@1],@"bindings":@[
        @{@"kind":@"ubo_ptr",@"reg":@0,@"arg_id":@0},
        @{@"kind":@"sbuf",@"reg":@0,@"arg_id":@1},
        @{@"kind":@"sbuf",@"reg":@1,@"arg_id":@2,@"rw":@YES}]};
    char reason[160];CHECK(!nvn_refl_from_json(json,&shader->rf,reason,sizeof reason));
    CHECK(compute_batch_buffer_only(&shader->rf));
    nvn_refl rejected=shader->rf;rejected.b[0].kind=NVN_RB_TEX;CHECK(!compute_batch_buffer_only(&rejected));
    rejected.b[0].kind=NVN_RB_DRV2;CHECK(!compute_batch_buffer_only(&rejected));
    prog_t program={.serial=1900000};NvProg *native=[NvProg new];native->sh[5]=shader;serial_put(program.serial,native);
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),262144));mtl_pool_add(memory,262144);
    pool_t pool={.mem=memory,.size=262144};
    NVNqueueBuilder qb={0};NVNqueue queue;h_nvnQueueBuilderSetDefaults(&qb);CHECK(h_nvnQueueInitialize(&queue,&qb));
    uint32_t reference[32];
    for(int enabled=0;enabled<2;enabled++) {
        g_p5r_compute_batch=enabled;g_compute_batch_encoders=g_compute_batch_ops=g_compute_batch_barriers=0;
        memset(memory,0xa7,262144);uint8_t *bytes=memory;
        uint32_t *buffers[2]={(uint32_t *)(bytes+256),(uint32_t *)(bytes+768)};
        uint32_t *scratch=(uint32_t *)(bytes+1280),*uniforms=(uint32_t *)(bytes+16384);
        uint32_t expected[32];for(unsigned j=0;j<32;j++)buffers[0][j]=expected[j]=j+7;
        for(unsigned i=0;i<160;i++)uniforms[i]=17+i*3;
        NVNcommandBuffer cb,child;CHECK(h_nvnCommandBufferInitialize(&cb,NULL));CHECK(h_nvnCommandBufferInitialize(&child,NULL));
        h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,65536,131072);
        h_nvnCommandBufferAddCommandMemory(&child,(const NVNmemoryPool *)&pool,196608,65536);
        h_nvnCommandBufferBeginRecording(&child);
        h_nvnCommandBufferCopyBufferToBuffer(&child,(uintptr_t)buffers[0],(uintptr_t)scratch,128,0);
        NVNcommandHandle childHandle=h_nvnCommandBufferEndRecording(&child);
        NVNsync sync;CHECK(h_nvnSyncInitialize(&sync,NULL));
        h_nvnCommandBufferBeginRecording(&cb);
        h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,NVN_SHADER_STAGE_COMPUTE_BIT);
        for(unsigned i=0;i<160;i++) {
            uint32_t *input=buffers[i&1],*output=buffers[(i+1)&1];uint32_t u=uniforms[i];
            if(i>=100) {
                u=300+i;h_nvnCommandBufferUpdateUniformBuffer(&cb,(uintptr_t)(uniforms+200),4,0,4,&u);
                if(i%2==0) {
                    h_nvnCommandBufferClearBuffer(&cb,(uintptr_t)input,128,0x12340000u+i);
                    for(unsigned j=0;j<32;j++)expected[j]=0x12340000u+i;
                } else {
                    h_nvnCommandBufferCopyBufferToBuffer(&cb,(uintptr_t)input,(uintptr_t)scratch,128,0);input=scratch;
                }
            }
            if(i==80)h_nvnCommandBufferBarrier(&cb,NVN_BARRIER_ORDER_PRIMITIVES_BIT);
            if(i==90){h_nvnCommandBufferCopyCommands(&cb,1,&childHandle);input=scratch;}
            if(i==120){h_nvnCommandBufferFenceSync(&cb,&sync,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,1);h_nvnCommandBufferWaitSync(&cb,&sync);}
            h_nvnCommandBufferBindUniformBuffer(&cb,NVN_SHADER_STAGE_COMPUTE,0,(uintptr_t)(uniforms+(i>=100?200:i)),4);
            h_nvnCommandBufferBindStorageBuffer(&cb,NVN_SHADER_STAGE_COMPUTE,0,(uintptr_t)input,128);
            h_nvnCommandBufferBindStorageBuffer(&cb,NVN_SHADER_STAGE_COMPUTE,1,(uintptr_t)output,128);
            h_nvnCommandBufferDispatchCompute(&cb,1,1,1);
            for(unsigned j=0;j<32;j++)expected[j]=expected[j]*1664525u+u+j;
        }
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);
        state_reset();memset(&R,0,sizeof R);h_nvnQueueSubmitCommands(&queue,1,&handle);h_nvnQueueFinish(&queue);
        CHECK(!mtl_last_commit_error());CHECK(!memcmp(buffers[0],expected,128));
        if(!enabled)memcpy(reference,buffers[0],128);else CHECK(!memcmp(reference,buffers[0],128));
        for(unsigned b=0;b<3;b++){uint8_t *p=b==2?(uint8_t *)scratch:(uint8_t *)buffers[b];for(int i=-16;i<144;i++)if(i<0||i>=128)CHECK(p[i]==0xa7);}
#if !DM_NVN_M3
        CHECK(!g_compute_batch_encoder && !g_compute_batch_scope);
        if(enabled){CHECK(g_compute_batch_ops>=160 && g_compute_batch_encoders<20 && g_compute_batch_barriers>=140);}
        else CHECK(!g_compute_batch_encoders && !g_compute_batch_ops);
#else
        CHECK(!g_compute_batch_encoders && !g_compute_batch_ops);
#endif
        printf("compute batch enabled=%d encoders=%llu work=%llu barriers=%llu\n",enabled,
            (unsigned long long)g_compute_batch_encoders,(unsigned long long)g_compute_batch_ops,(unsigned long long)g_compute_batch_barriers);
        h_nvnCommandBufferFinalize(&cb);h_nvnCommandBufferFinalize(&child);h_nvnSyncFinalize(&sync);
    }
    h_nvnQueueFinalize(&queue);mtl_pool_del(memory);free(memory);
    puts("COMPUTE BATCH GPU OK: exact baseline parity, 160 dependent dispatches, uniform rebinding/uploads, copies/clears, rollover, barriers, child lists, fences and guards");return 0;
}}
