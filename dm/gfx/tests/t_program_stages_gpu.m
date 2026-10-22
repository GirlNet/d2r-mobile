// Public masked bindings -> replay/lookahead -> independent colour/buffer
// readback. P5R binds one-stage programs separately instead of one combined one.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"program stages check failed at %d\n",__LINE__);return 1;}}while(0)

static int read_colour(tex_t *target,unsigned channel) {
    id<MTLBuffer> output=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];memset(output.contents,0xa7,1024);
    id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromTexture:tex_mtl(target) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1)
        toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
    [blit endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
    for(unsigned y=0;y<4;y++)for(unsigned x=0;x<256;x++) {
        uint8_t expected=x>=32?0xa7:x%4==3||x%4==channel?255:0;
        CHECK(((uint8_t *)output.contents)[y*256+x]==expected);
    }
    return 0;
}
int main(int argc,char **argv){@autoreleasepool{
    int available=nvn_gpu_test_device();if(available)return available;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],.5,1);}\n"
      "vertex float4 outside(uint n[[vertex_id]]){return float4(4+float(n),4,.5,1);}\n"
      "fragment float4 red(){return float4(1,0,0,1);}\nfragment float4 green(){return float4(0,1,0,1);}\n"
      "fragment float4 blue(){return float4(0,0,1,1);}\n"
      "struct Args{device uint *out[[id(0)]];};kernel void fill(constant Args &a[[buffer(0)]]){a.out[0]=0x12345678;}";
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    NSString *names[]={@"v",@"outside",@"red",@"green",@"blue",@"fill"};unsigned stages[]={0,0,1,1,1,5};
    NvShader *shaders[6];prog_t programs[8]={0};
    for(unsigned i=0;i<6;i++) {
        shaders[i]=[NvShader new];shaders[i]->stage=stages[i];shaders[i]->fn=[library newFunctionWithName:names[i]];CHECK(shaders[i]->fn);
        programs[i].serial=1910000+i;NvProg *native=[NvProg new];native->sh[stages[i]]=shaders[i];serial_put(programs[i].serial,native);
    }
    NvShader *compute=shaders[5];compute->ae=[compute->fn newArgumentEncoderWithBufferIndex:0];CHECK(compute->ae);compute->arg_len=compute->ae.encodedLength;
    NSDictionary *reflection=@{@"route":@"B",@"stage":@"cs",@"threadgroup_size":@[@1,@1,@1],
        @"bindings":@[@{@"kind":@"sbuf",@"reg":@0,@"arg_id":@0,@"rw":@YES}]};
    char reason[160];CHECK(!nvn_refl_from_json(reflection,&compute->rf,reason,sizeof reason));
    for(unsigned i=6;i<8;i++) {
        NvProg *native=[NvProg new];native->sh[0]=shaders[i==6?1:0];native->sh[1]=shaders[4];native->sh[5]=compute;
        programs[i].serial=1910000+i;serial_put(programs[i].serial,native);
    }
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),131072));mtl_pool_add(memory,131072);
    pool_t pool={.magic=MAGIC('P','O','O','L'),.mem=memory,.size=131072};NVNcommandBuffer cb;
    CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,65536,65536);
    const unsigned expected[]={0,1,1,2,1,2,0,0,0,2,1,2};
    for(unsigned scenario=0;scenario<12;scenario++) {
        memset(memory,0xa7,65536);tex_t target={.serial=1910100+scenario};
        target.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=1};
        h_nvnCommandBufferBeginRecording(&cb);const NVNtexture *targets[]={(const NVNtexture *)&target};
        h_nvnCommandBufferSetRenderTargets(&cb,1,targets,NULL,NULL,NULL);h_nvnCommandBufferSetViewport(&cb,0,0,8,4);h_nvnCommandBufferSetScissor(&cb,0,0,8,4);
        h_nvnCommandBufferClearColor(&cb,0,(float[]){0,0,0,1},15);
        h_nvnCommandBufferBindStorageBuffer(&cb,NVN_SHADER_STAGE_COMPUTE,0,(uintptr_t)memory+16,4);
        h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[5],32);
        h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[0],1);
        h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[2],2);
        if(argc>1 && !strcmp(argv[1],"--missing-vertex"))h_nvnCommandBufferBindProgram(&cb,NULL,1);
        switch(scenario) {
            case 1:h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[3],2);break;
            case 2:h_nvnCommandBufferBindProgram(&cb,NULL,2);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[3],2);break;
            case 3:h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[6],2);break; // Ignore its offscreen vertex shader.
            case 4:h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[3],2);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[7],1);break;
            case 5:h_nvnCommandBufferBindProgram(&cb,NULL,63);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[7],1);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[7],2);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[5],32);break;
            case 6:h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[5],32);break;
            case 7:h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[6],0);break;
            case 8:h_nvnCommandBufferBindProgram(&cb,NULL,32);break;
            case 9:h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[7],3);h_nvnCommandBufferBindProgram(&cb,NULL,1);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[0],1);break;
            case 10:
                // Replace shaders on the same program object after an earlier
                // composition was cached; resolution must use the new serial.
                mtl_prog_release(&programs[2]);programs[2].serial=1910200;
                {NvProg *replacement=[NvProg new];replacement->sh[1]=shaders[3];serial_put(programs[2].serial,replacement);}break;
            case 11:
                // 同一客体对象和序号替换宿主记录，登记代号必须使组合缓存失效。
                // Replace the host record at the same guest object and serial; the registry generation must invalidate the composition cache.
                {NvProg *replacement=[NvProg new];replacement->sh[1]=shaders[4];serial_put(programs[2].serial,replacement);}break;
        }
        h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
        if(scenario!=8)h_nvnCommandBufferDispatchCompute(&cb,1,1,1);
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        CHECK(!read_colour(&target,expected[scenario]));
        for(unsigned i=0;i<65536/4;i++)CHECK(((uint32_t *)memory)[i]==(i==4&&scenario!=8?0x12345678:0xa7a7a7a7));
        __unsafe_unretained NvProg *before=programs_get(&S.programs);__weak NvProg *lifetime=before;
        program_bindings future=S.programs;nvn_program_bind(&future,&programs[4],2);
        CHECK(programs_get(&future)->sh[1]==shaders[4]);CHECK(lifetime);CHECK(before->sh[1]==shaders[expected[scenario]+2]);
        CHECK((before->sh[5]!=nil)==(scenario!=8));mtl_tex_release(&target);
    }
    for(unsigned i=0;i<8;i++)mtl_prog_release(&programs[i]);h_nvnCommandBufferFinalize(&cb);mtl_pool_del(memory);free(memory);
    puts("PROGRAM STAGES GPU OK: twelve masked graphics/compute cases, selective unbind, serial/registry replacement, retained compositions, pixel/buffer and row guards");return 0;
}}
