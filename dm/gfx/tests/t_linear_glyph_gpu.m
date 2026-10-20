// 公开 NVN 录制验证 CPU 字形行距、线性贴图共用内存及更新后的贴图拷贝；全部像素为合成数据。
// Public NVN recording verifies CPU glyph pitch, shared linear texture storage and copies after updates; all pixels are synthetic.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"linear glyph check failed at %d: %s\n",__LINE__,#x);return 1;}}while(0)

static unsigned char pixel(int x,int y,int k,int phase) {
    return (unsigned char)((x*17+y*29+k*47+phase*83)&255);
}
static int readback(id<MTLTexture> t,int bpp,int phase,int cleared) {
    id<MTLBuffer> out=[g_dev newBufferWithLength:48*256 options:MTLResourceStorageModeShared];
    CHECK(out);memset(out.contents,0xa7,out.length);
    id<MTLCommandBuffer> cb=[g_q commandBuffer];id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
    [bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(48,48,1) toBuffer:out destinationOffset:0
        destinationBytesPerRow:256 destinationBytesPerImage:48*256];
    [bl endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(cb.status==MTLCommandBufferStatusCompleted);
    const unsigned char clear[]={51,102,153,204};
    for(int y=0;y<48;y++)for(int x=0;x<256;x++) {
        unsigned char expected=x<48*bpp?(cleared?clear[x%bpp]:pixel(x/bpp,y,x%bpp,phase)):0xa7;
        unsigned char actual=((unsigned char *)out.contents)[y*256+x];
        if(actual!=expected)fprintf(stderr,"pixel xbyte=%d y=%d got=%u expected=%u bpp=%d phase=%d clear=%d\n",x,y,actual,expected,bpp,phase,cleared);
        CHECK(actual==expected);
    }
    return 0;
}

static int one_case(int fmt,int bpp,int flags) {
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),131072));memset(memory,0x6b,131072);
    pool_t pool={.magic=MAGIC('P','O','O','L'),.mem=memory,.size=131072};mtl_pool_add(memory,131072);
    NVNtextureBuilder builder;h_nvnTextureBuilderSetDefaults(&builder);
    h_nvnTextureBuilderSetSize2D(&builder,48,48);h_nvnTextureBuilderSetFormat(&builder,fmt);
    h_nvnTextureBuilderSetFlags(&builder,flags);h_nvnTextureBuilderSetStride(&builder,256);
    h_nvnTextureBuilderSetStorage(&builder,(NVNmemoryPool *)&pool,512);
    NVNtexture source;CHECK(h_nvnTextureInitialize(&source,&builder));
    tex_t *src=(tex_t *)&source;CHECK(src->d.stride==256 && src->mem==(unsigned char *)memory+512);
    h_nvnTextureBuilderSetFlags(&builder,0);h_nvnTextureBuilderSetStride(&builder,0);
    h_nvnTextureBuilderSetStorage(&builder,(NVNmemoryPool *)&pool,16384);
    NVNtexture destination;CHECK(h_nvnTextureInitialize(&destination,&builder));
    tex_t *dst=(tex_t *)&destination;
    mtl_reg_tex(1800,src,NULL);
    pthread_mutex_lock(&g_rmu);id<MTLTexture> linear=tex_by_id(1800);pthread_mutex_unlock(&g_rmu);
    CHECK(linear && linear.buffer && linear.bufferBytesPerRow==256 && linear.bufferOffset==512);
    if(flags&NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET) {
        CHECK(linear.usage&MTLTextureUsageRenderTarget);
        MTLRenderPassDescriptor *pd=[MTLRenderPassDescriptor renderPassDescriptor];
        pd.colorAttachments[0].texture=linear;pd.colorAttachments[0].loadAction=MTLLoadActionClear;
        pd.colorAttachments[0].storeAction=MTLStoreActionStore;pd.colorAttachments[0].clearColor=MTLClearColorMake(.2,.4,.6,.8);
        id<MTLCommandBuffer> cb=[g_q commandBuffer];[[cb renderCommandEncoderWithDescriptor:pd] endEncoding];
        [cb commit];[cb waitUntilCompleted];CHECK(cb.status==MTLCommandBufferStatusCompleted);
        CHECK(!readback(linear,bpp,0,1));
        const unsigned char clear[]={51,102,153,204};
        for(int y=0;y<48;y++)for(int x=0;x<48*bpp;x++)CHECK(src->mem[y*256+x]==clear[x%bpp]);
    }
    NVNcommandBuffer cmd;CHECK(h_nvnCommandBufferInitialize(&cmd,NULL));
    h_nvnCommandBufferAddCommandMemory(&cmd,(NVNmemoryPool *)&pool,65536,32768);
    for(int phase=0;phase<2;phase++) {
        for(int y=0;y<48;y++)for(int x=0;x<48;x++)for(int k=0;k<bpp;k++)src->mem[y*256+x*bpp+k]=pixel(x,y,k,phase);
        pthread_mutex_lock(&g_rmu);id<MTLTexture> cached=tex_by_id(1800);pthread_mutex_unlock(&g_rmu);
        CHECK(cached==linear);CHECK(!readback(cached,bpp,phase,0));
        h_nvnCommandBufferBeginRecording(&cmd);
        NVNcopyRegion region={0,0,0,48,48,1};
        h_nvnCommandBufferCopyTextureToTexture(&cmd,&source,NULL,&region,&destination,NULL,&region,0);
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cmd);
        state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const unsigned char *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());
        CHECK(!readback(tex_mtl(dst),bpp,phase,0));
        for(int y=0;y<48;y++)for(int x=48*bpp;x<256;x++)CHECK(src->mem[y*256+x]==0x6b);
        for(int i=0;i<512;i++)CHECK(((unsigned char *)memory)[i]==0x6b);
        CHECK(src->mem[48*256]==0x6b);
    }
    printf("LINEAR_GLYPH format=%d flags=%#x two_cpu_updates=ok copy=ok padding=ok\n",fmt,flags);
    h_nvnCommandBufferFinalize(&cmd);h_nvnTextureFinalize(&source);h_nvnTextureFinalize(&destination);
    mtl_pool_del(memory);free(memory);return 0;
}
int main(void){@autoreleasepool{
    int available=nvn_gpu_test_device();if(available)return available;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();
    const int formats[]={NVN_FORMAT_R8,NVN_FORMAT_RG8,NVN_FORMAT_RGBA8};
    const int bpp[]={1,2,4},flags[]={0x14,0x4c,0x50};
    for(int f=0;f<3;f++)for(int k=0;k<3;k++)CHECK(!one_case(formats[f],bpp[f],flags[k]));
    puts("LINEAR GLYPH GPU OK: 9 format/flag cases, 18 CPU updates/copies, cached views, render-target aliasing and byte guards");return 0;
}}
