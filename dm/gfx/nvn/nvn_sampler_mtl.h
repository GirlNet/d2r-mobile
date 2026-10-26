// Extended sampler state shared by production and synthetic GPU checks.
#pragma once
#import <Metal/Metal.h>
#include "nvn_obj.h"

static inline int nvn_sampler_extended_descriptor(id<MTLDevice> device, MTLSamplerDescriptor *d, const samp_par *p, int strict) {
    // Metal has no NVN LOD snap equivalent. Retain/query the CPU value, but do not
    // silently render P5R with a different sampler when this feature is requested.
    if (strict && p->lod_snap != 0.f) return 0;
    if (p->reduction > NVN_SAMPLER_REDUCTION_MAX) return 0;
    if (@available(macOS 26.0, iOS 26.0, *)) {
        if (![device supportsFamily:MTLGPUFamilyApple10]) {
            if (p->reduction || (strict && p->lod_bias != 0.f)) return 0;
            return 1;
        }
        d.lodBias = p->lod_bias;
        switch (p->reduction) {
        case NVN_SAMPLER_REDUCTION_AVERAGE: d.reductionMode = MTLSamplerReductionModeWeightedAverage; break;
        case NVN_SAMPLER_REDUCTION_MIN: d.reductionMode = MTLSamplerReductionModeMinimum; break;
        case NVN_SAMPLER_REDUCTION_MAX: d.reductionMode = MTLSamplerReductionModeMaximum; break;
        }
        // Apple only enables reduction for this combination. Other combinations
        // need a shader implementation before they can be used faithfully.
        if (strict && p->reduction &&
            (d.minFilter != MTLSamplerMinMagFilterLinear || d.magFilter != MTLSamplerMinMagFilterLinear ||
             d.mipFilter != MTLSamplerMipFilterLinear)) return 0;
    } else if (p->reduction || (strict && p->lod_bias != 0.f)) return 0;
    return 1;
}
