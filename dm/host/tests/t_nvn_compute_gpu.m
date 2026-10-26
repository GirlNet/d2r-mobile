// 合成计算内核验证反射参数指针、32/64 线程组和写权限；无 Metal 设备时明确跳过，不使用游戏着色器。
// A synthetic compute kernel tests reflection argument pointers, 32/64-thread groups and write access; explicitly skips without a Metal device and uses no game shaders.
#import <Metal/Metal.h>
#import "../../gfx/nvn/nvn_refl.h"
#include <stdio.h>

#define CHECK(e) do { if (!(e)) { fprintf(stderr, "NVN compute GPU check failed at %d: %s\n", __LINE__, error.localizedDescription.UTF8String ?: ""); return 1; } } while (0)

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { puts("NVN COMPUTE GPU SKIPPED: no Metal device"); return 77; }
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Args { device uint* output [[id(0)]]; constant uint* count [[id(1)]]; const device uint* input [[id(2)]]; };\n"
        "kernel void main0(constant Args& args [[buffer(0)]], uint3 group [[threadgroup_position_in_grid]], uint3 local [[thread_position_in_threadgroup]], uint3 size [[threads_per_threadgroup]]) {\n"
        "uint i = group.x * size.x + local.x; if (i < *args.count) args.output[i] = args.input[i] ^ 0x3141u; }\n";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error]; CHECK(library);
    id<MTLFunction> function = [library newFunctionWithName:@"main0"]; CHECK(function);
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error]; CHECK(pipeline);
    id<MTLArgumentEncoder> argsEncoder = [function newArgumentEncoderWithBufferIndex:0];
    CHECK(argsEncoder.encodedLength == 24);
    id<MTLCommandQueue> queue = [device newCommandQueue]; CHECK(queue);
    for (NSNumber *width in @[@32, @64]) {
        NSDictionary *json = @{@"route":@"B", @"stage":@"cs", @"threadgroup_size":@[width,@1,@1], @"bindings":@[
            @{@"kind":@"sbuf", @"reg":@0, @"arg_id":@0, @"rw":@YES},
            @{@"kind":@"cbuf", @"reg":@0, @"arg_id":@1},
            @{@"kind":@"sbuf", @"reg":@1, @"arg_id":@2, @"rw":@NO}]};
        nvn_refl reflection; char reason[160];
        CHECK(!nvn_refl_from_json(json, &reflection, reason, sizeof reason));
        const uint32_t count = 137, capacity = 192;
        id<MTLBuffer> input = [device newBufferWithLength:capacity * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> output = [device newBufferWithLength:capacity * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> uniform = [device newBufferWithBytes:&count length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> args = [device newBufferWithLength:24 options:MTLResourceStorageModeShared];
        CHECK(input && output && uniform && args);
        for (unsigned i = 0; i < capacity; i++) ((uint32_t *)input.contents)[i] = i * 5 + 7;
        memset(output.contents, 0xa5, capacity * 4);
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        for (int i = 0; i < reflection.nb; i++) {
            nvn_rbind *binding = reflection.b + i;
            id<MTLBuffer> buffer = binding->kind == NVN_RB_CBUF ? uniform : binding->reg == 0 ? output : input;
            ((uint64_t *)args.contents)[binding->aid] = buffer.gpuAddress;
            [encoder useResource:buffer usage:binding->rw ? MTLResourceUsageRead | MTLResourceUsageWrite : MTLResourceUsageRead];
        }
        [encoder setComputePipelineState:pipeline]; [encoder setBuffer:args offset:0 atIndex:0];
        [encoder dispatchThreadgroups:MTLSizeMake((count + reflection.tg[0] - 1) / reflection.tg[0], 1, 1)
                      threadsPerThreadgroup:MTLSizeMake(reflection.tg[0], reflection.tg[1], reflection.tg[2])];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        error = command.error; CHECK(command.status == MTLCommandBufferStatusCompleted);
        for (unsigned i = 0; i < capacity; i++)
            CHECK(((uint32_t *)output.contents)[i] == (i < count ? (i * 5 + 7) ^ 0x3141u : 0xa5a5a5a5));
    }
    puts("NVN COMPUTE GPU OK: argument pointers, 32/64-thread groups, writes and bounds");
    return 0;
} }
