// Public scratch reservation and dispatch -> production storage-buffer binding.
// A per-thread addressable array uses Metal-managed private shader storage.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"shader scratch check failed at %d\n",__LINE__);return 1;}}while(0)
int main(void){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "struct Args{device uint *out[[id(0)]];};\n"
      "kernel void k(constant Args &a[[buffer(0)]],uint tid[[thread_position_in_grid]]){\n"
      "uint temporary[257];for(uint i=0;i<257;i++)temporary[i]=(i*17)^tid;\n"
      "uint sum=0;for(uint j=0;j<257;j++)sum+=temporary[(j*13+tid)%257];a.out[tid]=sum;}";
    MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:options error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    NvShader *shader=[NvShader new];shader->fn=[library newFunctionWithName:@"k"];CHECK(shader->fn);
    shader->stage=5;shader->ae=[shader->fn newArgumentEncoderWithBufferIndex:0];CHECK(shader->ae);
    shader->arg_len=shader->ae.encodedLength;shader->rf.route_b=1;shader->rf.nb=1;
    shader->rf.b[0]=(nvn_rbind){.kind=NVN_RB_SBUFP,.rw=1,.reg=0,.aid=0};
    shader->rf.tg[0]=8;shader->rf.tg[1]=shader->rf.tg[2]=1;
    prog_t program={.serial=1300000};NvProg *native=[NvProg new];native->sh[5]=shader;serial_put(program.serial,native);
    void *memory=NULL,*scratch=NULL,*commands=NULL;
    CHECK(!posix_memalign(&memory,getpagesize(),65536));CHECK(!posix_memalign(&scratch,getpagesize(),65536));CHECK(!posix_memalign(&commands,getpagesize(),65536));
    memset(memory,0xa7,65536);memset(scratch,0x5a,65536);memset(commands,0,65536);mtl_pool_add(memory,65536);mtl_pool_add(commands,65536);
    pool_t backing={.magic=MAGIC('P','O','O','L'),.mem=scratch,.size=65536};
    pool_t commandPool={.magic=MAGIC('P','O','O','L'),.mem=commands,.size=65536};NVNcommandBuffer cb;
    CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&commandPool,0,65536);h_nvnCommandBufferBeginRecording(&cb);
    h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,NVN_SHADER_STAGE_COMPUTE_BIT);
    const unsigned offsets[]={16,512};
    for(unsigned batch=0;batch<2;batch++) {
        h_nvnCommandBufferSetShaderScratchMemory(&cb,(const NVNmemoryPool *)&backing,batch?32768:4096,16384);
        h_nvnCommandBufferBindStorageBuffer(&cb,NVN_SHADER_STAGE_COMPUTE,0,(uintptr_t)memory+offsets[batch],32*4);
        h_nvnCommandBufferDispatchCompute(&cb,4,1,1);
    }
    h_nvnCommandBufferSetShaderScratchMemory(&cb,NULL,0,0);
    NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
    for(unsigned word=0;word<65536/4;word++) {
        uint32_t expected=0xa7a7a7a7;
        for(unsigned batch=0;batch<2;batch++)if(word>=offsets[batch]/4 && word<offsets[batch]/4+32) {
            unsigned tid=word-offsets[batch]/4;expected=0;for(unsigned i=0;i<257;i++)expected+=(i*17)^tid;
        }
        CHECK(((uint32_t *)memory)[word]==expected);CHECK(((uint32_t *)scratch)[word]==0x5a5a5a5a);
    }
    mtl_pool_del(memory);mtl_pool_del(commands);free(memory);free(scratch);free(commands);
    puts("SHADER SCRATCH GPU OK: two public dispatches, per-thread private arrays, independent outputs and guarded guest reservation");return 0;
}}
