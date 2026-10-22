// 重跑公开 NVN 像素／实例／同步验证，并核对 Metal 4 计时关闭、延迟、完成后解析和帧数上限。
// Repeat public NVN pixel/instance/sync checks, then verify disabled, delayed, completed and bounded Metal 4 profiling.
#define main sequence_main
#include "t_command_sequence_gpu.m"
#undef main

int main(void){@autoreleasepool{
#if DM_NVN_M3
    return 78;
#else
    int available=nvn_gpu_test_device();if(available)return available;
    CHECK(!g_pg4_enabled && !g_pg4_file && !g_pg4_batch);
    char *arguments[]={"t_passgpu",NULL};CHECK(!sequence_main(1,arguments));
    CHECK(!g_pg4_file && !g_pg4_pending);
    char temporary[]="/tmp/p5r-passgpu-XXXXXX";CHECK(mkdtemp(temporary));setenv("DM_TEMP",temporary,1);
    g_pg4_enabled=1;g_pg4_delay_ms=60000;
    mtl_sub_begin();CHECK(!g_pg4_batch && !g_pg4_file);uint64_t fence=mtl_sub_commit();CHECK(mtl_wait(fence,5000000000ull));
    g_pg4_enabled=0;mtl_sub_begin();fence=mtl_sub_commit();CHECK(mtl_wait(fence,5000000000ull));
    g_pg4_delay_ms=0;g_pg4_frame_limit=2;g_pg4_enabled=1;atomic_store(&g_cur_frame,400);
    CHECK(!sequence_main(1,arguments));
    id<MTLBuffer> values=[g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared];CHECK(values);res_add(values);memset(values.contents,0xa7,64);
    NSError *error=nil;id<MTLLibrary> library=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device uint *v[[buffer(0)]],uint i[[thread_position_in_grid]]){if(i<8)v[i]=0x13570000u+i;}" options:nil error:&error];
    id<MTLComputePipelineState> pipeline=library?[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"k"] error:&error]:nil;CHECK(pipeline);
    mtl_sub_begin();CENC encoder=enc_c_begin(nil);pg4_note("synthetic-compute");
    enc_c_pso(encoder,pipeline);enc_c_args(encoder,values.gpuAddress,0);enc_c_dispatch(encoder,MTLSizeMake(1,1,1),MTLSizeMake(8,1,1));enc_c_end(encoder);
    fence=mtl_sub_commit();CHECK(mtl_wait(fence,5000000000ull));
    for(int i=0;i<8;i++)CHECK(((uint32_t *)values.contents)[i]==0x13570000u+(unsigned)i);
    for(int i=32;i<64;i++)CHECK(((uint8_t *)values.contents)[i]==0xa7);
    atomic_store(&g_cur_frame,402);mtl_sub_begin();CHECK(!g_pg4_enabled && !g_pg4_batch);
    fence=mtl_sub_commit();CHECK(mtl_wait(fence,5000000000ull));
    uint64_t deadline=bp_now()+5000000000ull;
    while(atomic_load(&g_pg4_pending) && bp_now()<deadline)usleep(1000);
    CHECK(!g_pg4_pending && g_pg4_file);fflush(g_pg4_file);
    NSString *text=[NSString stringWithContentsOfFile:@(g_pg4_path) encoding:NSUTF8StringEncoding error:&error];CHECK(text.length);
    int rows=0,valid_render=0,valid_compute=0,valid_copy=0;
    for(NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if(!line.length || [line hasPrefix:@"#"] || [line hasPrefix:@"capture"])continue;
        NSArray<NSString *> *parts=[line componentsSeparatedByString:@"\t"];CHECK(parts.count==16);rows++;
        CHECK(parts[1].longLongValue==400 && parts[15].doubleValue>=0);
        if(parts[14].intValue) {
            if([parts[3] isEqualToString:@"R"]){valid_render++;CHECK(parts[4].intValue==8 && parts[5].intValue==4);}
            if([parts[3] isEqualToString:@"C"])valid_compute++;
            if([parts[3] isEqualToString:@"B"])valid_copy++;
        }
    }
    CHECK(rows>0);
    if(!valid_render || !valid_compute || !valid_copy) {
        printf("PASSGPU4 TIMESTAMPS UNAVAILABLE: %d records, valid R=%d C=%d B=%d; pixels passed\n",rows,valid_render,valid_compute,valid_copy);return 79;
    }
    printf("PASSGPU4 GPU OK: disabled and delayed paths, twelve public pixel/sync cases, exact compute guards, raw R/C/B timestamps and automatic frame bound (%d records)\n",rows);
    return 0;
#endif
}}
