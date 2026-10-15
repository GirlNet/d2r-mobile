// 合成 2D 贴图验证真实反射槽选择、原始 Metal 参数 ABI、采样与驱动表；同时执行 Metal 3/4，无游戏内容。
// Synthetic 2D textures test real reflection slot selection, raw Metal argument ABI, sampling and driver tables on Metal 3/4, without game content.
#import <Metal/Metal.h>
#import "../../gfx/nvn/nvn_refl.h"
#include <math.h>
#include <stdio.h>

#define CHECK(e) do { if (!(e)) { fprintf(stderr, "NVN texture GPU check failed at %d: %s (%s)\n", __LINE__, #e, error.localizedDescription.UTF8String ?: ""); return 1; } } while (0)

static NSDictionary *binding(NSString *kind, unsigned reg, unsigned aid) {
    return @{@"kind":kind, @"reg":@(reg), @"arg_id":@(aid), @"msl_type":@"texture2d<float>"};
}

static id<MTLTexture> texture(id<MTLDevice> device, const uint8_t *red, unsigned width) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:width height:width mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared; descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> result = [device newTextureWithDescriptor:descriptor];
    uint8_t pixels[16] = {0};
    for (unsigned i = 0; i < width * width; i++) { pixels[i * 4] = red[i]; pixels[i * 4 + 3] = 255; }
    [result replaceRegion:MTLRegionMake2D(0, 0, width, width) mipmapLevel:0 withBytes:pixels bytesPerRow:width * 4];
    return result;
}

static float expected(unsigned tid, unsigned sid, int outside) {
    if (!tid) return 0;
    float first = tid == 17 ? 0 : 128.f / 255, last = tid == 17 ? 1 : 64.f / 255;
    return sid == 4095 ? first * .75f + last * .25f : outside ? last : first;
}

static int execute(id<MTLDevice> device, id<MTLComputePipelineState> pipeline, BOOL metal4,
                   id<MTLBuffer> arguments, NSArray<id<MTLResource>> *resources, id<MTLBuffer> output) {
    NSError *error = nil;
    if (!metal4) {
        id<MTLCommandQueue> queue = [device newCommandQueue]; CHECK(queue);
        id<MTLCommandBuffer> command = [queue commandBuffer]; CHECK(command);
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder]; CHECK(encoder);
        for (id<MTLResource> resource in resources)
            [encoder useResource:resource usage:resource == output ? MTLResourceUsageWrite : MTLResourceUsageRead];
        [encoder setComputePipelineState:pipeline]; [encoder setBuffer:arguments offset:0 atIndex:0];
        [encoder dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        error = command.error; CHECK(command.status == MTLCommandBufferStatusCompleted);
    } else {
        id<MTL4CommandQueue> queue = [device newMTL4CommandQueueWithDescriptor:[MTL4CommandQueueDescriptor new] error:&error]; CHECK(queue);
        id<MTL4CommandAllocator> allocator = [device newCommandAllocatorWithDescriptor:[MTL4CommandAllocatorDescriptor new] error:&error]; CHECK(allocator);
        MTLResidencySetDescriptor *residencyDescriptor = [MTLResidencySetDescriptor new];
        residencyDescriptor.initialCapacity = resources.count;
        id<MTLResidencySet> residency = [device newResidencySetWithDescriptor:residencyDescriptor error:&error]; CHECK(residency);
        for (id<MTLResource> resource in resources) [residency addAllocation:(id<MTLAllocation>)resource];
        [residency commit]; [queue addResidencySet:residency];
        MTL4ArgumentTableDescriptor *tableDescriptor = [MTL4ArgumentTableDescriptor new]; tableDescriptor.maxBufferBindCount = 1;
        id<MTL4ArgumentTable> table = [device newArgumentTableWithDescriptor:tableDescriptor error:&error]; CHECK(table);
        [table setAddress:arguments.gpuAddress atIndex:0];
        id<MTL4CommandBuffer> command = [device newCommandBuffer]; CHECK(command);
        [command beginCommandBufferWithAllocator:allocator];
        id<MTL4ComputeCommandEncoder> encoder = [command computeCommandEncoder]; CHECK(encoder);
        [encoder setArgumentTable:table]; [encoder setComputePipelineState:pipeline];
        [encoder dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
        [encoder endEncoding]; [command endCommandBuffer];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSError *gpuError = nil;
        MTL4CommitOptions *options = [MTL4CommitOptions new];
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { gpuError = feedback.error; dispatch_semaphore_signal(done); }];
        id<MTL4CommandBuffer> commands[] = {command}; [queue commit:commands count:1 options:options];
        CHECK(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)));
        error = gpuError; CHECK(!gpuError);
    }
    return 0;
}

