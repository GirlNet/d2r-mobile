// Real NVN vertex layouts -> production PSO specialization -> GPU pixels.
// Includes mixed signed/unsigned/normalized fetches and values above 2^24.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"vertex fetch check failed at %d\n",__LINE__);return 1;}}while(0)
int main(void){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();
    const struct { NVNformat format;uint32_t raw;unsigned bytes;int sign; } cases[]={
      {NVN_FORMAT_R8UI,7,1,0},{NVN_FORMAT_R16UI,257,2,0},{NVN_FORMAT_R32UI,0xf1234567,4,0},
      {NVN_FORMAT_R8I,(uint32_t)-7,1,1},{NVN_FORMAT_R16I,(uint32_t)-1234,2,1},{NVN_FORMAT_R32I,0x80000017,4,1},{NVN_FORMAT_R8,127,1,2}};
    for(unsigned c=0;c<sizeof cases/sizeof *cases;c++) {
        NSString *condition=cases[c].sign==2?@"abs(in.data.x-127.0f/255.0f)<.001f":cases[c].sign?
          [NSString stringWithFormat:@"as_type<int>(in.data.x)==%d",(int32_t)cases[c].raw]:[NSString stringWithFormat:@"as_type<uint>(in.data.x)==%uu",cases[c].raw];
        NSString *source=[NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
          "struct main0_in\n{\nfloat4 position [[attribute(0)]];\nfloat4 data [[attribute(1)]];\nfloat4 extra [[attribute(2)]];\n};\n"
          "struct O{float4 p[[position]];float4 c[[user(locn0)]];};\n"
          "vertex O main0(main0_in in [[stage_in]]){bool ok=(%@)&&as_type<int>(in.extra.x)==-1234;return {in.position,ok?float4(1,0,0,1):float4(0,1,0,1)};}\n"
          "fragment float4 f(O in[[stage_in]]){return in.c;}",condition];
        MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;NSError *error=nil;
        id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:options error:&error];
        if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
        prog_t program={.serial=960000+c};NvProg *native=[NvProg new];NvShader *vertex=[NvShader new];
        vertex->fn=[library newFunctionWithName:@"main0"];vertex->vertex_source=source;vertex->vertex_entry=@"main0";vertex->rf.nv=3;
        for(int i=0;i<3;i++){vertex->rf.v[i].loc=i;vertex->rf.v[i].nvn=i;vertex->rf.v[i].ct=NVN_CT_FLOAT;}
        native->sh[0]=vertex;native->sh[1]=[NvShader new];native->sh[1]->fn=[library newFunctionWithName:@"f"];native->sh[1]->stage=1;serial_put(program.serial,native);
        void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));memset(memory,0,65536);pool_t pool={.mem=memory,.size=65536};mtl_pool_add(memory,65536);
        const float positions[3][4]={{-1,-1,.5,1},{-1,3,.5,1},{3,-1,.5,1}};
        for(unsigned i=0;i<3;i++){
            uint8_t *data=(uint8_t *)memory+32768+i*32;memcpy(data,positions[i],16);memcpy(data+16,&cases[c].raw,cases[c].bytes);
            int16_t extra=-1234;memcpy(data+20,&extra,2);
        }
        tex_t colour={.serial=970000+c};colour.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=1,.levels=1,.samples=1};
        NVNcommandBuffer cb;CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,0,16384);h_nvnCommandBufferBeginRecording(&cb);
        const NVNtexture *targets[]={(const NVNtexture *)&colour};h_nvnCommandBufferSetRenderTargets(&cb,1,targets,NULL,NULL,NULL);
        const float black[]={0,0,0,1};h_nvnCommandBufferClearColor(&cb,0,black,15);
        NVNvertexAttribState attributes[3];const NVNformat formats[]={NVN_FORMAT_RGBA32F,cases[c].format,NVN_FORMAT_R16I};const int offsets[]={0,16,20};
        for(int i=0;i<3;i++){h_nvnVertexAttribStateSetDefaults(&attributes[i]);h_nvnVertexAttribStateSetFormat(&attributes[i],formats[i],offsets[i]);}
        NVNvertexStreamState stream;h_nvnVertexStreamStateSetDefaults(&stream);h_nvnVertexStreamStateSetStride(&stream,32);
        h_nvnCommandBufferBindVertexAttribState(&cb,3,attributes);h_nvnCommandBufferBindVertexStreamState(&cb,1,&stream);
        NVNbufferRange range={(uintptr_t)memory+32768,96};h_nvnCommandBufferBindVertexBuffers(&cb,0,1,&range);
        h_nvnCommandBufferBindProgram(&cb,(const NVNprogram *)&program,3);h_nvnCommandBufferDrawArrays(&cb,NVN_DRAW_PRIMITIVE_TRIANGLES,0,3);
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        id<MTLBuffer> output=[g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];memset(output.contents,0xa7,1024);
        id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
        [encoder copyFromTexture:tex_mtl(&colour) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1)
           toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];[encoder endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
        for(unsigned y=0;y<4;y++)for(unsigned x=0;x<256;x++)CHECK(((uint8_t *)output.contents)[y*256+x]==(x>=32?0xa7:(x%4==0||x%4==3)?255:0));
        mtl_pool_del(memory);free(memory);
    }
    puts("VERTEX FETCH GPU OK: seven mixed signed/unsigned/normalized formats, raw integer bits and guards");return 0;
}}
