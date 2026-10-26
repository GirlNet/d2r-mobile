// 公开 NVN 录制验证 CPU 字形/BGRA8 界面行距、共享内存及更新后的拷贝；另用 GPU 读取核验 BGRA 颜色顺序，全部像素为合成数据。
// Public NVN recording verifies CPU glyph/BGRA8 UI pitch, shared storage and copies after updates; GPU reads also check BGRA channel order, using synthetic pixels only.
#include "../nvn/nvn_mtl.m"
#include "../nvn/hle_nvn.c"
#include "nvn_gpu_test_device.h"
#include "../../host/guest_bootstrap.h"
#include <math.h>
uint64_t g_t0_ns;
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"linear glyph check failed at %d: %s\n",__LINE__,#x);return 1;}}while(0)

static unsigned char pixel(int x,int y,int k,int phase) {
    return (unsigned char)((x*17+y*29+k*47+phase*83)&255);
}
static int readback(id<MTLTexture> t,int bpp,int phase,int cleared,int width,int height,int pitch) {
    id<MTLBuffer> out=[g_dev newBufferWithLength:(NSUInteger)height*pitch options:MTLResourceStorageModeShared];
    CHECK(out);memset(out.contents,0xa7,out.length);
    id<MTLCommandBuffer> cb=[g_q commandBuffer];id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
    [bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(width,height,1) toBuffer:out destinationOffset:0
        destinationBytesPerRow:pitch destinationBytesPerImage:(NSUInteger)height*pitch];
    [bl endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(cb.status==MTLCommandBufferStatusCompleted);
    const unsigned char clear[]={51,102,153,204};
    for(int y=0;y<height;y++)for(int x=0;x<pitch;x++) {
        int channel=x%bpp;
        if(t.pixelFormat==MTLPixelFormatBGRA8Unorm && channel<3)channel=2-channel;
        unsigned char expected=x<width*bpp?(cleared?clear[channel]:pixel(x/bpp,y,x%bpp,phase)):0xa7;
        unsigned char actual=((unsigned char *)out.contents)[y*pitch+x];
        if(actual!=expected)fprintf(stderr,"pixel xbyte=%d y=%d got=%u expected=%u bpp=%d phase=%d clear=%d\n",x,y,actual,expected,bpp,phase,cleared);
        CHECK(actual==expected);
    }
    return 0;
}

// 独立 GPU 读取验证 B/G/R/A 字节按 R/G/B/A 数值返回，防止两次同样的通道错误互相抵消。
// An independent GPU read verifies B/G/R/A bytes return R/G/B/A values, preventing matching channel mistakes from canceling out.
static int sample_bgra(id<MTLTexture> texture,int phase,int width,int height) {
    static id<MTLComputePipelineState> pipeline;
    if(!pipeline) {
        NSError *error=nil;
        NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void channels(texture2d<float,access::read> t[[texture(0)]],device float4 *o[[buffer(0)]],constant uint2 &p[[buffer(1)]]){o[0]=t.read(p);}";
        id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];CHECK(library);
        pipeline=[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"channels"] error:&error];CHECK(pipeline);
    }
    uint32_t position[2]={(uint32_t)width/2,(uint32_t)height/2};
    id<MTLBuffer> output=[g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];CHECK(output);
    float *values=output.contents;for(int k=0;k<8;k++)values[k]=-99;
    id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];[encoder setTexture:texture atIndex:0];
    [encoder setBuffer:output offset:0 atIndex:0];[encoder setBytes:position length:sizeof position atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
    [encoder endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
    for(int k=0;k<4;k++) {
        int channel=k<3?2-k:k;
        CHECK(fabsf(values[k]-pixel(position[0],position[1],channel,phase)/255.0f)<0.00001f);
        CHECK(values[k+4]==-99);
    }
    return 0;
}

static int one_case(int fmt,int bpp,int flags,int width,int height,int pitch) {
    const size_t capacity=8*1024*1024;
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),capacity));memset(memory,0x6b,capacity);
    pool_t pool={.magic=MAGIC('P','O','O','L'),.mem=memory,.size=capacity};mtl_pool_add(memory,capacity);
    NVNtextureBuilder builder;h_nvnTextureBuilderSetDefaults(&builder);
    h_nvnTextureBuilderSetSize2D(&builder,width,height);h_nvnTextureBuilderSetFormat(&builder,fmt);
    h_nvnTextureBuilderSetFlags(&builder,flags);h_nvnTextureBuilderSetStride(&builder,pitch);
    h_nvnTextureBuilderSetStorage(&builder,(NVNmemoryPool *)&pool,512);
    NVNtexture source;CHECK(h_nvnTextureInitialize(&source,&builder));
    tex_t *src=(tex_t *)&source;CHECK(src->d.stride==pitch && src->mem==(unsigned char *)memory+512);
    h_nvnTextureBuilderSetFlags(&builder,0);h_nvnTextureBuilderSetStride(&builder,0);
    h_nvnTextureBuilderSetStorage(&builder,(NVNmemoryPool *)&pool,4*1024*1024);
    NVNtexture destination;CHECK(h_nvnTextureInitialize(&destination,&builder));
    tex_t *dst=(tex_t *)&destination;
    mtl_reg_tex(1800,src,NULL);
    pthread_mutex_lock(&g_rmu);id<MTLTexture> linear=tex_by_id(1800);pthread_mutex_unlock(&g_rmu);
    CHECK(linear && linear.buffer && linear.bufferBytesPerRow==pitch && linear.bufferOffset==512);
    if(fmt==NVN_FORMAT_BGRA8)CHECK(linear.pixelFormat==MTLPixelFormatBGRA8Unorm);
    if(flags&NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET) {
        CHECK(linear.usage&MTLTextureUsageRenderTarget);
        MTLRenderPassDescriptor *pd=[MTLRenderPassDescriptor renderPassDescriptor];
        pd.colorAttachments[0].texture=linear;pd.colorAttachments[0].loadAction=MTLLoadActionClear;
        pd.colorAttachments[0].storeAction=MTLStoreActionStore;pd.colorAttachments[0].clearColor=MTLClearColorMake(.2,.4,.6,.8);
        id<MTLCommandBuffer> cb=[g_q commandBuffer];[[cb renderCommandEncoderWithDescriptor:pd] endEncoding];
        [cb commit];[cb waitUntilCompleted];CHECK(cb.status==MTLCommandBufferStatusCompleted);
        CHECK(!readback(linear,bpp,0,1,width,height,pitch));
        const unsigned char clear[]={51,102,153,204};
        for(int y=0;y<height;y++)for(int x=0;x<width*bpp;x++) {
            int channel=x%bpp;if(fmt==NVN_FORMAT_BGRA8 && channel<3)channel=2-channel;
            CHECK(src->mem[y*pitch+x]==clear[channel]);
        }
    }
    NVNcommandBuffer cmd;CHECK(h_nvnCommandBufferInitialize(&cmd,NULL));
    h_nvnCommandBufferAddCommandMemory(&cmd,(NVNmemoryPool *)&pool,7*1024*1024,32768);
    for(int phase=0;phase<2;phase++) {
        for(int y=0;y<height;y++)for(int x=0;x<width;x++)for(int k=0;k<bpp;k++)src->mem[y*pitch+x*bpp+k]=pixel(x,y,k,phase);
        pthread_mutex_lock(&g_rmu);id<MTLTexture> cached=tex_by_id(1800);pthread_mutex_unlock(&g_rmu);
        CHECK(cached==linear);CHECK(!readback(cached,bpp,phase,0,width,height,pitch));
        if(fmt==NVN_FORMAT_BGRA8)CHECK(!sample_bgra(cached,phase,width,height));
        h_nvnCommandBufferBeginRecording(&cmd);
        NVNcopyRegion region={0,0,0,width,height,1};
        h_nvnCommandBufferCopyTextureToTexture(&cmd,&source,NULL,&region,&destination,NULL,&region,0);
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cmd);
        state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const unsigned char *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        CHECK(!readback(tex_mtl(dst),bpp,phase,0,width,height,pitch));
        if(fmt==NVN_FORMAT_BGRA8)CHECK(!sample_bgra(tex_mtl(dst),phase,width,height));
        for(int y=0;y<height;y++)for(int x=width*bpp;x<pitch;x++)CHECK(src->mem[y*pitch+x]==0x6b);
        for(int i=0;i<512;i++)CHECK(((unsigned char *)memory)[i]==0x6b);
        CHECK(src->mem[(size_t)height*pitch]==0x6b);
    }
    printf("LINEAR_GLYPH format=%d flags=%#x %dx%d pitch=%d two_cpu_updates=ok copy=ok padding=ok bgra_channels=%s\n",fmt,flags,width,height,pitch,fmt==NVN_FORMAT_BGRA8?"ok":"n/a");
    h_nvnCommandBufferFinalize(&cmd);h_nvnTextureFinalize(&source);h_nvnTextureFinalize(&destination);
    mtl_pool_del(memory);free(memory);return 0;
}
int main(void){@autoreleasepool{
    int available=nvn_gpu_test_device();if(available)return available;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();
    const int formats[]={NVN_FORMAT_R8,NVN_FORMAT_RG8,NVN_FORMAT_RGBA8};
    const int bpp[]={1,2,4},flags[]={0x14,0x4c,0x50};
    for(int f=0;f<3;f++)for(int k=0;k<3;k++)CHECK(!one_case(formats[f],bpp[f],flags[k],48,48,256));
    for(int k=0;k<3;k++)CHECK(!one_case(NVN_FORMAT_BGRA8,4,flags[k],48,48,256));
    CHECK(!one_case(NVN_FORMAT_BGRA8,4,0x4c,408,770,1664));
    puts("LINEAR GLYPH GPU OK: 13 format/flag/shape cases, 26 CPU updates/copies, BGRA channels, cached views, render-target aliasing and byte guards");return 0;
}}
