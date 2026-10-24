// Public conditional rendering with GPU-written predicates and CPU query results.
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
static unsigned test_case;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"conditional render case %u failed at %d: %s\n",test_case,__LINE__,#x);return 1;}}while(0)
int main(void){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "struct Args{device atomic_uint *counter[[id(0)]];};struct V{float4 p[[position]];};\n"
      "vertex V v(uint n[[vertex_id]],constant Args &a[[buffer(0)]]){"
      "atomic_fetch_add_explicit(a.counter,1u,memory_order_relaxed);"
      "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return {float4(p[n],.5,1)};}\n"
      "fragment float4 red(){return float4(1,0,0,1);}\n"
      "fragment float4 green(){return float4(0,1,0,1);}";
    MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:options error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    NvShader *vertex=[NvShader new];vertex->fn=[library newFunctionWithName:@"v"];CHECK(vertex->fn);
    vertex->ae=[vertex->fn newArgumentEncoderWithBufferIndex:0];CHECK(vertex->ae);vertex->arg_len=vertex->ae.encodedLength;
    vertex->rf.route_b=1;vertex->rf.nb=1;vertex->rf.b[0]=(nvn_rbind){.kind=NVN_RB_SBUFP,.rw=1,.reg=0,.aid=0};
    prog_t programs[2]={{.serial=1400000},{.serial=1400001}};
    for(unsigned i=0;i<2;i++) {NvProg *program=[NvProg new];program->sh[0]=vertex;program->sh[1]=[NvShader new];
        program->sh[1]->fn=[library newFunctionWithName:i?@"green":@"red"];program->sh[1]->stage=1;serial_put(programs[i].serial,program);}
    for(test_case=0;test_case<14;test_case++) {
        tex_t colour={.serial=1400100+test_case*2},depth={.serial=1400101+test_case*2};
        colour.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=1};depth.d=colour.d;depth.d.format=NVN_FORMAT_DEPTH32F;
        void *memory=NULL,*commands=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));CHECK(!posix_memalign(&commands,getpagesize(),65536));
        memset(memory,0xa7,65536);memset(commands,0,65536);*(uint32_t *)((uint8_t *)memory+16)=0;
        // Start with the opposite equality. Predicate writes are commands after
        // the setter, so reading at record time or setter replay cannot pass.
        uint64_t pair[]={UINT64_C(0x100000005),11,UINT64_C(0x100000005),22};
        int equal=test_case==2 || test_case==5 || test_case==6 || test_case==9;
        if(!equal)pair[2]=UINT64_C(0x200000005);
        uint64_t initial[4];memcpy(initial,pair,sizeof pair);initial[2]=equal?UINT64_C(0x200000005):initial[0];memcpy((uint8_t *)memory+256,initial,sizeof initial);
        mtl_pool_add(memory,65536);mtl_pool_add(commands,65536);
        pool_t pool={.mem=commands,.size=65536};NVNcommandBuffer cb;CHECK(h_nvnCommandBufferInitialize(&cb,NULL));
        h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,0,65536);h_nvnCommandBufferBeginRecording(&cb);
        const NVNtexture *colours[]={(const NVNtexture *)&colour};h_nvnCommandBufferSetRenderTargets(&cb,1,colours,NULL,(const NVNtexture *)&depth,NULL);
        const float black[]={0,0,0,1},blue[]={0,0,1,1};h_nvnCommandBufferSetRenderEnable(&cb,1);
        h_nvnCommandBufferClearColor(&cb,0,black,15);h_nvnCommandBufferClearDepthStencil(&cb,.25,1,0,0);
        NVNdepthStencilState ds;h_nvnDepthStencilStateSetDefaults(&ds);h_nvnDepthStencilStateSetDepthTestEnable(&ds,1);h_nvnDepthStencilStateSetDepthWriteEnable(&ds,1);h_nvnDepthStencilStateSetDepthFunc(&ds,NVN_DEPTH_FUNC_ALWAYS);h_nvnCommandBufferBindDepthStencilState(&cb,&ds);
        h_nvnCommandBufferBindStorageBuffer(&cb,NVN_SHADER_STAGE_VERTEX,0,(uintptr_t)memory+16,4);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[0],3);
        unsigned expected_colour=0,expected_vertices=0;float expected_depth=.25f; // 0 black, 1 red, 2 green, 3 blue
        if(test_case>=12) {
            h_nvnCommandBufferResetCounter(&cb,NVN_COUNTER_TYPE_SAMPLES_PASSED);h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
            h_nvnCommandBufferReportCounter(&cb,NVN_COUNTER_TYPE_SAMPLES_PASSED,(uintptr_t)memory+256);
            uint64_t reference[]={test_case==12?32:31,UINT64_C(0xfedcba9876543210)};
            h_nvnCommandBufferUpdateUniformBuffer(&cb,(uintptr_t)memory,65536,272,sizeof reference,reference);
            h_nvnCommandBufferSetRenderEnableConditional(&cb,NVN_CONDITIONAL_RENDER_MODE_RENDER_IF_EQUAL,(uintptr_t)memory+256);
            h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[1],3);h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
            h_nvnCommandBufferReportCounter(&cb,NVN_COUNTER_TYPE_SAMPLES_PASSED,(uintptr_t)memory+128);
            expected_colour=test_case==12?2:1;expected_vertices=test_case==12?6:3;expected_depth=.5f;
        } else {
            if(test_case==0 || test_case==1 || test_case==11)h_nvnCommandBufferSetRenderEnable(&cb,test_case==0);
            else {
                if(test_case==8){h_nvnCommandBufferSetRenderEnable(&cb,0);h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);}
                h_nvnCommandBufferSetRenderEnableConditional(&cb,(test_case==4 || test_case==5 || test_case==8)?NVN_CONDITIONAL_RENDER_MODE_RENDER_IF_NOT_EQUAL:NVN_CONDITIONAL_RENDER_MODE_RENDER_IF_EQUAL,(uintptr_t)memory+256);
                h_nvnCommandBufferUpdateUniformBuffer(&cb,(uintptr_t)memory,65536,256,sizeof pair,pair);
            }
            if(test_case>=9) {
                h_nvnCommandBufferClearColor(&cb,0,blue,15);h_nvnCommandBufferClearDepthStencil(&cb,.75,1,0,0);
                if(test_case==9){expected_colour=3;expected_depth=.75f;}
            } else {
                if(test_case==8)h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[1],3);
                h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
                if(test_case==0 || test_case==2 || test_case==4 || test_case==6 || test_case==8){expected_colour=test_case==8?2:1;expected_vertices=3;expected_depth=.5f;}
                if(test_case==6){pair[2]=UINT64_C(0x200000005);h_nvnCommandBufferUpdateUniformBuffer(&cb,(uintptr_t)memory,65536,256,sizeof pair,pair);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[1],3);h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);}
                if(test_case==7){h_nvnCommandBufferSetRenderEnable(&cb,1);h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&programs[1],3);h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);expected_colour=2;expected_vertices=3;expected_depth=.5f;}
            }
        }
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        CHECK(*(uint32_t *)((uint8_t *)memory+16)==expected_vertices);
        if(test_case>=12){CHECK(*(uint64_t *)((uint8_t *)memory+256)==32);CHECK(*(uint64_t *)((uint8_t *)memory+128)==(test_case==12?64:32));}
        for(unsigned i=0;i<65536;i++)if(!(i>=16 && i<20) && !(i>=256 && i<288) && !(test_case>=12 && i>=128 && i<144))CHECK(((uint8_t *)memory)[i]==0xa7);
        for(unsigned target=0;target<2;target++) {
            id<MTLBuffer> output=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];memset(output.contents,0xa7,1024);
            id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
            [encoder copyFromTexture:tex_mtl(target?&depth:&colour) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1) toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
            [encoder endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
            for(unsigned y=0;y<4;y++) {uint8_t *row=(uint8_t *)output.contents+y*256;for(unsigned x=32;x<256;x++)CHECK(row[x]==0xa7);
                for(unsigned x=0;x<8;x++)if(target){CHECK(*(float *)(row+x*4)==expected_depth);}else for(unsigned k=0;k<4;k++)CHECK(row[x*4+k]==(k==3 || expected_colour==k+1?255:0));}
        }
        mtl_pool_del(memory);mtl_pool_del(commands);free(memory);free(commands);
    }
    puts("CONDITIONAL RENDER GPU OK: 14 cases, GPU predicate updates, 64-bit equal/not-equal, overrides, vertex effects, colour/depth clears, query callbacks and cumulative samples");return 0;
}}
