// 用自生成整数计算库验证公共派发的同进程切换、按帧交替和失败回退；不含游戏内容。
// Use generated integer kernels to verify public dispatch switching, frame alternation and rejection fallback without game content.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"compute probe check failed at %d: %s\n",__LINE__,#x);return 1;}}while(0)
static int tool(NSArray<NSString *> *arguments) {
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@"/usr/bin/xcrun"];task.arguments=arguments;
    NSError *error=nil;if(![task launchAndReturnError:&error]){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 0;}
    [task waitUntilExit];return task.terminationStatus==0;
}
int main(int argc,char **argv){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    const char *flag=argc>1?argv[1]:"";int rejection=flag[0]&&strcmp(flag,"--disabled-no-config");
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"compute-probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:NO attributes:nil error:nil]);
    NSString *source=[root stringByAppendingPathComponent:@"kernel.metal"];
    NSString *msl=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "struct Args{device const uint *input[[id(0)]];device uint *out[[id(1)]];\n"
      "#if PROBE_EXTRA\ndevice const uint *extra[[id(2)]];\n#endif\n};\n"
      "kernel void probe_main(constant Args &a[[buffer(0)]],uint i[[thread_position_in_grid]]){"
      "a.out[i]=a.input[i]*PROBE_FACTOR;\n#if PROBE_EXTRA\na.out[i]+=a.extra[i];\n#endif\n}";
    CHECK([msl writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSString *key=@"0123456789abcdef_b";
    NSString *original=[root stringByAppendingPathComponent:[key stringByAppendingString:@".metallib"]];
    NSString *candidate=[root stringByAppendingPathComponent:@"compute-probe.metallib"];
    for(unsigned i=0;i<2;i++){
        NSString *air=[root stringByAppendingPathComponent:i?@"candidate.air":@"original.air"];
        CHECK(tool(@[@"-sdk",@"macosx",@"metal",@"-c",source,@"-o",air,i?@"-DPROBE_FACTOR=3":@"-DPROBE_FACTOR=2",
            i&&!strcmp(flag,"--bad-layout")?@"-DPROBE_EXTRA=1":@"-DPROBE_EXTRA=0"]));
        CHECK(tool(@[@"-sdk",@"macosx",@"metallib",air,@"-o",i?candidate:original]));
    }
    NSData *originalData=[NSData dataWithContentsOfFile:original],*candidateData=[NSData dataWithContentsOfFile:candidate];
    NSMutableDictionary *config=[@{@"version":@1,@"key":key,@"entry":@"probe_main",
        @"original_sha256":compute_probe_digest(originalData),@"candidate_sha256":compute_probe_digest(candidateData)} mutableCopy];
    if(!strcmp(flag,"--bad-original"))config[@"original_sha256"]=[@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0];
    if(!strcmp(flag,"--bad-candidate"))config[@"candidate_sha256"]=[@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0];
    if(!strcmp(flag,"--bad-entry"))config[@"entry"]=@"missing_kernel";
    if(!strcmp(flag,"--oversize")){NSMutableData *large=[NSMutableData dataWithLength:4*1024*1024+1];CHECK([large writeToFile:candidate atomically:YES]);}
    if(strcmp(flag,"--missing")&&strcmp(flag,"--disabled-no-config"))
        CHECK([[NSJSONSerialization dataWithJSONObject:config options:0 error:nil] writeToFile:[root stringByAppendingPathComponent:@"compute-probe.json"] atomically:YES]);
    CHECK(!setenv("DM_TEMP",root.fileSystemRepresentation,1));CHECK(dm_guest_profile_select("p5r"));mtl_init();g_msl_dir=root;g_p5r_compute_batch=0;
    NSError *error=nil;id<MTLLibrary> library=lib_from_file(original,&error);CHECK(library);
    NvShader *shader=[NvShader new];shader->fn=[library newFunctionWithName:@"probe_main"];CHECK(shader->fn);
    shader->stage=5;shader->ae=[shader->fn newArgumentEncoderWithBufferIndex:0];CHECK(shader->ae);shader->arg_len=shader->ae.encodedLength;
    NSDictionary *json=@{@"route":@"B",@"stage":@"cs",@"threadgroup_size":@[@32,@1,@1],@"bindings":@[
        @{@"kind":@"sbuf",@"reg":@0,@"arg_id":@0},@{@"kind":@"sbuf",@"reg":@1,@"arg_id":@1,@"rw":@YES}]};
    char reason[160];CHECK(!nvn_refl_from_json(json,&shader->rf,reason,sizeof reason));strlcpy(shader->key,key.UTF8String,sizeof shader->key);
    prog_t programs[2]={{.serial=1910000},{.serial=1910001}};
    for(unsigned i=0;i<2;i++){
        NvShader *cs=i?[NvShader new]:shader;
        if(i){cs->fn=shader->fn;cs->rf=shader->rf;cs->ae=shader->ae;cs->arg_len=shader->arg_len;cs->stage=5;strlcpy(cs->key,"fedcba9876543210_b",sizeof cs->key);}
        NvProg *native=[NvProg new];native->sh[5]=cs;serial_put(programs[i].serial,native);
    }
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),131072));mtl_pool_add(memory,131072);pool_t pool={.mem=memory,.size=131072};
    NVNqueueBuilder qb={0};NVNqueue queue;h_nvnQueueBuilderSetDefaults(&qb);CHECK(h_nvnQueueInitialize(&queue,&qb));
    NVNcommandBuffer cb;CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,65536,65536);
    const struct{int mode;uint64_t frame;unsigned factor,program;} cases[]={{0,0,2,0},{1,1,3,0},{0,2,2,0},{1,3,3,0},{2,4,2,0},{2,5,3,0},{0,6,2,0},{1,7,2,1}};
    unsigned count=flag[0]?1:sizeof cases/sizeof *cases;
    for(unsigned i=0;i<count;i++){
        memset(memory,0xa7,65536);uint32_t *input=(uint32_t *)((uint8_t *)memory+256),*output=(uint32_t *)((uint8_t *)memory+768+(i%2)*256);
        for(unsigned j=0;j<32;j++)input[j]=j+10+i*100;
        g_cur_frame=cases[i].frame;g_compute_probe_mode=rejection?1:cases[i].mode;
        h_nvnCommandBufferBeginRecording(&cb);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[cases[i].program],NVN_SHADER_STAGE_COMPUTE_BIT);
        h_nvnCommandBufferBindStorageBuffer(&cb,NVN_SHADER_STAGE_COMPUTE,0,(uintptr_t)input,128);
        h_nvnCommandBufferBindStorageBuffer(&cb,NVN_SHADER_STAGE_COMPUTE,1,(uintptr_t)output,128);h_nvnCommandBufferDispatchCompute(&cb,1,1,1);
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);h_nvnQueueSubmitCommands(&queue,1,&handle);h_nvnQueueFinish(&queue);CHECK(!mtl_last_commit_error());
        unsigned factor=rejection?2:cases[i].factor;for(unsigned j=0;j<32;j++)CHECK(output[j]==input[j]*factor);
        for(int j=-16;j<144;j++)if(j<0||j>=128)CHECK(((uint8_t *)output)[j]==0xa7);
        if(!i&&!rejection)CHECK(!g_compute_probe_status&&!g_compute_probe_config);
    }
    if(!flag[0]){
        CHECK(g_compute_probe_status==1&&g_compute_probe_original_dispatches==3&&g_compute_probe_candidate_dispatches==3);
        p_dispatch dimensions={.x=7,.y=2,.z=1};
        CHECK(!strcmp(compute_probe_label(g_compute_probe_original,&dimensions),"P0:7,2,1"));
        CHECK(!strcmp(compute_probe_label(g_compute_probe_candidate,&dimensions),"P1:7,2,1"));
        p_dispatch large={.x=INT32_MAX,.y=INT32_MAX,.z=INT32_MAX};
        CHECK(!strcmp(compute_probe_label(g_compute_probe_candidate,&large),"probe-unmatched"));
        CHECK(g_compute_probe_original->fn!=g_compute_probe_candidate->fn);
    }else CHECK(g_compute_probe_status==(rejection?-1:0)&&!g_compute_probe_candidate_dispatches&&g_compute_probe_mode==0);
    g_compute_probe_mode=0;h_nvnCommandBufferFinalize(&cb);h_nvnQueueFinalize(&queue);mtl_pool_del(memory);free(memory);
    CHECK([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
    printf("COMPUTE PROBE GPU OK: %s same-process switching, frame parity, independent pipelines, rebinding and rejection guards\n",flag);return 0;
}}
