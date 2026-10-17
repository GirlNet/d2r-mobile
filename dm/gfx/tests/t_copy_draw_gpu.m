// Public copy recording/replay, independently calculated sampling coordinates,
// full destination subresources and row-padding guards. No game shader data.
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
#define CHECK(x) do{if(!(x)){fprintf(stderr,"copy draw check failed at %d\n",__LINE__);return 1;}}while(0)
static int execute_copy(tex_t *src,tex_t *dst,const NVNcopyRegion *sr,const NVNcopyRegion *dr,int flags,int sl,int dl,int ss,int ds) {
    void *memory=NULL;CHECK(!posix_memalign(&memory,getpagesize(),65536));memset(memory,0,65536);
    pool_t pool={.mem=memory,.size=65536};mtl_pool_add(memory,65536);
    NVNcommandBuffer cb;CHECK(h_nvnCommandBufferInitialize(&cb,NULL));h_nvnCommandBufferAddCommandMemory(&cb,(const NVNmemoryPool *)&pool,0,65536);h_nvnCommandBufferBeginRecording(&cb);
    NVNtextureView sv,dv;h_nvnTextureViewSetDefaults(&sv);h_nvnTextureViewSetDefaults(&dv);
    h_nvnTextureViewSetLevels(&sv,sl,1);h_nvnTextureViewSetLevels(&dv,dl,1);
    h_nvnTextureViewSetLayers(&sv,ss,sr->depth?sr->depth:1);h_nvnTextureViewSetLayers(&dv,ds,dr->depth?dr->depth:1);
    h_nvnCommandBufferCopyTextureToTexture(&cb,(const NVNtexture *)src,&sv,sr,(const NVNtexture *)dst,&dv,dr,flags);
    NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cb);state_reset();memset(&R,0,sizeof R);mtl_sub_begin();mtl_exec((const uint8_t *)handle);
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull));CHECK(!mtl_last_commit_error());mtl_pool_del(memory);free(memory);return 0;
}
static float component(int x,int y,int layer,int level,int channel) {
    if(channel==3)return 1;
    return (float)(channel==0?x*32+y*8+layer*4+level*16:channel==1?x*8+y*16+layer*4:32+layer*16+level*8)/255;
}
static int clamp_index(int x,int n){return x<0?0:x>=n?n-1:x;}
static float expected_sample(float sx,float sy,int n,int layer,int level,int channel,int linear) {
    if(!linear)return component(clamp_index((int)floorf(sx),n),clamp_index((int)floorf(sy),n),layer,level,channel);
    float px=sx-.5f,py=sy-.5f;int ix=(int)floorf(px),iy=(int)floorf(py);float fx=px-ix,fy=py-iy;
    float sum=0;for(int y=0;y<2;y++)for(int x=0;x<2;x++)sum+=component(clamp_index(ix+x,n),clamp_index(iy+y,n),layer,level,channel)*(x?fx:1-fx)*(y?fy:1-fy);
    return sum;
}
static int colour_cases(void) {
    const struct {int flags,sl,dl,ss,ds;NVNcopyRegion sr,dr;} cases[]={
      {0,0,0,0,0,{0,0,0,4,4,1},{0,0,0,8,8,1}},
      {NVN_COPY_FLAGS_MIRROR_X_BIT,0,0,0,0,{0,0,0,4,4,1},{2,2,0,4,4,1}},
      {NVN_COPY_FLAGS_MIRROR_Y_BIT,0,0,0,0,{0,0,0,4,4,1},{2,2,0,4,4,1}},
      {NVN_COPY_FLAGS_MIRROR_X_BIT|NVN_COPY_FLAGS_MIRROR_Y_BIT,0,0,0,0,{0,0,0,4,4,1},{2,2,0,4,4,1}},
      {NVN_COPY_FLAGS_LINEAR_FILTER_BIT,0,0,0,0,{0,0,0,4,4,1},{0,0,0,8,8,1}},
      {NVN_COPY_FLAGS_LINEAR_FILTER_BIT|NVN_COPY_FLAGS_MIRROR_X_BIT|NVN_COPY_FLAGS_MIRROR_Y_BIT,0,0,0,0,{0,0,0,4,4,1},{0,0,0,8,8,1}},
      {NVN_COPY_FLAGS_LINEAR_FILTER_BIT,1,1,1,1,{0,0,0,2,2,2},{0,0,0,4,4,2}},
      {NVN_COPY_FLAGS_LINEAR_FILTER_BIT,0,0,1,2,{1,1,0,2,2,1},{2,1,0,4,6,1}},
      {0,0,0,0,0,{0,0,0,4,4,1},{1,1,0,4,4,1}}};
    for(unsigned c=0;c<sizeof cases/sizeof *cases;c++) {
        tex_t src={.serial=1100000+c*2},dst={.serial=1100001+c*2};
        src.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D_ARRAY,.format=NVN_FORMAT_RGBA8,.width=4,.height=4,.depth=3,.levels=2,.samples=1};
        dst.d=src.d;dst.d.width=dst.d.height=8;dst.d.format=NVN_FORMAT_RGBA32F;
        MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:YES];
        descriptor.mipmapLevelCount=2;descriptor.textureType=MTLTextureType2DArray;descriptor.arrayLength=3;descriptor.storageMode=MTLStorageModeShared;descriptor.usage=MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
        id<MTLTexture> source=[g_dev newTextureWithDescriptor:descriptor];CHECK(source);
        descriptor.pixelFormat=MTLPixelFormatRGBA32Float;descriptor.width=descriptor.height=8;descriptor.usage|=MTLTextureUsageRenderTarget;
        id<MTLTexture> destination=[g_dev newTextureWithDescriptor:descriptor];CHECK(destination);
        uint8_t pixels[4*4*4];float guard[8*8*4];for(unsigned i=0;i<8*8*4;i++)guard[i]=-9;
        for(int layer=0;layer<3;layer++)for(int level=0;level<2;level++) {
            int n=4>>level;for(int y=0;y<n;y++)for(int x=0;x<n;x++)for(int k=0;k<4;k++)pixels[(y*n+x)*4+k]=(uint8_t)lroundf(component(x,y,layer,level,k)*255);
            [source replaceRegion:MTLRegionMake2D(0,0,n,n) mipmapLevel:level slice:layer withBytes:pixels bytesPerRow:n*4 bytesPerImage:n*n*4];
            int m=8>>level;[destination replaceRegion:MTLRegionMake2D(0,0,m,m) mipmapLevel:level slice:layer withBytes:guard bytesPerRow:m*16 bytesPerImage:m*m*16];
        }
        res_add(source);res_add(destination);serial_put(src.serial,source);serial_put(dst.serial,destination);
        NVNcopyRegion bad=cases[c].sr;bad.width=99;CHECK(!copy_t2t_draw(source,destination,0,0,0,0,&bad,&cases[c].dr,0,0));
        CHECK(!execute_copy(&src,&dst,&cases[c].sr,&cases[c].dr,cases[c].flags,cases[c].sl,cases[c].dl,cases[c].ss,cases[c].ds));
        for(int layer=0;layer<3;layer++)for(int level=0;level<2;level++) {
            unsigned n=8>>level;id<MTLBuffer> output=[g_dev newBufferWithLength:256*n options:MTLResourceStorageModeShared];memset(output.contents,0xa7,256*n);
            id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
            [encoder copyFromTexture:destination sourceSlice:layer sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(n,n,1)
               toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*n];[encoder endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
            for(unsigned y=0;y<n;y++) {
                uint8_t *row=(uint8_t *)output.contents+y*256;for(unsigned x=n*16;x<256;x++)CHECK(row[x]==0xa7);
                for(unsigned x=0;x<n;x++)for(int k=0;k<4;k++) {
                    const NVNcopyRegion *sr=&cases[c].sr,*dr=&cases[c].dr;float expected=-9;
                    if(level==cases[c].dl&&layer>=cases[c].ds&&layer<cases[c].ds+dr->depth&&x>=(unsigned)dr->xoffset&&x<(unsigned)(dr->xoffset+dr->width)&&y>=(unsigned)dr->yoffset&&y<(unsigned)(dr->yoffset+dr->height)) {
                        float u=((float)x-dr->xoffset+.5f)/dr->width,v=((float)y-dr->yoffset+.5f)/dr->height;
                        if(cases[c].flags&NVN_COPY_FLAGS_MIRROR_X_BIT)u=1-u;if(cases[c].flags&NVN_COPY_FLAGS_MIRROR_Y_BIT)v=1-v;
                        expected=expected_sample(sr->xoffset+u*sr->width,sr->yoffset+v*sr->height,4>>cases[c].sl,layer-cases[c].ds+cases[c].ss,cases[c].sl,k,!!(cases[c].flags&NVN_COPY_FLAGS_LINEAR_FILTER_BIT));
                    }
                    if(!isfinite(((float *)row)[x*4+k])||fabsf(((float *)row)[x*4+k]-expected)>.002f){fprintf(stderr,"case%u layer%d level%d pixel%u,%u channel%d actual%g expected%g\n",c,layer,level,x,y,k,((float *)row)[x*4+k],expected);return 1;}
                }
            }
        }
    }
    puts("COPY DRAW COLOUR GPU OK: nine nearest/linear/mirror/conversion/mip/layer cases and untouched subresources");return 0;
}
static int depth_cases(void) {
    // Produce varying depth/stencil on the GPU, then read both planes with an
    // independent compute pipeline. The combined source deliberately lacks PFV.
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],0,1);}\n"
      "struct D{float d[[depth(any)]];};struct DS{float d[[depth(any)]];uint s[[stencil]];};\n"
      "fragment D fd(float4 p[[position]]){D o;o.d=.125f+(uint(p.x)+4*uint(p.y))/32.f;return o;}\n"
      "fragment DS fds(float4 p[[position]]){DS o;uint i=uint(p.x)+4*uint(p.y);o.d=.125f+i/32.f;o.s=0x20+i;return o;}\n"
      "kernel void rd(depth2d<float> d[[texture(0)]],device uint *o[[buffer(0)]],uint2 p[[thread_position_in_grid]]){uint i=2*(p.x+8*p.y);o[i]=as_type<uint>(d.read(p));o[i+1]=0;}\n"
      "kernel void rds(depth2d<float> d[[texture(0)]],texture2d<uint> s[[texture(1)]],device uint *o[[buffer(0)]],uint2 p[[thread_position_in_grid]]){uint i=2*(p.x+8*p.y);o[i]=as_type<uint>(d.read(p));o[i+1]=s.read(p).r;}\n";
    NSError *error=nil;MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:options error:&error];
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    for(int stencil=0;stencil<2;stencil++) {
        MTLPixelFormat format=stencil?MTLPixelFormatDepth32Float_Stencil8:MTLPixelFormatDepth32Float;
        tex_t src={.serial=1200000+stencil*2},dst={.serial=1200001+stencil*2};
        src.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=stencil?NVN_FORMAT_DEPTH32F_STENCIL8:NVN_FORMAT_DEPTH32F,.width=4,.height=4,.depth=1,.levels=1,.samples=1};
        dst.d=src.d;dst.d.width=dst.d.height=8;
        MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:4 height:4 mipmapped:NO];
        descriptor.storageMode=MTLStorageModePrivate;descriptor.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
        id<MTLTexture> input=[g_dev newTextureWithDescriptor:descriptor];CHECK(input);
        descriptor.width=descriptor.height=8;descriptor.usage|=MTLTextureUsagePixelFormatView;
        id<MTLTexture> output=[g_dev newTextureWithDescriptor:descriptor];CHECK(output);
        res_add(input);res_add(output);serial_put(src.serial,input);serial_put(dst.serial,output);
        MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[library newFunctionWithName:@"v"];
        pd.fragmentFunction=[library newFunctionWithName:stencil?@"fds":@"fd"];pd.depthAttachmentPixelFormat=format;
        if(stencil)pd.stencilAttachmentPixelFormat=format;
        id<MTLRenderPipelineState> pipeline=[g_dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if(!pipeline)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(pipeline);
        MTLDepthStencilDescriptor *dd=[MTLDepthStencilDescriptor new];dd.depthCompareFunction=MTLCompareFunctionAlways;dd.depthWriteEnabled=YES;
        if(stencil){MTLStencilDescriptor *sd=[MTLStencilDescriptor new];sd.stencilCompareFunction=MTLCompareFunctionAlways;sd.depthStencilPassOperation=MTLStencilOperationReplace;dd.frontFaceStencil=dd.backFaceStencil=sd;}
        id<MTLDepthStencilState> state=[g_dev newDepthStencilStateWithDescriptor:dd];CHECK(state);
        id<MTLCommandBuffer> produce=[g_q commandBuffer];
        for(int target=0;target<2;target++) {
            id<MTLTexture> texture=target?output:input;MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor new];
            rp.depthAttachment.texture=texture;rp.depthAttachment.loadAction=MTLLoadActionClear;rp.depthAttachment.storeAction=MTLStoreActionStore;rp.depthAttachment.clearDepth=.875;
            if(stencil){rp.stencilAttachment.texture=texture;rp.stencilAttachment.loadAction=MTLLoadActionClear;rp.stencilAttachment.storeAction=MTLStoreActionStore;rp.stencilAttachment.clearStencil=0xa5;}
            id<MTLRenderCommandEncoder> encoder=[produce renderCommandEncoderWithDescriptor:rp];CHECK(encoder);
            if(!target){[encoder setRenderPipelineState:pipeline];[encoder setDepthStencilState:state];[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];}
            [encoder endEncoding];
        }
        [produce commit];[produce waitUntilCompleted];CHECK(produce.status==MTLCommandBufferStatusCompleted);
        NVNcopyRegion sr={0,0,0,4,4,1},dr={1,1,0,6,6,1};
        CHECK(!execute_copy(&src,&dst,&sr,&dr,NVN_COPY_FLAGS_MIRROR_X_BIT,0,0,0,0));
        if(stencil){CHECK(tex_mtl(&src)!=input);CHECK(tex_mtl(&src).usage&MTLTextureUsagePixelFormatView);}
        id<MTLTexture> stencilView=stencil?[output newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8]:nil;CHECK(!stencil||stencilView);
        id<MTLComputePipelineState> read=[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:stencil?@"rds":@"rd"] error:&error];CHECK(read);
        id<MTLBuffer> buffer=[g_dev newBufferWithLength:8*8*8+32 options:MTLResourceStorageModeShared];CHECK(buffer);memset(buffer.contents,0xa7,buffer.length);
        id<MTLCommandBuffer> command=[g_q commandBuffer];id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:read];[encoder setTexture:output atIndex:0];if(stencil)[encoder setTexture:stencilView atIndex:1];[encoder setBuffer:buffer offset:16 atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(8,8,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[encoder endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
        uint8_t *bytes=buffer.contents;for(int i=0;i<16;i++){CHECK(bytes[i]==0xa7);CHECK(bytes[16+8*8*8+i]==0xa7);}
        uint32_t *values=(uint32_t *)(bytes+16);
        for(int y=0;y<8;y++)for(int x=0;x<8;x++) {
            float expected=.875f;uint32_t expectedStencil=stencil?0xa5:0;
            if(x>=1&&x<7&&y>=1&&y<7){int sx=(int)floorf(4-(x-.5f)*(4.f/6)),sy=(int)floorf((y-.5f)*(4.f/6));int i=sx+4*sy;expected=.125f+i/32.f;expectedStencil=stencil?0x20+i:0;}
            float actual;memcpy(&actual,values+2*(x+8*y),4);
            if(actual!=expected||values[2*(x+8*y)+1]!=expectedStencil){fprintf(stderr,"depth/stencil case%d pixel%d,%d actual%g/%u expected%g/%u\n",stencil,x,y,actual,values[2*(x+8*y)+1],expected,expectedStencil);return 1;}
        }
    }
    puts("COPY DRAW DEPTH GPU OK: varying depth/stencil, mirrored scaling, PFV upgrade, untouched border and buffer guards");return 0;
}
int main(void){@autoreleasepool{
    int availability=nvn_gpu_test_device();if(availability)return availability;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();CHECK(!colour_cases());CHECK(!depth_cases());return 0;
}}
