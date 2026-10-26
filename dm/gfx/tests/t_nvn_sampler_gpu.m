// Synthetic values only; exercises the same extended descriptor mapping as production.
#import <Foundation/Foundation.h>
#include "../nvn/nvn_sampler_mtl.h"
#include <math.h>
#include <stdio.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr,"sampler check failed at %d\n",__LINE__);return 1; } } while (0)
int main(void) { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if (!device) return 77;
    if (@available(macOS 26.0, iOS 26.0, *)) {
        if (![device supportsFamily:MTLGPUFamilyApple10]) {
            MTLSamplerDescriptor *d=[MTLSamplerDescriptor new];samp_par p={0};
            CHECK(nvn_sampler_extended_descriptor(device,d,&p,1));
            p.reduction=1;CHECK(!nvn_sampler_extended_descriptor(device,d,&p,1));
            p.reduction=0;p.lod_bias=1;CHECK(!nvn_sampler_extended_descriptor(device,d,&p,1));
            puts("sampler defaults and unsupported-family rejection passed; reduction GPU execution requires Apple10");
            return 78;
        }
        NSError *error=nil;
        NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
          "kernel void run(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float *out [[buffer(0)]]) { out[0]=t.sample(s,float2(0.5),level(0.5)).r; }";
        id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
        CHECK(library);
        id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"run"] error:&error];
        CHECK(pipeline);
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:2 height:2 mipmapped:YES];
        td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> texture=[device newTextureWithDescriptor:td];CHECK(texture);
        const float level0[4]={1,3,5,7}, level1=8;
        [texture replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:level0 bytesPerRow:8];
        [texture replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:1 withBytes:&level1 bytesPerRow:4];
        id<MTLCommandQueue> queue=[device newCommandQueue];CHECK(queue);
        const float expected[3]={6,1,8};
        for (unsigned mode=0;mode<3;mode++) {
            samp_par p={.reduction=mode};
            MTLSamplerDescriptor *d=[MTLSamplerDescriptor new];
            d.minFilter=d.magFilter=MTLSamplerMinMagFilterLinear;d.mipFilter=MTLSamplerMipFilterLinear;
            d.sAddressMode=d.tAddressMode=MTLSamplerAddressModeClampToEdge;
            CHECK(nvn_sampler_extended_descriptor(device,d,&p,1));
            id<MTLSamplerState> sampler=[device newSamplerStateWithDescriptor:d];CHECK(sampler);
            id<MTLBuffer> output=[device newBufferWithLength:16 options:MTLResourceStorageModeShared];CHECK(output);
            float *values=output.contents;for(int i=0;i<4;i++)values[i]=-99;
            id<MTLCommandBuffer> command=[queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
            [encoder setComputePipelineState:pipeline];[encoder setTexture:texture atIndex:0];
            [encoder setSamplerState:sampler atIndex:0];[encoder setBuffer:output offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
            [encoder endEncoding];[command commit];[command waitUntilCompleted];
            CHECK(command.status==MTLCommandBufferStatusCompleted);
            CHECK(fabsf(values[0]-expected[mode])<0.0001f);
            CHECK(values[1]==-99 && values[2]==-99 && values[3]==-99);
        }
        MTLSamplerDescriptor *d=[MTLSamplerDescriptor new];samp_par p={.lod_bias=1.25f};
        CHECK(nvn_sampler_extended_descriptor(device,d,&p,1));CHECK(d.lodBias==1.25f);
        p.lod_snap=0.5f;CHECK(!nvn_sampler_extended_descriptor(device,d,&p,1));
        p.lod_snap=0;p.reduction=1;CHECK(!nvn_sampler_extended_descriptor(device,d,&p,1));
        p.reduction=15;CHECK(!nvn_sampler_extended_descriptor(device,d,&p,1));
        puts("sampler GPU: average/min/max outputs, output guards, bias descriptor and unsupported-state rejection passed");
        return 0;
    }
    return 78;
} }
