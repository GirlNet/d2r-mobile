// Match the actual Metal sampling view to the translated shader declaration.
// The caller resolves descriptor snapshots and holds the registration lock.
#pragma once
#include <stddef.h>
#include "nvn_refl.h"

// Dimension numbers are the Metal types already stored in nvn_rbind.dtt.
// Numeric class, usage and aspect come from the resolved view, not its base.
static inline const char *nvn_texture_contract_error(const nvn_rbind *binding, int present,
    unsigned type, unsigned numeric, int depth, unsigned samples, int readable, int writable) {
    if (!present) return "missing texture descriptor";
    unsigned expected = binding->kind == NVN_RB_TBUF ? 9 : binding->dtt;
    if (type != expected) return "texture dimension mismatch";
    if (binding->dpf == NVN_DPF_DEPTH) {
        if (!depth) return "comparison texture requires depth format";
    } else if (numeric != binding->dpf) return "texture numeric type mismatch";
    if (!samples || ((samples > 1) != (expected == 4 || expected == 8))) return "texture sample count mismatch";
    if (!readable) return "texture lacks shader read usage";
    if (binding->kind == NVN_RB_IMG && !writable) return "image lacks shader write usage";
    return NULL;
}

#ifdef __OBJC__
#import <Metal/Metal.h>
_Static_assert(MTLTextureTypeTextureBuffer == 9 && MTLTextureType2DMultisample == 4 &&
               MTLTextureType2DMultisampleArray == 8, "Resource contract texture type ABI");

static inline unsigned nvn_mtl_integer_class(MTLPixelFormat format) {
    switch (format) {
    case MTLPixelFormatR8Uint: case MTLPixelFormatRG8Uint: case MTLPixelFormatRGBA8Uint:
    case MTLPixelFormatR16Uint: case MTLPixelFormatRG16Uint: case MTLPixelFormatRGBA16Uint:
    case MTLPixelFormatR32Uint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRGBA32Uint:
    case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatStencil8: case MTLPixelFormatX32_Stencil8:
        return NVN_DPF_UINT;
    case MTLPixelFormatR8Sint: case MTLPixelFormatRG8Sint: case MTLPixelFormatRGBA8Sint:
    case MTLPixelFormatR16Sint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRGBA16Sint:
    case MTLPixelFormatR32Sint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA32Sint:
        return NVN_DPF_SINT;
    default: return NVN_DPF_FLOAT;
    }
}

static inline int nvn_mtl_depth_format(MTLPixelFormat format) {
    return format == MTLPixelFormatDepth16Unorm || format == MTLPixelFormatDepth32Float ||
           format == MTLPixelFormatDepth32Float_Stencil8;
}

static inline const char *nvn_texture_binding_error(const nvn_rbind *binding, id<MTLTexture> texture) {
    return nvn_texture_contract_error(binding, texture != nil, (unsigned)texture.textureType,
        nvn_mtl_integer_class(texture.pixelFormat), nvn_mtl_depth_format(texture.pixelFormat),
        (unsigned)texture.sampleCount,
        texture.usage == MTLTextureUsageUnknown || (texture.usage & MTLTextureUsageShaderRead),
        (texture.usage & MTLTextureUsageShaderWrite) != 0);
}
#endif
