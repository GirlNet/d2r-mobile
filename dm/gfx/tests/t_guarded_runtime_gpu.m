// Disk library + candidate reflection -> production loader -> public dispatch/draw.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"guarded runtime check failed at %d\n",__LINE__);return 1;}}while(0)
int main(int argc,char **argv){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();
    CHECK(getenv("DM_GUARDED_LIB") && getenv("DM_GUARDED_SOURCE"));
    NSData *binary=[NSData dataWithContentsOfFile:@(getenv("DM_GUARDED_LIB"))];CHECK(binary.length>4 && !memcmp(binary.bytes,"MTLB",4));
    NSData *msl=[NSData dataWithContentsOfFile:@(getenv("DM_GUARDED_SOURCE"))];CHECK(msl);
    g_msl_dir=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:g_msl_dir withIntermediateDirectories:YES attributes:nil error:nil]);
    const int stages[]={0,1,5};NSString *names[] = {@"guarded_vertex",@"guarded_fragment",@"guarded_compute"};
    NvShader *shaders[3];
    for(unsigned i=0;i<3;i++) {
        NSString *key=[NSString stringWithFormat:@"e00000000000000%u_b",i];
        NSMutableDictionary *reflection=[@{@"key":key,@"route":@"B",@"profile":@"p5r",@"chain":@DMSH_CHAIN,
            @"entry":names[i],@"stage":i==0?@"vs":i==1?@"ps":@"cs",@"execution_mode":@"guarded_candidate",
            @"diagnostic_only":@NO,@"resource_facts_verified":@NO,@"runtime_ready":@NO,
            @"binding_coverage_complete":@YES,@"missing_descriptors":@[],@"drv_reads":@{},@"c1":@"",
            @"runtime_contract":@{@"version":@1,@"pipeline":@"p5r_nvn11",@"resources":@"per_binding",@"coordinates":@"normalized",@"storage":@"exact_gpu_pointer"},
            @"raster":@{@"colors":@[@0]},@"bindings":@[] } mutableCopy];
        if(i==2){reflection[@"bindings"]=@[@{@"kind":@"sbuf",@"reg":@0,@"arg_id":@0,@"rw":@YES,@"slot_mapping_verified":@YES}];
            reflection[@"threadgroup_size"]=@[@1,@1,@1];reflection[@"compute_memory_audit"]=@{@"memory_unused_proven":@YES};}
        CHECK([binary writeToFile:[g_msl_dir stringByAppendingPathComponent:[key stringByAppendingString:@".metallib"]] atomically:YES]);
        CHECK([msl writeToFile:[g_msl_dir stringByAppendingPathComponent:[key stringByAppendingString:@".metal"]] atomically:YES]);
        NSData *json=[NSJSONSerialization dataWithJSONObject:reflection options:0 error:nil];CHECK(json);
        CHECK([json writeToFile:[g_msl_dir stringByAppendingPathComponent:[key stringByAppendingString:@".json"]] atomically:YES]);
        unsetenv("DM_P5R_RUNTIME_MODE");CHECK(!shader_load(key,stages[i]));
        setenv("DM_P5R_RUNTIME_MODE","guarded",1);shaders[i]=shader_load(key,stages[i]);CHECK(shaders[i] && shaders[i]->rf.guarded_candidate);
    }
    NvProg *compute=[NvProg new],*graphics=[NvProg new];compute->sh[5]=shaders[2];graphics->sh[0]=shaders[0];graphics->sh[1]=shaders[1];
    prog_t cp={.serial=1500001},gp={.serial=1500002};serial_put(cp.serial,compute);serial_put(gp.serial,graphics);
    tex_t target={.serial=1500003};target.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=1};
    void *memory=NULL,*commands=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));CHECK(!posix_memalign(&commands,getpagesize(),65536));
    memset(memory,0xa7,65536);memset(commands,0,65536);mtl_pool_add(memory,65536);mtl_pool_add(commands,65536);
    pool_t pool={.mem=commands,.size=65536};NVNcommandBuffer cb;CHECK(h_nvnCommandBufferInitialize(&cb,NULL));
    h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,0,65536);h_nvnCommandBufferBeginRecording(&cb);
    h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&cp,NVN_SHADER_STAGE_COMPUTE_BIT);
    int badStorage=argc>1&&!strcmp(argv[1],"--bad-storage");
    h_nvnCommandBufferBindStorageBuffer(&cb,NVN_SHADER_STAGE_COMPUTE,0,(uintptr_t)memory+16+badStorage,4);
    h_nvnCommandBufferDispatchCompute(&cb,1,1,1);
    const NVNtexture *targets[]={(const NVNtexture *)&target};h_nvnCommandBufferSetRenderTargets(&cb,1,targets,NULL,NULL,NULL);
    const float black[]={0,0,0,1};h_nvnCommandBufferClearColor(&cb,0,black,15);
    if(argc>1&&!strcmp(argv[1],"--bad-alpha")){NVNcolorState color;h_nvnColorStateSetDefaults(&color);((color_st *)&color)->alpha_func=NVN_ALPHA_FUNC_LESS;h_nvnCommandBufferBindColorState(&cb,&color);}
    h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&gp,3);h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
    NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();
    mtl_guest_coordinates(argc>1&&!strcmp(argv[1],"--bad-coordinate")?0:1,1);mtl_exec((const uint8_t *)handle);
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
    for(unsigned i=0;i<65536/4;i++)CHECK(((uint32_t *)memory)[i]==(i==4?0x1234abcd:0xa7a7a7a7));
    id<MTLBuffer> output=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];memset(output.contents,0xa7,1024);
    id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromTexture:tex_mtl(&target) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1)
        toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
    [blit endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
    const uint8_t pixel[]={64,128,191,255};
    for(unsigned y=0;y<4;y++)for(unsigned x=0;x<256;x++)CHECK(((uint8_t *)output.contents)[y*256+x]==(x<32?pixel[x%4]:0xa7));
    mtl_pool_del(memory);mtl_pool_del(commands);free(memory);free(commands);
    CHECK([NSFileManager.defaultManager removeItemAtPath:g_msl_dir error:nil]);
    puts("GUARDED RUNTIME GPU OK: strict denial, explicit disk loading, public compute/draw, pixel/buffer and padding checks");return 0;
}}
