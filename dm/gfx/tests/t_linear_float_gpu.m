// 合成 R32F 线性渲染目标验证 GPU 写入/CPU 读取共用存储、原始行距和缓存视图，覆盖六种深度金字塔尺寸。
// Synthetic R32F linear render targets verify shared GPU-write/CPU-read storage, original pitch and cached views across six depth-pyramid sizes.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"linear float check failed at %d: %s\n",__LINE__,#x);return 1;}}while(0)

static float pattern(int x,int y,int phase,int level){return (float)((x+3*y+phase*71+level*19)%1024)/1024.0f;}
static int run_commands(NVNcommandBuffer *cmd){
    NVNcommandHandle handle=h_nvnCommandBufferEndRecording(cmd);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const unsigned char *)handle);
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());return 0;
}
static int check_copy(id<MTLTexture> texture,int w,int h,int phase,int level){
    size_t row=((size_t)w*4+255)&~(size_t)255;
    id<MTLBuffer> out=[g_dev newBufferWithLength:row*h options:MTLResourceStorageModeShared];CHECK(out);
    memset(out.contents,0xa7,out.length);
    id<MTLCommandBuffer> cb=[g_q commandBuffer];id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
    [bl copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(w,h,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*h];
    [bl endEncoding];[cb commit];[cb waitUntilCompleted];CHECK(cb.status==MTLCommandBufferStatusCompleted);
    for(int y=0;y<h;y++){
        for(int x=0;x<w;x++){float v;memcpy(&v,(unsigned char *)out.contents+y*row+x*4,4);CHECK(v==pattern(x,y,phase,level));}
        for(size_t x=(size_t)w*4;x<row;x++)CHECK(((unsigned char *)out.contents)[y*row+x]==0xa7);
    }
    return 0;
}
static int one_level(int level,int w,int h,int row){
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),4*1024*1024));memset(memory,0x6b,4*1024*1024);
    pool_t pool={.magic=MAGIC('P','O','O','L'),.mem=memory,.size=4*1024*1024};mtl_pool_add(memory,pool.size);
    NVNtextureBuilder builder;h_nvnTextureBuilderSetDefaults(&builder);
    h_nvnTextureBuilderSetSize2D(&builder,w,h);h_nvnTextureBuilderSetFormat(&builder,NVN_FORMAT_R32F);
    h_nvnTextureBuilderSetFlags(&builder,0x44);h_nvnTextureBuilderSetStride(&builder,row);
    h_nvnTextureBuilderSetStorage(&builder,(NVNmemoryPool *)&pool,128);
    NVNtexture source;CHECK(h_nvnTextureInitialize(&source,&builder));tex_t *src=(tex_t *)&source;
    h_nvnTextureBuilderSetFlags(&builder,0);h_nvnTextureBuilderSetStride(&builder,0);
    h_nvnTextureBuilderSetStorage(&builder,(NVNmemoryPool *)&pool,2*1024*1024);
    NVNtexture destination;CHECK(h_nvnTextureInitialize(&destination,&builder));
    mtl_reg_tex(1801,src,NULL);
    pthread_mutex_lock(&g_rmu);id<MTLTexture> linear=tex_by_id(1801);pthread_mutex_unlock(&g_rmu);
    CHECK(linear&&linear.buffer&&linear.pixelFormat==MTLPixelFormatR32Float);
    CHECK(linear.bufferBytesPerRow==(NSUInteger)row&&linear.bufferOffset==128);
    CHECK(linear.usage&MTLTextureUsageRenderTarget);
    NVNcommandBuffer cmd;CHECK(h_nvnCommandBufferInitialize(&cmd,NULL));
    h_nvnCommandBufferAddCommandMemory(&cmd,(NVNmemoryPool *)&pool,3*1024*1024,65536);
    for(int phase=0;phase<2;phase++){
        float value=(float)(phase*8+level+1)/16.0f,rgba[]={value,0,0,1};
        h_nvnCommandBufferBeginRecording(&cmd);const NVNtexture *targets[]={&source};
        h_nvnCommandBufferSetRenderTargets(&cmd,1,targets,NULL,NULL,NULL);
        h_nvnCommandBufferClearColor(&cmd,0,rgba,1);CHECK(!run_commands(&cmd));
        for(int y=0;y<h;y++)for(int x=0;x<w;x++){float actual;memcpy(&actual,src->mem+y*row+x*4,4);CHECK(actual==value);}
        for(int y=0;y<h;y++)for(int x=0;x<w;x++){float next=pattern(x,y,phase,level);memcpy(src->mem+y*row+x*4,&next,4);}
        pthread_mutex_lock(&g_rmu);id<MTLTexture> cached=tex_by_id(1801);pthread_mutex_unlock(&g_rmu);CHECK(cached==linear);
        h_nvnCommandBufferBeginRecording(&cmd);NVNcopyRegion region={0,0,0,w,h,1};
        h_nvnCommandBufferCopyTextureToTexture(&cmd,&source,NULL,&region,&destination,NULL,&region,0);
        CHECK(!run_commands(&cmd));CHECK(!check_copy(tex_mtl((tex_t *)&destination),w,h,phase,level));
        for(int y=0;y<h;y++)for(int x=w*4;x<row;x++)CHECK(src->mem[y*row+x]==0x6b);
        for(int i=0;i<128;i++)CHECK(((unsigned char *)memory)[i]==0x6b&&src->mem[row*h+i]==0x6b);
    }
    printf("LINEAR_FLOAT level=%d size=%dx%d pitch=%d gpu_to_cpu=ok cpu_to_gpu=ok guards=ok\n",level,w,h,row);
    h_nvnCommandBufferFinalize(&cmd);h_nvnTextureFinalize(&source);h_nvnTextureFinalize(&destination);
    mtl_pool_del(memory);free(memory);return 0;
}
int main(void){@autoreleasepool{
    int available=nvn_gpu_test_device();if(available)return available;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();
    const int shapes[][3]={{720,405,2944},{360,203,1536},{180,102,768},{90,51,384},{45,26,256},{23,13,128}};
    for(int i=0;i<6;i++)CHECK(!one_level(i,shapes[i][0],shapes[i][1],shapes[i][2]));
    puts("LINEAR FLOAT GPU OK: 6 shapes, 12 GPU render/CPU reads, 12 CPU update/GPU copies, cached views and guards");return 0;
}}
