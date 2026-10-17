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
    puts("P5R SHADER MATH GPU OK: production source loader, NaN, signed zero and guards");return 0;
} }
