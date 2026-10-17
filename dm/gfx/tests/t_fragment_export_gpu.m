// Public draw -> production fragment specialization -> independent GPU readback.
#include "../nvn/nvn_mtl.m"
#include "../nvn/hle_nvn.c"
#include "../../host/guest_bootstrap.h"
uint64_t g_t0_ns;
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"fragment export check failed at %d\n",__LINE__);return 1;}}while(0)
static id<MTLBuffer> readback(id<MTLTexture> texture) {
    id<MTLBuffer> output=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];memset(output.contents,0xa7,1024);
    id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
    [encoder copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1)
       toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
    [encoder endEncoding];[command commit];[command waitUntilCompleted];return command.status==MTLCommandBufferStatusCompleted?output:nil;
}
int main(void){@autoreleasepool{
    if(!MTLCreateSystemDefaultDevice())return 77;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();
    const struct { NVNformat format;uint32_t raw;unsigned bytes; } cases[]={
      {NVN_FORMAT_R8UI,7,1},{NVN_FORMAT_R16UI,257,2},{NVN_FORMAT_R32UI,0xf1234567,4},
      {NVN_FORMAT_R8I,(uint32_t)-7,1},{NVN_FORMAT_R16I,(uint32_t)-1234,2},{NVN_FORMAT_R32I,0x80000017,4},{NVN_FORMAT_RGBA8,0,4}};
    for(unsigned c=0;c<sizeof cases/sizeof *cases;c++) {
        NSString *value=c==6?@"float4(.25,.5,.75,1)":
          [NSString stringWithFormat:@"float4(as_type<float>(%uu ^ uint(in.p.x>=4)))",cases[c].raw];
        NSString *source=[NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
          "struct V {float4 p [[position]];};\n"
          "vertex V v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return {float4(p[n],.5,1)};}\n"
          "struct O {float4 a [[color(0)]];float4 b [[color(1)]];float4 c [[color(2)]];float z [[depth(any)]];uint mask [[sample_mask]];};\n"
          "fragment O f(V in [[stage_in]]){O out={};out.a=%@;out.b=float4(as_type<float>(-1234));out.c=float4(.25,.5,.75,1);out.z=.75;out.mask=1;"
          "if(in.p.x<7){return out;}out.mask=0;return out;}\n",value];
        MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;NSError *error=nil;
        id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:options error:&error];
        if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
        prog_t program={.serial=980000+c};NvProg *native=[NvProg new];
        native->sh[0]=[NvShader new];native->sh[0]->fn=[library newFunctionWithName:@"v"];
        NvShader *fragment=[NvShader new];fragment->fn=[library newFunctionWithName:@"f"];fragment->stage=1;
        fragment->fragment_source=source;fragment->fragment_entry=@"f";native->sh[1]=fragment;serial_put(program.serial,native);
        tex_t targets[4]={0};const NVNformat formats[]={cases[c].format,NVN_FORMAT_R32I,NVN_FORMAT_RGBA8,NVN_FORMAT_DEPTH32F};
        for(unsigned i=0;i<4;i++){targets[i].serial=990000+c*4+i;targets[i].d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=formats[i],.width=8,.height=4,.depth=1,.levels=1,.samples=1};}
        void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));memset(memory,0,65536);pool_t pool={.mem=memory,.size=65536};mtl_pool_add(memory,65536);
        NVNcommandBuffer cb;CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,0,65536);h_nvnCommandBufferBeginRecording(&cb);
        const NVNtexture *colours[]={(const NVNtexture *)&targets[0],(const NVNtexture *)&targets[1],(const NVNtexture *)&targets[2]};
        h_nvnCommandBufferSetRenderTargets(&cb,3,colours,NULL,(const NVNtexture *)&targets[3],NULL);
        const float black[]={0,0,0,0};for(unsigned i=0;i<3;i++)h_nvnCommandBufferClearColor(&cb,i,black,15);h_nvnCommandBufferClearDepthStencil(&cb,.25,1,0,0);
        NVNdepthStencilState ds;h_nvnDepthStencilStateSetDefaults(&ds);h_nvnDepthStencilStateSetDepthTestEnable(&ds,1);
        h_nvnDepthStencilStateSetDepthWriteEnable(&ds,1);h_nvnDepthStencilStateSetDepthFunc(&ds,NVN_DEPTH_FUNC_ALWAYS);h_nvnCommandBufferBindDepthStencilState(&cb,&ds);
        h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,3);h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        for(unsigned target=0;target<4;target++) {
            id<MTLBuffer> output=readback(tex_mtl(&targets[target]));CHECK(output);unsigned bytes=target?4:cases[c].bytes;
            for(unsigned y=0;y<4;y++) {
                uint8_t *row=(uint8_t *)output.contents+y*256;
                for(unsigned x=8*bytes;x<256;x++)CHECK(row[x]==0xa7);
                for(unsigned x=0;x<8;x++) {
                    if(target==3){CHECK(*(float *)(row+x*4)==(x<7?.75f:.25f));continue;}
                    if(target==2||(target==0&&c==6)) {
                        const uint8_t expected[]={64,128,191,255};for(unsigned k=0;k<4;k++)CHECK(row[x*4+k]==(x<7?expected[k]:0));
                    } else {
                        uint32_t expected=x<7?(target==1?(uint32_t)-1234:cases[c].raw^(x>=4)):0;
                        for(unsigned k=0;k<bytes;k++)CHECK(row[x*bytes+k]==(uint8_t)(expected>>(8*k)));
                    }
                }
            }
        }
        CHECK(fragment->fragment_variants.count==1);mtl_pool_del(memory);free(memory);
    }
    puts("FRAGMENT EXPORT GPU OK: seven formats, mixed targets, raw bits, early returns, depth/sample mask and row guards");return 0;
}}
