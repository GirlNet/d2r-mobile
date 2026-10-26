// Sampling state is independent of storage layout and render attachment selection.
#pragma once
#include "nvn_obj.h"
#include "../tex/nvn_fmt_mtl.h"

static inline int nvn_texture_component(const tex_sampling_t *s, unsigned channel) {
    return s->has_swizzle ? s->swizzle[channel] : (int)channel+2;
}

static inline int nvn_texture_sampling_plan(const tex_t *t, const view_t *v, int format,
                                           uint32_t *pixel_format, uint8_t swizzle[4], int *mode) {
    uint8_t physical[4];
    if (!nvn_fmt_to_mtl(format,pixel_format,physical) || !*pixel_format) return 0;
    for (unsigned i=0;i<4;i++) {
        int c=v && v->set_swizzle ? v->swizzle[i] : nvn_texture_component(&t->sampling,i);
        if (c<0 || c>5) return 0;
        swizzle[i]=c<2 ? (uint8_t)c : physical[c-2];
    }
    *mode=v && v->set_depth_mode ? v->depth_mode : t->sampling.depth_mode;
    return *mode==0 || *mode==1;
}
