// Public compute bindings use production descriptor views and argument encoding.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"resource binding check failed at %d\n",__LINE__);return 1;}}while(0)

int main(int argc,char **argv){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();NSError *error=nil;
    const char *failure=argc>1?argv[1]:"";
    const NVNformat formats[]={NVN_FORMAT_R32F,NVN_FORMAT_R32UI,NVN_FORMAT_R32I};
    const MTLPixelFormat metalFormats[]={MTLPixelFormatR32Float,MTLPixelFormatR32Uint,MTLPixelFormatR32Sint};
    const uint32_t words[]={0x3e800000,0xf1234567,0xfffffb2e};
    const char *types[]={"float","uint","int"};
    void *memory=NULL,*commands=NULL;
    CHECK(!posix_memalign(&memory,getpagesize(),65536));CHECK(!posix_memalign(&commands,getpagesize(),65536));
    mtl_pool_add(memory,65536);mtl_pool_add(commands,65536);
    pool_t commandPool={.magic=MAGIC('P','O','O','L'),.mem=commands,.size=65536};
    for(unsigned c=0;c<3;c++) {
        NSString *expression=c?@"uint(a.t.read(uint2(0)).r)":@"as_type<uint>(a.t.sample(a.s,float2(.5)).r)";
        NSString *source=[NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct Args{texture2d<%s> t[[id(0)]];sampler s[[id(1)]];device uint *out[[id(2)]];};\n"
            "kernel void k(constant Args &a[[buffer(0)]]){a.out[0]=%@;}\n",types[c],expression];
        MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;
        id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:options error:&error];
        if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
        NvShader *shader=[NvShader new];shader->fn=[library newFunctionWithName:@"k"];CHECK(shader->fn);
        shader->stage=5;shader->ae=[shader->fn newArgumentEncoderWithBufferIndex:0];CHECK(shader->ae);
        shader->arg_len=shader->ae.encodedLength;
        NSDictionary *json=@{@"route":@"B",@"stage":@"cs",@"threadgroup_size":@[@1,@1,@1],@"bindings":@[
            @{@"kind":@"tex_combined",@"reg":@0,@"arg_id":@0,@"msl_type":[NSString stringWithFormat:@"texture2d<%s>",types[c]]},
            @{@"kind":@"samp_combined",@"reg":@0,@"arg_id":@1},
            @{@"kind":@"sbuf",@"reg":@0,@"arg_id":@2,@"rw":@YES}]};
        char reason[160];CHECK(!nvn_refl_from_json(json,&shader->rf,reason,sizeof reason));
        prog_t program={.serial=1400000+c};NvProg *native=[NvProg new];native->sh[5]=shader;serial_put(program.serial,native);
        for(unsigned variant=0;variant<3;variant++) {
            MTLPixelFormat pf=metalFormats[c];NVNformat format=formats[c];
            // A signed sampling view overrides unsigned storage and must be checked as signed.
            if(c==2&&variant==0){pf=MTLPixelFormatR32Uint;format=NVN_FORMAT_R32UI;}
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:1 height:1 mipmapped:NO];
            d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
            id<MTLTexture> texture=[g_dev newTextureWithDescriptor:d];CHECK(texture);
            uint32_t word=variant==1?0:words[c];[texture replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&word bytesPerRow:4];
            tex_t guest={.serial=1410000+c*3+variant};guest.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=format,.width=1,.height=1,.depth=1,.levels=1,.samples=1};
            serial_put(guest.serial,texture);view_t view={0};
            if(c==2&&variant==0){view.set_format=1;view.format=NVN_FORMAT_R32I;}
            mtl_reg_tex(19+variant,&guest,view.set_format?&view:NULL);
        }
        samp_par sampler={.lod_max=1000,.aniso=1};mtl_reg_samp(300,&sampler);
        // Negative subprocesses enter the same public dispatch as the valid cases.
        if(!strcmp(failure,"--bad-format"))shader->rf.b[0].dpf=NVN_DPF_UINT;
        if(!strcmp(failure,"--bad-dimension"))shader->rf.b[0].dtt=MTLTextureTypeCube;
        memset(memory,0xa7,65536);memset(commands,0,65536);NVNcommandBuffer cb;
        CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&commandPool,0,65536);h_nvnCommandBufferBeginRecording(&cb);
        h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,NVN_SHADER_STAGE_COMPUTE_BIT);
        NVNseparateTextureHandle decoy={(uint64_t)20};
        h_nvnCommandBufferBindSeparateTexture(&cb,NVN_SHADER_STAGE_COMPUTE,0,decoy);
        for(unsigned iteration=0;iteration<3;iteration++) {
            int tid=iteration==0?19:iteration==1?21:0;
            if(!strcmp(failure,"--missing-texture"))tid=999;
            int sid=!strcmp(failure,"--missing-sampler")?999:300;
            NVNtextureHandle handle=tid?nvn_combined_handle(tid,sid):0;
            h_nvnCommandBufferBindTexture(&cb,NVN_SHADER_STAGE_COMPUTE,0,handle);
            h_nvnCommandBufferBindStorageBuffer(&cb,NVN_SHADER_STAGE_COMPUTE,0,(uintptr_t)memory+16+iteration*16,4);
            h_nvnCommandBufferDispatchCompute(&cb,1,1,1);
        }
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        for(unsigned word=0;word<65536/4;word++)CHECK(((uint32_t *)memory)[word]==(word==4||word==8?words[c]:word==12?0:0xa7a7a7a7));
    }
    mtl_pool_del(memory);mtl_pool_del(commands);free(memory);free(commands);
    puts("RESOURCE BINDING GPU OK: float/uint/sint, format views, combined slot isolation, rebinding, unbinding and output guards");return 0;
}}
