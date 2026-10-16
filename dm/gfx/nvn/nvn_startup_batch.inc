// 启动接口批量补全：依据 nvn.h 的签名及现有宿主对象/命令格式；未验证 GPU 功能仍走具名停止桩。
// Batch startup interfaces from nvn.h signatures and existing host objects/command formats; unverified GPU features retain named stops.
// 宿主共享池只提供通用非压缩存储类；0x100 是类标签，低字节 0 是宿主策略，不声称 Tegra 压缩种类一致。
// Shared host pools expose a generic uncompressed class: 0x100 is the class tag and low byte 0 is host policy, not Tegra compression-kind equivalence.
static NVNstorageClass host_storage_class(const nvn_texdesc *d) { return d && nvn_fmt_bpb(d->format,NULL,NULL) ? 0x100 : 0; }
NVN(nvnTextureBuilderGetStorageClass, NVNstorageClass, const NVNtextureBuilder *b) { return b ? host_storage_class(&((const tex_builder_t *)b)->d) : 0; }
NVN(nvnTextureGetStorageClass, NVNstorageClass, const NVNtexture *t) { return t && ((const tex_t *)t)->magic==MAGIC('T','E','X',0) ? host_storage_class(&((const tex_t *)t)->d) : 0; }
NVN(nvnMultisampleStateGetAlphaToCoverageDither, NVNboolean, const NVNmultisampleState *s) { return ((const ms_st *)s)->a2c_dither!=0; }
NVN(nvnMultisampleStateGetRasterSamples, int, NVNmultisampleState *s) { return ((const ms_st *)s)->raster_samples; }
NVN(nvnDeviceBuilderGetFlags, int, const NVNdeviceBuilder *p) { return (int)(((const dev_builder_t *)p)->flags); }
NVN(nvnDeviceGetWindowOriginMode, NVNwindowOriginMode, const NVNdevice *p) { return (NVNwindowOriginMode)(((const dev_t_ *)p)->origin); }
NVN(nvnDeviceGetDepthMode, NVNdepthMode, const NVNdevice *p) { return (NVNdepthMode)(((const dev_t_ *)p)->depth_mode); }
NVN(nvnQueueBuilderGetDevice, NVNdevice *, const NVNqueueBuilder *p) { return (NVNdevice *)(((const queue_builder_t *)p)->dev); }
NVN(nvnQueueBuilderGetFlags, int, const NVNqueueBuilder *p) { return (int)(((const queue_builder_t *)p)->flags); }
NVN(nvnQueueBuilderGetCommandMemorySize, size_t, const NVNqueueBuilder *p) { return (size_t)(((const queue_builder_t *)p)->cmd_sz); }
NVN(nvnQueueBuilderGetComputeMemorySize, size_t, const NVNqueueBuilder *p) { return (size_t)(((const queue_builder_t *)p)->comp_sz); }
NVN(nvnQueueBuilderGetControlMemorySize, size_t, const NVNqueueBuilder *p) { return (size_t)(((const queue_builder_t *)p)->ctl_sz); }
NVN(nvnQueueBuilderGetCommandFlushThreshold, size_t, const NVNqueueBuilder *p) { return (size_t)(((const queue_builder_t *)p)->flush); }
NVN(nvnQueueBuilderGetMemorySize, size_t, const NVNqueueBuilder *p) { return (size_t)(((const queue_builder_t *)p)->mem_sz); }
NVN(nvnQueueBuilderGetMemory, void *, const NVNqueueBuilder *p) { return (void *)(((const queue_builder_t *)p)->mem); }
NVN(nvnWindowBuilderGetDevice, NVNdevice *, const NVNwindowBuilder *p) { return (NVNdevice *)(((const win_builder_t *)p)->dev); }
NVN(nvnWindowBuilderGetNumTextures, int, const NVNwindowBuilder *p) { return (int)(((const win_builder_t *)p)->ntex); }
NVN(nvnWindowBuilderGetNativeWindow, NVNnativeWindow, const NVNwindowBuilder *p) { return (NVNnativeWindow)(((const win_builder_t *)p)->native); }
NVN(nvnWindowBuilderGetPresentInterval, int, const NVNwindowBuilder *p) { return (int)(((const win_builder_t *)p)->interval); }
NVN(nvnWindowBuilderGetTexture, NVNtexture *, const NVNwindowBuilder *b, int i) { const win_builder_t *o=(const win_builder_t *)b; return i>=0 && i<o->ntex && i<4 ? o->tex[i] : NULL; }
NVN(nvnWindowGetNativeWindow, NVNnativeWindow, const NVNwindow *p) { return (NVNnativeWindow)(((const win_t *)p)->native); }
NVN(nvnWindowGetPresentInterval, int, const NVNwindow *p) { return (int)(((const win_t *)p)->interval); }
NVN(nvnWindowGetCrop, void, const NVNwindow *w, NVNrectangle *r) { _Static_assert(sizeof *r==sizeof ((win_t *)w)->crop,"rectangle ABI"); if (r) memcpy(r,((const win_t *)w)->crop,sizeof *r); }
NVN(nvnTexturePoolGetMemoryPool, const NVNmemoryPool *, const NVNtexturePool *p) { return (const NVNmemoryPool *)(((const dpool_t *)p)->pool); }
NVN(nvnTexturePoolGetMemoryOffset, ptrdiff_t, const NVNtexturePool *p) { return (ptrdiff_t)(((const dpool_t *)p)->off); }
NVN(nvnTexturePoolGetSize, int, const NVNtexturePool *p) { return (int)(((const dpool_t *)p)->n); }
NVN(nvnSamplerPoolGetMemoryPool, const NVNmemoryPool *, const NVNsamplerPool *p) { return (const NVNmemoryPool *)(((const dpool_t *)p)->pool); }
NVN(nvnSamplerPoolGetMemoryOffset, ptrdiff_t, const NVNsamplerPool *p) { return (ptrdiff_t)(((const dpool_t *)p)->off); }
NVN(nvnSamplerPoolGetSize, int, const NVNsamplerPool *p) { return (int)(((const dpool_t *)p)->n); }
NVN(nvnTextureBuilderSetSize2D, void, NVNtextureBuilder *b, int w, int h) { h_nvnTextureBuilderSetSize1D(b,w);h_nvnTextureBuilderSetHeight(b,h); }
NVN(nvnTextureBuilderSetSize3D, void, NVNtextureBuilder *b, int w, int h, int d) { h_nvnTextureBuilderSetSize2D(b,w,h);h_nvnTextureBuilderSetDepth(b,d); }
NVN(nvnTextureBuilderGetTarget, NVNtextureTarget, const NVNtextureBuilder *p) { return (NVNtextureTarget)(((const tex_builder_t *)p)->d.target); }
NVN(nvnTextureGetTarget, NVNtextureTarget, const NVNtexture *p) { return (NVNtextureTarget)(((const tex_t *)p)->d.target); }
NVN(nvnTextureBuilderGetWidth, int, const NVNtextureBuilder *p) { return (int)(((const tex_builder_t *)p)->d.width); }
NVN(nvnTextureBuilderGetHeight, int, const NVNtextureBuilder *p) { return (int)(((const tex_builder_t *)p)->d.height); }
NVN(nvnTextureBuilderGetDepth, int, const NVNtextureBuilder *p) { return (int)(((const tex_builder_t *)p)->d.depth); }
NVN(nvnTextureBuilderGetLevels, int, const NVNtextureBuilder *p) { return (int)(((const tex_builder_t *)p)->d.levels); }
NVN(nvnTextureGetLevels, int, const NVNtexture *p) { return (int)(((const tex_t *)p)->d.levels); }
NVN(nvnTextureBuilderGetFormat, NVNformat, const NVNtextureBuilder *p) { return (NVNformat)(((const tex_builder_t *)p)->d.format); }
NVN(nvnTextureGetFormat, NVNformat, const NVNtexture *p) { return (NVNformat)(((const tex_t *)p)->d.format); }
NVN(nvnTextureBuilderGetSamples, int, const NVNtextureBuilder *p) { return (int)(((const tex_builder_t *)p)->d.samples); }
NVN(nvnTextureGetSamples, int, const NVNtexture *p) { return (int)(((const tex_t *)p)->d.samples); }
NVN(nvnTextureBuilderGetStride, ptrdiff_t, const NVNtextureBuilder *p) { return (ptrdiff_t)(((const tex_builder_t *)p)->d.stride); }
NVN(nvnTextureGetStride, ptrdiff_t, const NVNtexture *p) { return (ptrdiff_t)(((const tex_t *)p)->d.stride); }
NVN(nvnTextureBuilderGetMemoryPool, NVNmemoryPool *, const NVNtextureBuilder *p) { return (NVNmemoryPool *)(((const tex_builder_t *)p)->pool); }
NVN(nvnTextureBuilderGetMemoryOffset, ptrdiff_t, const NVNtextureBuilder *p) { return (ptrdiff_t)(((const tex_builder_t *)p)->off); }
NVN(nvnTextureGetMemoryPool, NVNmemoryPool *, const NVNtexture *p) { return (NVNmemoryPool *)(((const tex_t *)p)->pool); }
NVN(nvnTextureGetMemoryOffset, ptrdiff_t, const NVNtexture *p) { return (ptrdiff_t)(((const tex_t *)p)->off); }
NVN(nvnTextureBuilderGetDevice, NVNdevice *, const NVNtextureBuilder *p) { return (NVNdevice *)(((const tex_builder_t *)p)->dev); }
NVN(nvnTextureGetTextureAddress, NVNtextureAddress, const NVNtexture *p) { return (NVNtextureAddress)((uintptr_t)((const tex_t *)p)->mem); }
NVN(nvnTextureGetDebugID, uint64_t, const NVNtexture *p) { return (uint64_t)(((const tex_t *)p)->serial); }
NVN(nvnTextureViewGetLevels, NVNboolean, const NVNtextureView *v, int *base, int *n) { const view_t *o=(const view_t *)v; if (!o->set_levels) return 0; if(base)*base=o->base_level; if(n)*n=o->nlevels; return 1; }
NVN(nvnTextureViewGetFormat, NVNboolean, const NVNtextureView *v, NVNformat *out) { const view_t *o=(const view_t *)v; if (!o->set_format) return 0; if(out)*out=(NVNformat)o->format; return 1; }
NVN(nvnTextureViewGetTarget, NVNboolean, const NVNtextureView *v, NVNtextureTarget *out) { const view_t *o=(const view_t *)v; if (!o->set_target) return 0; if(out)*out=(NVNtextureTarget)o->target; return 1; }
NVN(nvnTextureViewCompare, NVNboolean, const NVNtextureView *a, const NVNtextureView *b) { return !memcmp(a,b,sizeof(view_t)); }
NVN(nvnSamplerBuilderGetDevice, NVNdevice *, const NVNsamplerBuilder *p) { return (NVNdevice *)(((const samp_builder_t *)p)->dev); }
NVN(nvnSamplerBuilderGetLodBias, float, const NVNsamplerBuilder *p) { return (&((const samp_builder_t *)p)->p)->lod_bias; }
NVN(nvnSamplerBuilderGetMaxAnisotropy, float, const NVNsamplerBuilder *p) { return (&((const samp_builder_t *)p)->p)->aniso; }
NVN(nvnSamplerBuilderGetLodClamp, void, const NVNsamplerBuilder *p, float *lo, float *hi) { const samp_par *o=&((const samp_builder_t *)p)->p;*lo=o->lod_min;*hi=o->lod_max; }
NVN(nvnSamplerBuilderGetCompare, void, const NVNsamplerBuilder *p, NVNcompareMode *mode, NVNcompareFunc *fn) { const samp_par *o=&((const samp_builder_t *)p)->p;*mode=(NVNcompareMode)o->cmp_mode;*fn=(NVNcompareFunc)o->cmp_func; }
NVN(nvnSamplerBuilderGetBorderColor, void, const NVNsamplerBuilder *p, float *color) { const samp_par *o=&((const samp_builder_t *)p)->p;memcpy(color,o->border,sizeof o->border); }
NVN(nvnSamplerGetLodBias, float, const NVNsampler *p) { return (&((const samp_t *)p)->p)->lod_bias; }
NVN(nvnSamplerGetMaxAnisotropy, float, const NVNsampler *p) { return (&((const samp_t *)p)->p)->aniso; }
NVN(nvnSamplerGetLodClamp, void, const NVNsampler *p, float *lo, float *hi) { const samp_par *o=&((const samp_t *)p)->p;*lo=o->lod_min;*hi=o->lod_max; }
NVN(nvnSamplerGetCompare, void, const NVNsampler *p, NVNcompareMode *mode, NVNcompareFunc *fn) { const samp_par *o=&((const samp_t *)p)->p;*mode=(NVNcompareMode)o->cmp_mode;*fn=(NVNcompareFunc)o->cmp_func; }
NVN(nvnSamplerGetBorderColor, void, const NVNsampler *p, float *color) { const samp_par *o=&((const samp_t *)p)->p;memcpy(color,o->border,sizeof o->border); }
NVN(nvnSamplerGetMinMagFilter, void, const NVNsampler *p, NVNminFilter *mi, NVNmagFilter *ma) { const samp_par *o=&((const samp_t *)p)->p;*mi=(NVNminFilter)o->minf;*ma=(NVNmagFilter)o->magf; }
NVN(nvnSamplerGetWrapMode, void, const NVNsampler *p, NVNwrapMode *s, NVNwrapMode *t, NVNwrapMode *r) { const samp_par *o=&((const samp_t *)p)->p;*s=(NVNwrapMode)o->ws;*t=(NVNwrapMode)o->wt;*r=(NVNwrapMode)o->wr; }
NVN(nvnSamplerCompare, NVNboolean, const NVNsampler *a, const NVNsampler *b) { return !memcmp(&((const samp_t *)a)->p,&((const samp_t *)b)->p,sizeof(samp_par)); }
NVN(nvnBlendStateGetBlendTarget, int, const NVNblendState *p) { return (int)(((const blend_st *)p)->target); }
NVN(nvnPolygonStateGetCullFace, NVNface, const NVNpolygonState *p) { return (NVNface)(((const poly_st *)p)->cull); }
NVN(nvnPolygonStateGetFrontFace, NVNfrontFace, const NVNpolygonState *p) { return (NVNfrontFace)(((const poly_st *)p)->front); }
NVN(nvnPolygonStateGetPolygonMode, NVNpolygonMode, const NVNpolygonState *p) { return (NVNpolygonMode)(((const poly_st *)p)->mode); }
NVN(nvnPolygonStateGetPolygonOffsetEnables, NVNpolygonOffsetEnable, const NVNpolygonState *p) { return (NVNpolygonOffsetEnable)(((const poly_st *)p)->offset_en); }
NVN(nvnDepthStencilStateGetDepthTestEnable, NVNboolean, const NVNdepthStencilState *p) { return (NVNboolean)(((const ds_st *)p)->dt); }
NVN(nvnDepthStencilStateGetDepthWriteEnable, NVNboolean, const NVNdepthStencilState *p) { return (NVNboolean)(((const ds_st *)p)->dw); }
NVN(nvnDepthStencilStateGetDepthFunc, NVNdepthFunc, const NVNdepthStencilState *p) { return (NVNdepthFunc)(((const ds_st *)p)->df); }
NVN(nvnDepthStencilStateGetStencilTestEnable, NVNboolean, const NVNdepthStencilState *p) { return (NVNboolean)(((const ds_st *)p)->st); }
NVN(nvnVertexAttribStateGetStreamIndex, int, const NVNvertexAttribState *p) { return (int)(((const va_st *)p)->stream); }
NVN(nvnVertexStreamStateGetStride, ptrdiff_t, const NVNvertexStreamState *p) { return (ptrdiff_t)(((const vs_st *)p)->stride); }
NVN(nvnVertexStreamStateGetDivisor, int, const NVNvertexStreamState *p) { return (int)(((const vs_st *)p)->divisor); }
NVN(nvnColorStateGetLogicOp, NVNlogicOp, const NVNcolorState *p) { return (NVNlogicOp)(((const color_st *)p)->logic_op); }
NVN(nvnColorStateGetAlphaTest, NVNalphaFunc, const NVNcolorState *p) { return (NVNalphaFunc)(((const color_st *)p)->alpha_func); }
NVN(nvnMultisampleStateGetMultisampleEnable, NVNboolean, const NVNmultisampleState *p) { return (NVNboolean)(((const ms_st *)p)->enable); }
NVN(nvnMultisampleStateGetSamples, int, const NVNmultisampleState *p) { return (int)(((const ms_st *)p)->samples); }
NVN(nvnMultisampleStateGetAlphaToCoverageEnable, NVNboolean, const NVNmultisampleState *p) { return (NVNboolean)(((const ms_st *)p)->a2c); }
NVN(nvnMultisampleStateGetSampleLocationsEnable, NVNboolean, const NVNmultisampleState *p) { return (NVNboolean)(((const ms_st *)p)->sl_en); }
NVN(nvnColorStateGetBlendEnable, NVNboolean, const NVNcolorState *s, int i) { return i>=0 && i<8 ? (((const color_st *)s)->blend_en>>i)&1 : 0; }
NVN(nvnChannelMaskStateGetChannelMask, void, const NVNchannelMaskState *s, int i, NVNboolean *r, NVNboolean *g, NVNboolean *b, NVNboolean *a) { unsigned v=i>=0 && i<8 ? ((const chmask_st *)s)->mask>>(4*i) : 0;*r=v&1;*g=(v>>1)&1;*b=(v>>2)&1;*a=(v>>3)&1; }
NVN(nvnVertexAttribStateGetFormat, void, const NVNvertexAttribState *s, NVNformat *format, ptrdiff_t *offset) { const va_st *o=(const va_st *)s;*format=(NVNformat)o->fmt;*offset=o->offset; }
NVN(nvnBlendStateGetBlendFunc, void, const NVNblendState *s, NVNblendFunc *sr, NVNblendFunc *dr, NVNblendFunc *sa, NVNblendFunc *da) { const blend_st *o=(const blend_st *)s;*sr=(NVNblendFunc)o->src_rgb;*dr=(NVNblendFunc)o->dst_rgb;*sa=(NVNblendFunc)o->src_a;*da=(NVNblendFunc)o->dst_a; }
NVN(nvnBlendStateGetBlendEquation, void, const NVNblendState *s, NVNblendEquation *r, NVNblendEquation *a) { const blend_st *o=(const blend_st *)s;*r=(NVNblendEquation)o->eq_rgb;*a=(NVNblendEquation)o->eq_a; }
NVN(nvnDepthStencilStateGetStencilFunc, NVNstencilFunc, const NVNdepthStencilState *s, NVNface f) { const ds_st *o=(const ds_st *)s;return (NVNstencilFunc)(f==NVN_FACE_BACK ? o->sf_b : o->sf_f); }
NVN(nvnDepthStencilStateGetStencilOp, void, const NVNdepthStencilState *s, NVNface f, NVNstencilOp *fail, NVNstencilOp *zfail, NVNstencilOp *pass) { const ds_st *o=(const ds_st *)s;int b=f==NVN_FACE_BACK;*fail=(NVNstencilOp)(b?o->fail_b:o->fail_f);*zfail=(NVNstencilOp)(b?o->zfail_b:o->zfail_f);*pass=(NVNstencilOp)(b?o->zpass_b:o->zpass_f); }
NVN(nvnCommandBufferGetMemoryCallback, PFNNVNCOMMANDBUFFERMEMORYCALLBACKPROC, const NVNcommandBuffer *p) { return (PFNNVNCOMMANDBUFFERMEMORYCALLBACKPROC)(((const cmd_t *)p)->cb); }
NVN(nvnCommandBufferGetMemoryCallbackData, void *, const NVNcommandBuffer *c) { return ((const cmd_t *)c)->cb_data; }
NVN(nvnDeviceSetDebugLabel, void, NVNdevice *o, const char *label) { (void)o;OLOG("debug label %s",label?label:""); }
NVN(nvnQueueSetDebugLabel, void, NVNqueue *o, const char *label) { (void)o;OLOG("debug label %s",label?label:""); }
NVN(nvnWindowSetDebugLabel, void, NVNwindow *o, const char *label) { (void)o;OLOG("debug label %s",label?label:""); }
NVN(nvnProgramSetDebugLabel, void, NVNprogram *o, const char *label) { (void)o;OLOG("debug label %s",label?label:""); }
NVN(nvnTexturePoolSetDebugLabel, void, NVNtexturePool *o, const char *label) { (void)o;OLOG("debug label %s",label?label:""); }
NVN(nvnSamplerPoolSetDebugLabel, void, NVNsamplerPool *o, const char *label) { (void)o;OLOG("debug label %s",label?label:""); }
NVN(nvnTextureSetDebugLabel, void, NVNtexture *o, const char *label) { (void)o;OLOG("debug label %s",label?label:""); }
NVN(nvnSamplerSetDebugLabel, void, NVNsampler *o, const char *label) { (void)o;OLOG("debug label %s",label?label:""); }
NVN(nvnCommandBufferSetDebugLabel, void, NVNcommandBuffer *o, const char *label) { (void)o;OLOG("debug label %s",label?label:""); }
NVN(nvnSyncSetDebugLabel, void, NVNsync *o, const char *label) { (void)o;OLOG("debug label %s",label?label:""); }
NVN(nvnCommandBufferCallCommands, void, NVNcommandBuffer *c, int n, const NVNcommandHandle *h) { h_nvnCommandBufferCopyCommands(c,n,h); }
NVN(nvnCommandBufferBindVertexBuffer, void, NVNcommandBuffer *c, int i, NVNbufferAddress a, size_t n) { NVNbufferRange r={a,n};h_nvnCommandBufferBindVertexBuffers(c,i,1,&r); }
NVN(nvnCommandBufferBindImage, void, NVNcommandBuffer *c, NVNshaderStage stage, int i, NVNimageHandle h) { h_nvnCommandBufferBindImages(c,stage,i,1,&h); }
NVN(nvnCommandBufferDrawElements, void, NVNcommandBuffer *c, NVNdrawPrimitive p, NVNindexType t, int n, NVNbufferAddress a) { h_nvnCommandBufferDrawElementsInstanced(c,p,t,n,a,0,0,1); }
NVN(nvnCommandBufferDrawElementsBaseVertex, void, NVNcommandBuffer *c, NVNdrawPrimitive p, NVNindexType t, int n, NVNbufferAddress a, int base) { h_nvnCommandBufferDrawElementsInstanced(c,p,t,n,a,base,0,1); }
NVN(nvnCommandBufferSetViewport, void, NVNcommandBuffer *c, int x, int y, int w, int h) { float v[4]={(float)x,(float)y,(float)w,(float)h};h_nvnCommandBufferSetViewports(c,0,1,v); }
