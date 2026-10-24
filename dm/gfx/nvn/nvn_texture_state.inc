// Builder enums retain 32 bits; view swizzles retain bytes and view depth mode two bits,
// matching the original SDK accessors. Unset view getters still write their default words.
NVN(nvnTextureBuilderSetSwizzle, void, NVNtextureBuilder *b, NVNtextureSwizzle r, NVNtextureSwizzle g, NVNtextureSwizzle bl, NVNtextureSwizzle a) {
    tex_sampling_t *s=&((tex_builder_t *)b)->sampling;*s=(tex_sampling_t){.swizzle={r,g,bl,a},.depth_mode=s->depth_mode,.has_swizzle=1};
}
NVN(nvnTextureBuilderGetSwizzle, void, const NVNtextureBuilder *b, NVNtextureSwizzle *r, NVNtextureSwizzle *g, NVNtextureSwizzle *bl, NVNtextureSwizzle *a) {
    const tex_sampling_t *s=&((const tex_builder_t *)b)->sampling;
    *r=(NVNtextureSwizzle)nvn_texture_component(s,0);*g=(NVNtextureSwizzle)nvn_texture_component(s,1);*bl=(NVNtextureSwizzle)nvn_texture_component(s,2);*a=(NVNtextureSwizzle)nvn_texture_component(s,3);
}
NVN(nvnTextureBuilderSetDepthStencilMode, void, NVNtextureBuilder *b, NVNtextureDepthStencilMode m) { ((tex_builder_t *)b)->sampling.depth_mode=m; }
NVN(nvnTextureBuilderGetDepthStencilMode, NVNtextureDepthStencilMode, const NVNtextureBuilder *b) { return (NVNtextureDepthStencilMode)((const tex_builder_t *)b)->sampling.depth_mode; }
NVN(nvnTextureGetSwizzle, void, const NVNtexture *t, NVNtextureSwizzle *r, NVNtextureSwizzle *g, NVNtextureSwizzle *bl, NVNtextureSwizzle *a) {
    const tex_sampling_t *s=&((const tex_t *)t)->sampling;
    *r=(NVNtextureSwizzle)nvn_texture_component(s,0);*g=(NVNtextureSwizzle)nvn_texture_component(s,1);*bl=(NVNtextureSwizzle)nvn_texture_component(s,2);*a=(NVNtextureSwizzle)nvn_texture_component(s,3);
}
NVN(nvnTextureGetDepthStencilMode, NVNtextureDepthStencilMode, const NVNtexture *t) { return (NVNtextureDepthStencilMode)((const tex_t *)t)->sampling.depth_mode; }
NVN(nvnTextureViewSetSwizzle, void, NVNtextureView *v, NVNtextureSwizzle r, NVNtextureSwizzle g, NVNtextureSwizzle b, NVNtextureSwizzle a) {
    view_t *s=(view_t *)v;s->swizzle[0]=r;s->swizzle[1]=g;s->swizzle[2]=b;s->swizzle[3]=a;s->set_swizzle=1;
}
NVN(nvnTextureViewGetSwizzle, NVNboolean, const NVNtextureView *v, NVNtextureSwizzle *r, NVNtextureSwizzle *g, NVNtextureSwizzle *b, NVNtextureSwizzle *a) {
    const view_t *s=(const view_t *)v;*r=(NVNtextureSwizzle)s->swizzle[0];*g=(NVNtextureSwizzle)s->swizzle[1];*b=(NVNtextureSwizzle)s->swizzle[2];*a=(NVNtextureSwizzle)s->swizzle[3];return s->set_swizzle;
}
NVN(nvnTextureViewSetDepthStencilMode, void, NVNtextureView *v, NVNtextureDepthStencilMode m) { view_t *s=(view_t *)v;s->depth_mode=(unsigned)m&3;s->set_depth_mode=1; }
NVN(nvnTextureViewGetDepthStencilMode, NVNboolean, const NVNtextureView *v, NVNtextureDepthStencilMode *m) { const view_t *s=(const view_t *)v;*m=(NVNtextureDepthStencilMode)s->depth_mode;return s->set_depth_mode; }