int main(void) { @autoreleasepool {
    NSError *error = nil;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { puts("NVN TEXTURE GPU SKIPPED: no Metal device"); return 77; }
    CHECK(device.hasUnifiedMemory);
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Args { texture2d<float> combined [[id(0)]]; sampler combinedSampler [[id(1)]]; texture2d<float> separate [[id(2)]]; sampler separateSampler [[id(3)]]; device uint4* output [[id(4)]]; constant uint* driver [[id(5)]]; constant uint2* config [[id(6)]]; };\n"
        "kernel void main0(constant Args& a [[buffer(0)]]) {\n"
        "a.output[0] = as_type<uint4>(float4(a.combined.sample(a.combinedSampler, float2(.375,.25), level(0)).r, a.separate.sample(a.separateSampler,float2(.375,.25),level(0)).r, a.combined.sample(a.combinedSampler,float2(1.125,.25),level(0)).r, a.separate.sample(a.separateSampler,float2(1.125,.25),level(0)).r));\n"
        "a.output[1] = as_type<uint4>(float4(a.combined.read(uint2(a.combined.get_width()-1,a.combined.get_height()-1)).r, a.separate.read(uint2(a.separate.get_width()-1,a.separate.get_height()-1)).r, 0, 0));\n"
        "uint co = 8 + (*a.config).x * 2, se = 0x168/4 + (*a.config).y * 2, sa = 0x568/4 + (*a.config).y * 2;\n"
        "a.output[2] = uint4(a.driver[co], a.driver[co+1], a.driver[se], a.driver[sa]);\n"
        "a.output[3] = uint4(a.combined.get_width(),a.combined.get_height(),a.separate.get_width(),a.separate.get_height()); }\n";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error]; CHECK(library);
    id<MTLFunction> function = [library newFunctionWithName:@"main0"]; CHECK(function);
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error]; CHECK(pipeline);
    id<MTLArgumentEncoder> canonical = [function newArgumentEncoderWithBufferIndex:0]; CHECK(canonical.encodedLength == 56);
    const uint8_t a[] = {0,255,64,192}, b[] = {128,64,255,0}, zero[] = {0};
    id<MTLTexture> textureA = texture(device,a,2), textureB = texture(device,b,2), dummy = texture(device,zero,1);
    CHECK(textureA && textureB && dummy);
    MTLSamplerDescriptor *descriptor = [MTLSamplerDescriptor new]; descriptor.supportArgumentBuffers = YES;
    descriptor.minFilter = descriptor.magFilter = MTLSamplerMinMagFilterNearest;
    descriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
    descriptor.normalizedCoordinates = YES; descriptor.sAddressMode = descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> nearest = [device newSamplerStateWithDescriptor:descriptor]; CHECK(nearest);
    descriptor.minFilter = descriptor.magFilter = MTLSamplerMinMagFilterLinear;
    descriptor.sAddressMode = descriptor.tAddressMode = MTLSamplerAddressModeRepeat;
    id<MTLSamplerState> linear = [device newSamplerStateWithDescriptor:descriptor]; CHECK(linear);
    NSDictionary<NSNumber *, id<MTLTexture>> *textures = @{@17:textureA, @23:textureB};
    NSDictionary<NSNumber *, id<MTLSamplerState>> *samplers = @{@2048:nearest, @4095:linear};
    unsigned cases = 0;
    for (int api = 3; api <= 4; api++) for (NSNumber *stageNumber in @[@0,@1,@5]) for (NSNumber *slotNumber in @[@0,@1,@2,@31]) {
        unsigned stage = stageNumber.unsignedIntValue, slot = slotNumber.unsignedIntValue;
        uint64_t tex[6][NVN_TEX_SLOTS] = {{0}}, samp[6][128] = {{0}}, images[6][32] = {{0}};
        // 其他阶段和同号分离槽故意放不同资源，以便错误的槽域选择可从 GPU 结果发现。
        // Other stages and the same-numbered separate slot hold different resources so GPU output exposes a wrong domain selection.
        for (unsigned st = 0; st < 6; st++) tex[st][NVN_COMBINED_TEX_FIRST + slot] = nvn_combined_handle(23,4095);
        NSDictionary *json = @{@"route":@"B", @"stage":@"cs", @"threadgroup_size":@[@1,@1,@1], @"bindings":@[
            binding(@"tex_combined",slot,0),binding(@"samp_combined",slot,1),binding(@"tex",slot,2),binding(@"samp",slot,3),
            binding(@"sbuf",0,4),@{@"kind":@"drvcb",@"bank":@2,@"arg_id":@5},binding(@"cbuf",0,6)]};
        nvn_refl reflection; char reason[160]; CHECK(!nvn_refl_from_json(json,&reflection,reason,sizeof reason));
        const unsigned coTid[] = {17,23,0,17}, coSid[] = {2048,4095,0,4095};
        const unsigned seTid[] = {23,17,23,0}, seSid[] = {4095,2048,4095,0};
        for (unsigned iteration = 0; iteration < 4; iteration++) {
            uint64_t combined = coTid[iteration] ? nvn_combined_handle(coTid[iteration],coSid[iteration]) : 0;
            uint64_t separate = seTid[iteration], sampler = seSid[iteration] ? nvn_combined_handle(0,seSid[iteration]) : 0;
            nvn_apply_handles(tex,NVN_TEX_SLOTS,stage,NVN_COMBINED_TEX_FIRST+slot,1,&combined);
            nvn_apply_handles(tex,NVN_TEX_SLOTS,stage,slot,1,&separate);
            nvn_apply_handles(samp,128,stage,slot,1,&sampler);
            id<MTLBuffer> args = [device newBufferWithLength:56 options:MTLResourceStorageModeShared];
            id<MTLBuffer> oracle = [device newBufferWithLength:56 options:MTLResourceStorageModeShared];
            id<MTLBuffer> output = [device newBufferWithLength:96 options:MTLResourceStorageModeShared];
            id<MTLBuffer> driver = [device newBufferWithLength:0xa00 options:MTLResourceStorageModeShared];
            unsigned config[] = {slot,slot};
            id<MTLBuffer> params = [device newBufferWithBytes:config length:sizeof config options:MTLResourceStorageModeShared];
            CHECK(args && oracle && output && driver && params);
            memset(output.contents,0xa5,output.length); memset(driver.contents,0,driver.length);
            CHECK(nvn_fill_texture_driver(driver.contents,driver.length,tex[stage],samp[stage]));
            [canonical setArgumentBuffer:oracle offset:0];
            for (int i = 0; i < reflection.nb; i++) {
                const nvn_rbind *rb = reflection.b + i;
                uint64_t handle = nvn_rbind_handle(rb,tex[stage],samp[stage],images[stage]);
                if (rb->kind == NVN_RB_TEX) {
                    id<MTLTexture> resource = textures[@(nvn_handle_texture_id(handle))] ?: dummy;
                    ((uint64_t *)args.contents)[rb->aid] = resource.gpuResourceID._impl;
                    [canonical setTexture:resource atIndex:rb->aid];
                } else if (rb->kind == NVN_RB_SAMP || rb->kind == NVN_RB_SAMPT) {
                    id<MTLSamplerState> resource = samplers[@(nvn_handle_sampler_id(handle))] ?: nearest;
                    ((uint64_t *)args.contents)[rb->aid] = resource.gpuResourceID._impl;
                    [canonical setSamplerState:resource atIndex:rb->aid];
                } else {
                    id<MTLBuffer> resource = rb->kind == NVN_RB_SBUFP ? output : rb->kind == NVN_RB_DRV2 ? driver : params;
                    ((uint64_t *)args.contents)[rb->aid] = resource.gpuAddress;
                    [canonical setBuffer:resource offset:0 atIndex:rb->aid];
                }
            }
            CHECK(!memcmp(args.contents,oracle.contents,56));
            CHECK(!execute(device,pipeline,api==4,args,@[args,output,driver,params,textureA,textureB,dummy],output));
            float *got = output.contents;
            float values[] = {expected(coTid[iteration],coSid[iteration],0),expected(seTid[iteration],seSid[iteration],0),
                expected(coTid[iteration],coSid[iteration],1),expected(seTid[iteration],seSid[iteration],1),
                coTid[iteration] == 17 ? 192.f/255 : 0, seTid[iteration] == 17 ? 192.f/255 : 0,0,0};
            for (unsigned i = 0; i < 8; i++) {
                if (!isfinite(got[i]) || fabsf(got[i]-values[i]) >= 0.00001f)
                    fprintf(stderr,"api=%d stage=%u slot=%u iteration=%u value=%u actual=%g expected=%g\n",api,stage,slot,iteration,i,got[i],values[i]);
                CHECK(isfinite(got[i]) && fabsf(got[i]-values[i]) < 0.00001f);
            }
            uint32_t *words = output.contents;
            CHECK(words[8] == (uint32_t)combined && words[9] == combined >> 32 && words[10] == (uint32_t)separate && words[11] == (uint32_t)sampler);
            CHECK(words[12] == (coTid[iteration] ? 2u:1u) && words[13] == words[12]);
            CHECK(words[14] == (seTid[iteration] ? 2u:1u) && words[15] == words[14]);
            for (unsigned i = 16; i < 24; i++) CHECK(words[i] == 0xa5a5a5a5);
            cases++;
        }
    }
    printf("NVN TEXTURE GPU OK: %u cases, Metal 3/4, independent slots/stages, rebind/unbind, tagged samplers, samples, dimensions, driver bytes, raw ABI\n",cases);
    return 0;
} }
