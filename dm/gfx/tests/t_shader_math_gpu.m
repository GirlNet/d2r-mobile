// Compile a synthetic source file through the production shell library loader.
// Check NaN and signed-zero behavior on the GPU, with untouched output guards.
#define DM_SHELL 1
#include "../nvn/nvn_mtl.m"
#include "../../host/guest_bootstrap.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD];int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"shader math check failed at %d\n",__LINE__);return 1; } } while(0)

// 只改变合成辅助函数的内联属性，保留显式 fma，关闭收缩与 fast math；同时比较计算和片元结果。
// Change only synthetic helper inlining, retaining explicit fma with contraction and fast math off; compare compute and fragment outputs.
static id<MTLLibrary> math_library(NSString *source,NSError **error) {
    NSData *data=[source dataUsingEncoding:NSUTF8StringEncoding];
    char path[]="/tmp/p5r-exact-inline-XXXXXX";int fd=mkstemp(path);if(fd<0)return nil;
    ssize_t written=write(fd,data.bytes,data.length);close(fd);
    id<MTLLibrary> library=written==(ssize_t)data.length?lib_from_file(@(path),error):nil;
    unlink(path);return library;
}
static int exact_math_inline_check(void) {
    static const uint32_t special[]={0,0x80000000,0x3f800000,0xbf800000,0x3f800001,0x3f7ffffe,
        1,0x80000001,0x007fffff,0x807fffff,0x00800000,0x80800000,0x7f7fffff,0xff7fffff,
        0x7f800000,0xff800000,0x7fc00000,0xffc00000,0x7fc01234,0x7fa01234,
        0x3f000000,0xbf000000,0x40000000,0xc0000000,0x33800000,0xb3800000,
        0x5f000001,0xdf000001,0x20000001,0xa0000001,0x3f7fffff,0xbf800001};
    enum { SIDE=32, RANDOM=65536, COUNT=SIDE*SIDE*SIDE+RANDOM, WIDTH=512, WORDS=12, GUARD=256 };
    CHECK(sizeof special/sizeof *special==SIDE && COUNT%WIDTH==0);
    id<MTLBuffer> input=[g_dev newBufferWithLength:(NSUInteger)COUNT*16 options:MTLResourceStorageModeShared];CHECK(input);
    uint32_t *values=input.contents;uint32_t random=0x147c3a29;
    for(unsigned i=0;i<COUNT;i++)for(unsigned j=0;j<4;j++) {
        if(i<SIDE*SIDE*SIDE)values[i*4+j]=special[j==0?i/(SIDE*SIDE):j==1?(i/SIDE)%SIDE:j==2?i%SIDE:(i*13+7)%SIDE];
        else {random^=random<<13;random^=random>>17;random^=random<<5;values[i*4+j]=random;}
    }
    NSString *body=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "template<typename T> ATTR T exact_mul(T a,T b){return fma(a,b,T(-0.0));}\n"
        "template<typename T> ATTR T exact_add(T a,T b){return fma(T(1),a,b);}\n"
        "uint4 four(float4 v){float a=v.x,b=v.y,c=v.z;return uint4(as_type<uint>(exact_mul(a,b)),"
        "as_type<uint>(exact_add(exact_mul(a,b),c)),as_type<uint>(exact_mul(exact_add(a,b),c)),as_type<uint>(fma(a,b,c)));}\n"
        "kernel void k(device const uint4 *x[[buffer(0)]],device uint *o[[buffer(1)]],constant uint &n[[buffer(2)]],uint i[[thread_position_in_grid]]){"
        "if(i>=n)return;float4 v=as_type<float4>(x[i]);uint4 s=four(v);uint p=i*12;"
        "o[p]=s.x;o[p+1]=s.y;o[p+2]=s.z;o[p+3]=s.w;"
        "o[p+4]=as_type<uint>(exact_add(exact_add(v.x,v.y),v.z));"
        "o[p+5]=as_type<uint>(exact_add(exact_mul(v.x,v.y),exact_mul(v.z,v.w)));"
        "o[p+6]=as_type<uint>(exact_mul(exact_add(v.x,v.z),exact_add(v.y,v.w)));"
        "o[p+7]=as_type<uint>(exact_add(exact_mul(v.x,exact_add(v.y,v.z)),v.w));"
        "uint4 q=as_type<uint4>(exact_add(exact_mul(v,v.yzwx),v.wxyz));o[p+8]=q.x;o[p+9]=q.y;o[p+10]=q.z;o[p+11]=q.w;}\n"
        "vertex float4 v(uint i[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],0,1);}\n"
        "fragment uint4 f(float4 p[[position]],device const uint4 *x[[buffer(0)]],constant uint &n[[buffer(2)]]){"
        "uint i=uint(p.y)*512+uint(p.x);return i<n?four(as_type<float4>(x[i])):uint4(0);}\n";
    id<MTLBuffer> compute[2],pixels[2];double gpu_ms[2]={0};
    const NSUInteger compute_size=(NSUInteger)COUNT*WORDS*4,pixel_size=(NSUInteger)COUNT*16;
    id<MTLCommandQueue> queue=[g_dev newCommandQueue];CHECK(queue);
    for(int variant=0;variant<2;variant++) {
        NSString *source=[body stringByReplacingOccurrencesOfString:@"ATTR" withString:variant?@"[[clang::always_inline]] inline":@"[[clang::optnone]]"];
        if(variant)source=[@"#pragma clang fp contract(off)\n" stringByAppendingString:source];
        NSError *error=nil;id<MTLLibrary> library=math_library(source,&error);
        if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
        id<MTLComputePipelineState> cps=[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"k"] error:&error];CHECK(cps);
        MTLRenderPipelineDescriptor *descriptor=[MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction=[library newFunctionWithName:@"v"];descriptor.fragmentFunction=[library newFunctionWithName:@"f"];
        descriptor.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Uint;
        id<MTLRenderPipelineState> rps=[g_dev newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if(!rps)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(rps);
        compute[variant]=[g_dev newBufferWithLength:compute_size+GUARD*2 options:MTLResourceStorageModeShared];
        pixels[variant]=[g_dev newBufferWithLength:pixel_size+GUARD*2 options:MTLResourceStorageModeShared];CHECK(compute[variant] && pixels[variant]);
        memset(compute[variant].contents,0xa7,compute_size+GUARD*2);memset(pixels[variant].contents,0xa7,pixel_size+GUARD*2);
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:WIDTH height:COUNT/WIDTH mipmapped:NO];
        td.usage=MTLTextureUsageRenderTarget;td.storageMode=MTLStorageModePrivate;id<MTLTexture> target=[g_dev newTextureWithDescriptor:td];CHECK(target);
        id<MTLCommandBuffer> command=[queue commandBuffer];id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:cps];[encoder setBuffer:input offset:0 atIndex:0];[encoder setBuffer:compute[variant] offset:GUARD atIndex:1];
        uint32_t count=COUNT;[encoder setBytes:&count length:sizeof count atIndex:2];
        [encoder dispatchThreads:MTLSizeMake(COUNT,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];[encoder endEncoding];
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=target;
        pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> render=[command renderCommandEncoderWithDescriptor:pass];[render setRenderPipelineState:rps];
        [render setFragmentBuffer:input offset:0 atIndex:0];[render setFragmentBytes:&count length:sizeof count atIndex:2];
        [render setViewport:(MTLViewport){0,0,WIDTH,COUNT/WIDTH,0,1}];[render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[render endEncoding];
        id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
        [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(WIDTH,COUNT/WIDTH,1)
            toBuffer:pixels[variant] destinationOffset:GUARD destinationBytesPerRow:WIDTH*16 destinationBytesPerImage:pixel_size];
        [blit endEncoding];[command commit];[command waitUntilCompleted];
        if(command.error)fprintf(stderr,"%s\n",command.error.localizedDescription.UTF8String);CHECK(command.status==MTLCommandBufferStatusCompleted);
        gpu_ms[variant]=(command.GPUEndTime-command.GPUStartTime)*1000;
        for(NSUInteger j=0;j<GUARD;j++)CHECK(((uint8_t *)compute[variant].contents)[j]==0xa7 && ((uint8_t *)compute[variant].contents)[GUARD+compute_size+j]==0xa7
            && ((uint8_t *)pixels[variant].contents)[j]==0xa7 && ((uint8_t *)pixels[variant].contents)[GUARD+pixel_size+j]==0xa7);
    }
    const uint32_t *reference=(const uint32_t *)((const uint8_t *)compute[0].contents+GUARD);
    const uint32_t *candidate=(const uint32_t *)((const uint8_t *)compute[1].contents+GUARD);
    for(NSUInteger i=0;i<COUNT*WORDS;i++)if(reference[i]!=candidate[i]) {
        fprintf(stderr,"Exact inline compute mismatch case=%lu lane=%lu got=%08x expected=%08x\n",(unsigned long)(i/WORDS),(unsigned long)(i%WORDS),candidate[i],reference[i]);return 1;
    }
    reference=(const uint32_t *)((const uint8_t *)pixels[0].contents+GUARD);candidate=(const uint32_t *)((const uint8_t *)pixels[1].contents+GUARD);
    for(NSUInteger i=0;i<COUNT*4;i++)if(reference[i]!=candidate[i]) {
        fprintf(stderr,"Exact inline fragment mismatch case=%lu lane=%lu got=%08x expected=%08x\n",(unsigned long)(i/4),(unsigned long)(i%4),candidate[i],reference[i]);return 1;
    }
    const uint32_t *baseline=(const uint32_t *)((const uint8_t *)compute[0].contents+GUARD);
    unsigned cancellation=(4*SIDE+5)*SIDE+3;CHECK(baseline[cancellation*WORDS+1]!=baseline[cancellation*WORDS+3]);
    printf("EXACT MATH INLINE GPU OK: %u inputs, %u bit comparisons across compute and fragments; signed zero, subnormals, infinities, NaN payloads, cancellation, vectors and guards; diagnostic GPU %.3f / %.3f ms (not FPS)\n",COUNT,COUNT*(WORDS+4),gpu_ms[0],gpu_ms[1]);
    return 0;
}
int main(void) { @autoreleasepool {
    if (!MTLCreateSystemDefaultDevice()) return 77;
    CHECK(dm_guest_profile_select("p5r"));mtl_init();
    CHECK(guest_metal_options()!=nil && !guest_metal_options().fastMathEnabled);
    const char *source="#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void mathcheck(device const float *x [[buffer(0)]],device uint *o [[buffer(1)]]) {"
        "float a=x[0]; o[0]=isnan(a);o[1]=as_type<uint>(x[1]*1.0f);o[2]=isnan(a-a);}";
    char path[]="/tmp/p5r-synthetic-math-XXXXXX";int fd=mkstemp(path);CHECK(fd>=0);
    CHECK(write(fd,source,strlen(source))==(ssize_t)strlen(source));close(fd);
    NSError *error=nil;id<MTLLibrary> library=lib_from_file(@(path),&error);unlink(path);
    if(!library)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);CHECK(library);
    id<MTLComputePipelineState> pipeline=[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"mathcheck"] error:&error];CHECK(pipeline);
    uint32_t values[]={0x7fc01234,0x80000000};
    id<MTLBuffer> input=[g_dev newBufferWithBytes:values length:sizeof values options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];CHECK(input && output);
    uint32_t *result=output.contents;for(int i=0;i<8;i++)result[i]=0xdeadbeef;
    id<MTLCommandQueue> queue=[g_dev newCommandQueue];id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];[encoder setBuffer:input offset:0 atIndex:0];[encoder setBuffer:output offset:0 atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[encoder endEncoding];
    [command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
    CHECK(result[0]==1 && result[1]==0x80000000 && result[2]==1);
    for(int i=3;i<8;i++)CHECK(result[i]==0xdeadbeef);
    puts("P5R SHADER MATH GPU OK: production source loader, NaN, signed zero and guards");return exact_math_inline_check();
} }
