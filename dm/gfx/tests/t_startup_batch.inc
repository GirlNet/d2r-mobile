// 成组接口原生回归：真实跳板、对象往返、窄布尔输出与命令载荷；不创建 GPU。
// Batch native regressions: real thunks, object round trips, narrow boolean outputs and command payloads, without creating a GPU.

static void test_startup_batch(void) {
    uint32_t saved_origin=((dev_t_ *)&dev)->origin,saved_depth=((dev_t_ *)&dev)->depth_mode;
    uint8_t storage[131072]={0};uint8_t record[1024] __attribute__((aligned(8)));
    NVNdeviceBuilder db={0};P(nvnDeviceBuilderSetFlags)(&db,0x35);
    P(nvnDeviceSetWindowOriginMode)(&dev,(NVNwindowOriginMode)1);P(nvnDeviceSetDepthMode)(&dev,(NVNdepthMode)1);
    NVNqueueBuilder qb={0};P(nvnQueueBuilderSetDevice)(&qb,&dev);P(nvnQueueBuilderSetDefaults)(&qb);P(nvnQueueBuilderSetFlags)(&qb,0x15);
    P(nvnQueueBuilderSetCommandMemorySize)(&qb,8192);P(nvnQueueBuilderSetComputeMemorySize)(&qb,16384);P(nvnQueueBuilderSetControlMemorySize)(&qb,32768);
    P(nvnQueueBuilderSetCommandFlushThreshold)(&qb,1024);P(nvnQueueBuilderSetQueueMemory)(&qb,storage,512);NVNqueue queue;P(nvnQueueInitialize)(&queue,&qb);
    NVNmemoryPool pool={0};*(pool_t *)&pool=(pool_t){.magic=MAGIC('P','O','O','L'),.flags=0x22,.mem=storage,.size=sizeof storage};
    NVNtextureBuilder tb={0};P(nvnTextureBuilderSetDevice)(&tb,&dev);P(nvnTextureBuilderSetDefaults)(&tb);
    P(nvnTextureBuilderSetTarget)(&tb,NVN_TEXTURE_TARGET_3D);P(nvnTextureBuilderSetWidth)(&tb,32);P(nvnTextureBuilderSetHeight)(&tb,16);P(nvnTextureBuilderSetDepth)(&tb,4);
    P(nvnTextureBuilderSetLevels)(&tb,3);P(nvnTextureBuilderSetFormat)(&tb,NVN_FORMAT_RGBA8);P(nvnTextureBuilderSetSamples)(&tb,1);P(nvnTextureBuilderSetStride)(&tb,128);P(nvnTextureBuilderSetStorage)(&tb,&pool,128);
    NVNtexture tex;EXPECT("batch CPU texture initialize",1,P(nvnTextureInitialize)(&tex,&tb));
    NVNwindowBuilder wb={0};P(nvnWindowBuilderSetDevice)(&wb,&dev);P(nvnWindowBuilderSetDefaults)(&wb);P(nvnWindowBuilderSetNativeWindow)(&wb,storage);
    NVNtexture *textures[2]={&tex,&tex};P(nvnWindowBuilderSetTextures)(&wb,2,textures);P(nvnWindowBuilderSetPresentInterval)(&wb,2);
    NVNwindow window={0};win_t *w=(win_t *)&window;w->native=storage;w->interval=2;P(nvnWindowSetCrop)(&window,2,3,40,50);
    NVNtexturePool tp={0};NVNsamplerPool sp={0};*(dpool_t *)&tp=(dpool_t){(pool_t *)&pool,64,4};*(dpool_t *)&sp=*(dpool_t *)&tp;
    NVNtextureView view={0};P(nvnTextureViewSetDefaults)(&view);
    NVNsamplerBuilder sb={0};P(nvnSamplerBuilderSetDevice)(&sb,&dev);P(nvnSamplerBuilderSetDefaults)(&sb);
    P(nvnSamplerBuilderSetMinMagFilter)(&sb,NVN_MIN_FILTER_LINEAR,NVN_MAG_FILTER_NEAREST);
    P(nvnSamplerBuilderSetWrapMode)(&sb,NVN_WRAP_MODE_CLAMP_TO_EDGE,NVN_WRAP_MODE_REPEAT,NVN_WRAP_MODE_MIRRORED_REPEAT);
    P(nvnSamplerBuilderSetLodClamp)(&sb,-2.f,8.f);P(nvnSamplerBuilderSetLodBias)(&sb,1.25f);P(nvnSamplerBuilderSetMaxAnisotropy)(&sb,4.f);
    P(nvnSamplerBuilderSetCompare)(&sb,NVN_COMPARE_MODE_COMPARE_R_TO_TEXTURE,NVN_COMPARE_FUNC_GEQUAL);float border[4]={.25f,.5f,.75f,1.f};P(nvnSamplerBuilderSetBorderColor)(&sb,border);
    NVNsampler sampler;P(nvnSamplerInitialize)(&sampler,&sb);
    NVNblendState blend;P(nvnBlendStateSetDefaults)(&blend);P(nvnBlendStateSetBlendTarget)(&blend,3);
    P(nvnBlendStateSetBlendFunc)(&blend,NVN_BLEND_FUNC_SRC_ALPHA,NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA,NVN_BLEND_FUNC_ONE,NVN_BLEND_FUNC_ZERO);
    P(nvnBlendStateSetBlendEquation)(&blend,NVN_BLEND_EQUATION_SUB,NVN_BLEND_EQUATION_ADD);
    NVNpolygonState poly;P(nvnPolygonStateSetDefaults)(&poly);P(nvnPolygonStateSetCullFace)(&poly,NVN_FACE_BACK);P(nvnPolygonStateSetFrontFace)(&poly,NVN_FRONT_FACE_CW);P(nvnPolygonStateSetPolygonMode)(&poly,NVN_POLYGON_MODE_LINE);P(nvnPolygonStateSetPolygonOffsetEnables)(&poly,3);
    NVNdepthStencilState depth;P(nvnDepthStencilStateSetDefaults)(&depth);P(nvnDepthStencilStateSetDepthTestEnable)(&depth,0x101);P(nvnDepthStencilStateSetDepthWriteEnable)(&depth,0x100);P(nvnDepthStencilStateSetDepthFunc)(&depth,NVN_DEPTH_FUNC_GEQUAL);P(nvnDepthStencilStateSetStencilTestEnable)(&depth,1);
    P(nvnDepthStencilStateSetStencilFunc)(&depth,NVN_FACE_FRONT,NVN_STENCIL_FUNC_LESS);P(nvnDepthStencilStateSetStencilFunc)(&depth,NVN_FACE_BACK,NVN_STENCIL_FUNC_GREATER);
    P(nvnDepthStencilStateSetStencilOp)(&depth,NVN_FACE_BACK,NVN_STENCIL_OP_REPLACE,NVN_STENCIL_OP_ZERO,NVN_STENCIL_OP_KEEP);
    NVNvertexAttribState attrib;P(nvnVertexAttribStateSetDefaults)(&attrib);P(nvnVertexAttribStateSetFormat)(&attrib,NVN_FORMAT_RGBA8,48);P(nvnVertexAttribStateSetStreamIndex)(&attrib,3);
    NVNvertexStreamState stream;P(nvnVertexStreamStateSetDefaults)(&stream);P(nvnVertexStreamStateSetStride)(&stream,256);P(nvnVertexStreamStateSetDivisor)(&stream,7);
    NVNcolorState colorState;P(nvnColorStateSetDefaults)(&colorState);P(nvnColorStateSetBlendEnable)(&colorState,2,0x101);
    NVNchannelMaskState channel;P(nvnChannelMaskStateSetDefaults)(&channel);P(nvnChannelMaskStateSetChannelMask)(&channel,3,0x101,0x100,1,0);
    NVNmultisampleState ms;P(nvnMultisampleStateSetDefaults)(&ms);P(nvnMultisampleStateSetSamples)(&ms,4);P(nvnMultisampleStateSetAlphaToCoverageEnable)(&ms,1);P(nvnMultisampleStateSetSampleLocationsEnable)(&ms,1);
    NVNcommandBuffer command;P(nvnCommandBufferInitialize)(&command,&dev);P(nvnCommandBufferSetMemoryCallback)(&command,mem_cb);P(nvnCommandBufferSetMemoryCallbackData)(&command,storage);
    NVNprogram program;P(nvnProgramInitialize)(&program,&dev);NVNsync sync;P(nvnSyncInitialize)(&sync,&dev);
EXPECT("nvnDeviceBuilderGetFlags",(long long)(53),(long long)(uintptr_t)P(nvnDeviceBuilderGetFlags)(&db));
EXPECT("nvnDeviceGetWindowOriginMode",(long long)(1),(long long)(uintptr_t)P(nvnDeviceGetWindowOriginMode)(&dev));
EXPECT("nvnDeviceGetDepthMode",(long long)(1),(long long)(uintptr_t)P(nvnDeviceGetDepthMode)(&dev));
EXPECT("nvnQueueBuilderGetDevice",(long long)((uintptr_t)&dev),(long long)(uintptr_t)P(nvnQueueBuilderGetDevice)(&qb));
EXPECT("nvnQueueBuilderGetFlags",(long long)(21),(long long)(uintptr_t)P(nvnQueueBuilderGetFlags)(&qb));
EXPECT("nvnQueueBuilderGetCommandMemorySize",(long long)(8192),(long long)(uintptr_t)P(nvnQueueBuilderGetCommandMemorySize)(&qb));
EXPECT("nvnQueueBuilderGetComputeMemorySize",(long long)(16384),(long long)(uintptr_t)P(nvnQueueBuilderGetComputeMemorySize)(&qb));
EXPECT("nvnQueueBuilderGetControlMemorySize",(long long)(32768),(long long)(uintptr_t)P(nvnQueueBuilderGetControlMemorySize)(&qb));
EXPECT("nvnQueueBuilderGetCommandFlushThreshold",(long long)(1024),(long long)(uintptr_t)P(nvnQueueBuilderGetCommandFlushThreshold)(&qb));
EXPECT("nvnQueueBuilderGetMemorySize",(long long)(512),(long long)(uintptr_t)P(nvnQueueBuilderGetMemorySize)(&qb));
EXPECT("nvnQueueBuilderGetMemory",(long long)((uintptr_t)storage),(long long)(uintptr_t)P(nvnQueueBuilderGetMemory)(&qb));
EXPECT("nvnWindowBuilderGetDevice",(long long)((uintptr_t)&dev),(long long)(uintptr_t)P(nvnWindowBuilderGetDevice)(&wb));
EXPECT("nvnWindowBuilderGetNumTextures",(long long)(2),(long long)(uintptr_t)P(nvnWindowBuilderGetNumTextures)(&wb));
EXPECT("nvnWindowBuilderGetNativeWindow",(long long)((uintptr_t)storage),(long long)(uintptr_t)P(nvnWindowBuilderGetNativeWindow)(&wb));
EXPECT("nvnWindowBuilderGetPresentInterval",(long long)(2),(long long)(uintptr_t)P(nvnWindowBuilderGetPresentInterval)(&wb));
EXPECT("window indexed texture",(uintptr_t)&tex,P(nvnWindowBuilderGetTexture)(&wb,1)); EXPECT("window texture bounds",0,(uintptr_t)P(nvnWindowBuilderGetTexture)(&wb,2));
EXPECT("nvnWindowGetNativeWindow",(long long)((uintptr_t)storage),(long long)(uintptr_t)P(nvnWindowGetNativeWindow)(&window));
EXPECT("nvnWindowGetPresentInterval",(long long)(2),(long long)(uintptr_t)P(nvnWindowGetPresentInterval)(&window));
NVNrectangle crop;P(nvnWindowGetCrop)(&window,&crop);int cr[4];memcpy(cr,&crop,sizeof cr);EXPECT("window crop",1,cr[0]==2 && cr[1]==3 && cr[2]==40 && cr[3]==50);
EXPECT("nvnTexturePoolGetMemoryPool",(long long)((uintptr_t)&pool),(long long)(uintptr_t)P(nvnTexturePoolGetMemoryPool)(&tp));
EXPECT("nvnTexturePoolGetMemoryOffset",(long long)(64),(long long)(uintptr_t)P(nvnTexturePoolGetMemoryOffset)(&tp));
EXPECT("nvnTexturePoolGetSize",(long long)(4),(long long)(uintptr_t)P(nvnTexturePoolGetSize)(&tp));
EXPECT("nvnSamplerPoolGetMemoryPool",(long long)((uintptr_t)&pool),(long long)(uintptr_t)P(nvnSamplerPoolGetMemoryPool)(&sp));
EXPECT("nvnSamplerPoolGetMemoryOffset",(long long)(64),(long long)(uintptr_t)P(nvnSamplerPoolGetMemoryOffset)(&sp));
EXPECT("nvnSamplerPoolGetSize",(long long)(4),(long long)(uintptr_t)P(nvnSamplerPoolGetSize)(&sp));
P(nvnTextureBuilderSetSize2D)(&tb,32,16);EXPECT("2D size",1,TB(&tb)->d.width==32 && TB(&tb)->d.height==16 && TB(&tb)->d.depth==1);
P(nvnTextureBuilderSetSize3D)(&tb,32,16,4);EXPECT("3D size",1,TB(&tb)->d.width==32 && TB(&tb)->d.height==16 && TB(&tb)->d.depth==4);
EXPECT("nvnTextureBuilderGetTarget",(long long)(NVN_TEXTURE_TARGET_3D),(long long)(uintptr_t)P(nvnTextureBuilderGetTarget)(&tb));
EXPECT("nvnTextureGetTarget",(long long)(NVN_TEXTURE_TARGET_3D),(long long)(uintptr_t)P(nvnTextureGetTarget)(&tex));
EXPECT("nvnTextureBuilderGetWidth",(long long)(32),(long long)(uintptr_t)P(nvnTextureBuilderGetWidth)(&tb));
EXPECT("nvnTextureBuilderGetHeight",(long long)(16),(long long)(uintptr_t)P(nvnTextureBuilderGetHeight)(&tb));
EXPECT("nvnTextureBuilderGetDepth",(long long)(4),(long long)(uintptr_t)P(nvnTextureBuilderGetDepth)(&tb));
EXPECT("nvnTextureBuilderGetLevels",(long long)(3),(long long)(uintptr_t)P(nvnTextureBuilderGetLevels)(&tb));
EXPECT("nvnTextureGetLevels",(long long)(3),(long long)(uintptr_t)P(nvnTextureGetLevels)(&tex));
EXPECT("nvnTextureBuilderGetFormat",(long long)(NVN_FORMAT_RGBA8),(long long)(uintptr_t)P(nvnTextureBuilderGetFormat)(&tb));
EXPECT("nvnTextureGetFormat",(long long)(NVN_FORMAT_RGBA8),(long long)(uintptr_t)P(nvnTextureGetFormat)(&tex));
EXPECT("nvnTextureBuilderGetSamples",(long long)(1),(long long)(uintptr_t)P(nvnTextureBuilderGetSamples)(&tb));
EXPECT("nvnTextureGetSamples",(long long)(1),(long long)(uintptr_t)P(nvnTextureGetSamples)(&tex));
EXPECT("nvnTextureBuilderGetStride",(long long)(128),(long long)(uintptr_t)P(nvnTextureBuilderGetStride)(&tb));
EXPECT("nvnTextureGetStride",(long long)(128),(long long)(uintptr_t)P(nvnTextureGetStride)(&tex));
EXPECT("nvnTextureBuilderGetMemoryPool",(long long)((uintptr_t)&pool),(long long)(uintptr_t)P(nvnTextureBuilderGetMemoryPool)(&tb));
EXPECT("nvnTextureBuilderGetMemoryOffset",(long long)(128),(long long)(uintptr_t)P(nvnTextureBuilderGetMemoryOffset)(&tb));
EXPECT("nvnTextureGetMemoryPool",(long long)((uintptr_t)&pool),(long long)(uintptr_t)P(nvnTextureGetMemoryPool)(&tex));
EXPECT("nvnTextureGetMemoryOffset",(long long)(128),(long long)(uintptr_t)P(nvnTextureGetMemoryOffset)(&tex));
EXPECT("nvnTextureBuilderGetDevice",(long long)((uintptr_t)&dev),(long long)(uintptr_t)P(nvnTextureBuilderGetDevice)(&tb));
EXPECT("nvnTextureGetTextureAddress",(long long)((uintptr_t)(storage+128)),(long long)(uintptr_t)P(nvnTextureGetTextureAddress)(&tex));
EXPECT("texture debug lifetime ID",1,P(nvnTextureGetDebugID)(&tex)>0);
int base=99,nlevels=99;EXPECT("unset view leaves output",0,P(nvnTextureViewGetLevels)(&view,&base,&nlevels));EXPECT("unset output preserved",99,base);P(nvnTextureViewSetLevels)(&view,1,2);EXPECT("view levels present",1,P(nvnTextureViewGetLevels)(&view,&base,&nlevels));EXPECT("view levels",1,base==1 && nlevels==2);
NVNformat viewFormat;P(nvnTextureViewSetFormat)(&view,NVN_FORMAT_RGBA8);EXPECT("view Format presence",1,P(nvnTextureViewGetFormat)(&view,&viewFormat));EXPECT("view Format",NVN_FORMAT_RGBA8,viewFormat);
NVNtextureTarget viewTarget;P(nvnTextureViewSetTarget)(&view,NVN_TEXTURE_TARGET_3D);EXPECT("view Target presence",1,P(nvnTextureViewGetTarget)(&view,&viewTarget));EXPECT("view Target",NVN_TEXTURE_TARGET_3D,viewTarget);
NVNtextureView viewCopy=view;EXPECT("view value comparison",1,P(nvnTextureViewCompare)(&view,&viewCopy));P(nvnTextureViewSetLevels)(&viewCopy,2,1);EXPECT("different view comparison",0,P(nvnTextureViewCompare)(&view,&viewCopy));
EXPECT("nvnSamplerBuilderGetDevice",(long long)((uintptr_t)&dev),(long long)(uintptr_t)P(nvnSamplerBuilderGetDevice)(&sb));
EXPECT("nvnSamplerBuilderGetLodBias",1,P(nvnSamplerBuilderGetLodBias)(&sb)==1.25f);
EXPECT("nvnSamplerBuilderGetMaxAnisotropy",1,P(nvnSamplerBuilderGetMaxAnisotropy)(&sb)==4.f);
{float lo,hi;P(nvnSamplerBuilderGetLodClamp)(&sb,&lo,&hi);EXPECT("lod clamp",1,lo==-2.f && hi==8.f);}
{NVNcompareMode mode;NVNcompareFunc fn;P(nvnSamplerBuilderGetCompare)(&sb,&mode,&fn);EXPECT("sampler compare",1,mode==NVN_COMPARE_MODE_COMPARE_R_TO_TEXTURE && fn==NVN_COMPARE_FUNC_GEQUAL);}
{float color[4];P(nvnSamplerBuilderGetBorderColor)(&sb,color);EXPECT("sampler border",1,color[0]==0.25f && color[1]==0.5f && color[2]==0.75f && color[3]==1.f);}
EXPECT("nvnSamplerGetLodBias",1,P(nvnSamplerGetLodBias)(&sampler)==1.25f);
EXPECT("nvnSamplerGetMaxAnisotropy",1,P(nvnSamplerGetMaxAnisotropy)(&sampler)==4.f);
{float lo,hi;P(nvnSamplerGetLodClamp)(&sampler,&lo,&hi);EXPECT("lod clamp",1,lo==-2.f && hi==8.f);}
{NVNcompareMode mode;NVNcompareFunc fn;P(nvnSamplerGetCompare)(&sampler,&mode,&fn);EXPECT("sampler compare",1,mode==NVN_COMPARE_MODE_COMPARE_R_TO_TEXTURE && fn==NVN_COMPARE_FUNC_GEQUAL);}
{float color[4];P(nvnSamplerGetBorderColor)(&sampler,color);EXPECT("sampler border",1,color[0]==0.25f && color[1]==0.5f && color[2]==0.75f && color[3]==1.f);}
{NVNminFilter mi;NVNmagFilter ma;P(nvnSamplerGetMinMagFilter)(&sampler,&mi,&ma);EXPECT("sampler filter",1,mi==NVN_MIN_FILTER_LINEAR && ma==NVN_MAG_FILTER_NEAREST);}
{NVNwrapMode ws,wt,wr;P(nvnSamplerGetWrapMode)(&sampler,&ws,&wt,&wr);EXPECT("sampler wrap",1,ws==NVN_WRAP_MODE_CLAMP_TO_EDGE && wt==NVN_WRAP_MODE_REPEAT && wr==NVN_WRAP_MODE_MIRRORED_REPEAT);}
NVNsampler samplerCopy=sampler;EXPECT("sampler copy",1,P(nvnSamplerCompare)(&sampler,&samplerCopy));((samp_t *)&samplerCopy)->p.aniso=8;EXPECT("sampler differs",0,P(nvnSamplerCompare)(&sampler,&samplerCopy));
EXPECT("nvnBlendStateGetBlendTarget",(long long)(3),(long long)(uintptr_t)P(nvnBlendStateGetBlendTarget)(&blend));
EXPECT("nvnPolygonStateGetCullFace",(long long)(NVN_FACE_BACK),(long long)(uintptr_t)P(nvnPolygonStateGetCullFace)(&poly));
EXPECT("nvnPolygonStateGetFrontFace",(long long)(NVN_FRONT_FACE_CW),(long long)(uintptr_t)P(nvnPolygonStateGetFrontFace)(&poly));
EXPECT("nvnPolygonStateGetPolygonMode",(long long)(NVN_POLYGON_MODE_LINE),(long long)(uintptr_t)P(nvnPolygonStateGetPolygonMode)(&poly));
EXPECT("nvnPolygonStateGetPolygonOffsetEnables",(long long)(3),(long long)(uintptr_t)P(nvnPolygonStateGetPolygonOffsetEnables)(&poly));
EXPECT("nvnDepthStencilStateGetDepthTestEnable",(long long)(1),(long long)(uintptr_t)P(nvnDepthStencilStateGetDepthTestEnable)(&depth));
EXPECT("nvnDepthStencilStateGetDepthWriteEnable",(long long)(0),(long long)(uintptr_t)P(nvnDepthStencilStateGetDepthWriteEnable)(&depth));
EXPECT("nvnDepthStencilStateGetDepthFunc",(long long)(NVN_DEPTH_FUNC_GEQUAL),(long long)(uintptr_t)P(nvnDepthStencilStateGetDepthFunc)(&depth));
EXPECT("nvnDepthStencilStateGetStencilTestEnable",(long long)(1),(long long)(uintptr_t)P(nvnDepthStencilStateGetStencilTestEnable)(&depth));
EXPECT("nvnVertexAttribStateGetStreamIndex",(long long)(3),(long long)(uintptr_t)P(nvnVertexAttribStateGetStreamIndex)(&attrib));
EXPECT("nvnVertexStreamStateGetStride",(long long)(256),(long long)(uintptr_t)P(nvnVertexStreamStateGetStride)(&stream));
EXPECT("nvnVertexStreamStateGetDivisor",(long long)(7),(long long)(uintptr_t)P(nvnVertexStreamStateGetDivisor)(&stream));
EXPECT("nvnColorStateGetLogicOp",(long long)(NVN_LOGIC_OP_COPY),(long long)(uintptr_t)P(nvnColorStateGetLogicOp)(&colorState));
EXPECT("nvnColorStateGetAlphaTest",(long long)(NVN_ALPHA_FUNC_ALWAYS),(long long)(uintptr_t)P(nvnColorStateGetAlphaTest)(&colorState));
EXPECT("nvnMultisampleStateGetMultisampleEnable",(long long)(1),(long long)(uintptr_t)P(nvnMultisampleStateGetMultisampleEnable)(&ms));
EXPECT("nvnMultisampleStateGetSamples",(long long)(4),(long long)(uintptr_t)P(nvnMultisampleStateGetSamples)(&ms));
EXPECT("nvnMultisampleStateGetAlphaToCoverageEnable",(long long)(1),(long long)(uintptr_t)P(nvnMultisampleStateGetAlphaToCoverageEnable)(&ms));
EXPECT("nvnMultisampleStateGetSampleLocationsEnable",(long long)(1),(long long)(uintptr_t)P(nvnMultisampleStateGetSampleLocationsEnable)(&ms));
EXPECT("blend enable",1,P(nvnColorStateGetBlendEnable)(&colorState,2));EXPECT("blend enable bounds",0,P(nvnColorStateGetBlendEnable)(&colorState,8));
struct {uint8_t before;NVNboolean r,g,b,a;uint8_t after;} mask={.before=0xa5,.after=0x5a};P(nvnChannelMaskStateGetChannelMask)(&channel,3,&mask.r,&mask.g,&mask.b,&mask.a);EXPECT("mask narrow ABI and guards",1,mask.r==1 && mask.g==0 && mask.b==1 && mask.a==0 && mask.before==0xa5 && mask.after==0x5a);
NVNformat af;ptrdiff_t ao;P(nvnVertexAttribStateGetFormat)(&attrib,&af,&ao);EXPECT("vertex format",1,af==NVN_FORMAT_RGBA8 && ao==48);
NVNblendFunc sr,dr,sa,da;P(nvnBlendStateGetBlendFunc)(&blend,&sr,&dr,&sa,&da);EXPECT("blend funcs",1,sr==NVN_BLEND_FUNC_SRC_ALPHA && dr==NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA && sa==NVN_BLEND_FUNC_ONE && da==NVN_BLEND_FUNC_ZERO);
NVNblendEquation er,ea;P(nvnBlendStateGetBlendEquation)(&blend,&er,&ea);EXPECT("blend equations",1,er==NVN_BLEND_EQUATION_SUB && ea==NVN_BLEND_EQUATION_ADD);
EXPECT("front stencil",NVN_STENCIL_FUNC_LESS,P(nvnDepthStencilStateGetStencilFunc)(&depth,NVN_FACE_FRONT));EXPECT("back stencil",NVN_STENCIL_FUNC_GREATER,P(nvnDepthStencilStateGetStencilFunc)(&depth,NVN_FACE_BACK));
NVNstencilOp fail,zfail,pass;P(nvnDepthStencilStateGetStencilOp)(&depth,NVN_FACE_BACK,&fail,&zfail,&pass);EXPECT("stencil operations",1,fail==NVN_STENCIL_OP_REPLACE && zfail==NVN_STENCIL_OP_ZERO && pass==NVN_STENCIL_OP_KEEP);
EXPECT("nvnCommandBufferGetMemoryCallback",(long long)((uintptr_t)mem_cb),(long long)(uintptr_t)P(nvnCommandBufferGetMemoryCallback)(&command));
EXPECT("callback data pointer ABI",(uintptr_t)storage,(uintptr_t)P(nvnCommandBufferGetMemoryCallbackData)(&command));
P(nvnDeviceSetDebugLabel)(&dev,"synthetic");
P(nvnQueueSetDebugLabel)(&queue,"synthetic");
P(nvnWindowSetDebugLabel)(&window,"synthetic");
P(nvnProgramSetDebugLabel)(&program,"synthetic");
P(nvnTexturePoolSetDebugLabel)(&tp,"synthetic");
P(nvnSamplerPoolSetDebugLabel)(&sp,"synthetic");
P(nvnTextureSetDebugLabel)(&tex,"synthetic");
P(nvnSamplerSetDebugLabel)(&sampler,"synthetic");
P(nvnCommandBufferSetDebugLabel)(&command,"synthetic");
P(nvnSyncSetDebugLabel)(&sync,"synthetic");
{CB(&command)->cur=record;CB(&command)->end=record+sizeof record;NVNcommandHandle handle=0x12345000;P(nvnCommandBufferCallCommands)(&command,1,&handle);EXPECT("call record",1,((op_hdr *)record)->op==OP_CALL && !memcmp(record+8,&handle,8));}
{CB(&command)->cur=record;CB(&command)->end=record+sizeof record;P(nvnCommandBufferBindVertexBuffer)(&command,2,0x12340000,256);const p_bind_vbuf *vb=(const p_bind_vbuf *)(record+8);EXPECT("single vertex buffer",1,((op_hdr *)record)->op==OP_BIND_VBUF && vb->first==2 && vb->n==1 && vb->r[0].address==0x12340000 && vb->r[0].size==256);}
{CB(&command)->cur=record;CB(&command)->end=record+sizeof record;P(nvnCommandBufferBindImage)(&command,NVN_SHADER_STAGE_FRAGMENT,2,7);const p_bind_handles *bi=(const p_bind_handles *)(record+8);EXPECT("single image",1,((op_hdr *)record)->op==OP_BIND_IMG && bi->first==2 && bi->n==1 && bi->h[0]==7);}
{CB(&command)->cur=record;CB(&command)->end=record+sizeof record;P(nvnCommandBufferDrawElements)(&command,NVN_DRAW_PRIMITIVE_TRIANGLES,NVN_INDEX_TYPE_UNSIGNED_SHORT,6,0x12340000);const p_draw_idx *di=(const p_draw_idx *)(record+8);EXPECT("indexed draw",1,((op_hdr *)record)->op==OP_DRAW_IDX && di->count==6 && di->instances==1 && di->base_vertex==0 && di->ibuf==0x12340000);}
{CB(&command)->cur=record;CB(&command)->end=record+sizeof record;P(nvnCommandBufferDrawElementsBaseVertex)(&command,NVN_DRAW_PRIMITIVE_TRIANGLES,NVN_INDEX_TYPE_UNSIGNED_SHORT,6,0x12340000,-5);EXPECT("base vertex draw",-5,((const p_draw_idx *)(record+8))->base_vertex);}
{CB(&command)->cur=record;CB(&command)->end=record+sizeof record;P(nvnCommandBufferSetViewport)(&command,2,3,640,480);const p_viewports *vp=(const p_viewports *)(record+8);EXPECT("single viewport",1,((op_hdr *)record)->op==OP_VIEWPORTS && vp->n==1 && vp->v[0][0]==2 && vp->v[0][2]==640);}
{CB(&command)->cur=record;CB(&command)->end=record+sizeof record;P(nvnCommandBufferSetSampleMask)(&command,-1);EXPECT("sample mask command",1,((op_hdr *)record)->op==OP_SAMPLE_MASK && *(const uint32_t *)(record+8)==UINT32_MAX);}
{CB(&command)->cur=record;CB(&command)->end=record+sizeof record;P(nvnCommandBufferSetRenderEnable)(&command,0x101);EXPECT("render enable command",1,((op_hdr *)record)->op==OP_RENDER_ENABLE && *(const uint32_t *)(record+8)==1);}
{CB(&command)->cur=record;CB(&command)->end=record+sizeof record;P(nvnCommandBufferSetConservativeRasterEnable)(&command,0x100);EXPECT("conservative default command",1,((op_hdr *)record)->op==OP_CONSERVATIVE_RASTER && *(const uint32_t *)(record+8)==0);}
    EXPECT("scratch bounded reservation",1,nvn_shader_scratch_valid((pool_t *)&pool,4096,16384));
    EXPECT("scratch end zero size",1,nvn_shader_scratch_valid((pool_t *)&pool,sizeof storage,0));
    EXPECT("scratch reset",1,nvn_shader_scratch_valid(NULL,0,0));
    EXPECT("scratch missing pool",0,nvn_shader_scratch_valid(NULL,0,1));
    EXPECT("scratch negative offset",0,nvn_shader_scratch_valid((pool_t *)&pool,-1,0));
    EXPECT("scratch offset overflow",0,nvn_shader_scratch_valid((pool_t *)&pool,sizeof storage+1,0));
    EXPECT("scratch size overflow",0,nvn_shader_scratch_valid((pool_t *)&pool,1,SIZE_MAX));
    pool_t badScratchPool={0};EXPECT("scratch invalid pool",0,nvn_shader_scratch_valid(&badScratchPool,0,0));
    uint8_t *savedCommandCursor=CB(&command)->cur;
    P(nvnCommandBufferSetShaderScratchMemory)(&command,&pool,4096,16384);
    P(nvnCommandBufferSetShaderScratchMemory)(&command,NULL,0,0);
    EXPECT("Metal owns private scratch; no guest command allocation",1,CB(&command)->cur==savedCommandCursor);

    EXPECT("host builder storage class",0x100,P(nvnTextureBuilderGetStorageClass)(&tb));
    EXPECT("host texture storage class",0x100,P(nvnTextureGetStorageClass)(&tex));
    NVNtextureBuilder invalidBuilder=tb;P(nvnTextureBuilderSetFormat)(&invalidBuilder,NVN_FORMAT_NONE);
    EXPECT("invalid storage format rejected",0,P(nvnTextureBuilderGetStorageClass)(&invalidBuilder));
    EXPECT("null storage class queries",0,P(nvnTextureBuilderGetStorageClass)(NULL)+P(nvnTextureGetStorageClass)(NULL));
    NVNtexture invalidTexture={0};EXPECT("invalid texture class",0,P(nvnTextureGetStorageClass)(&invalidTexture));
    EXPECT("default dither metadata",0,P(nvnMultisampleStateGetAlphaToCoverageDither)(&ms));
    EXPECT("default raster sample metadata",0,P(nvnMultisampleStateGetRasterSamples)(&ms));
    { struct {NVNmultisampleState value;uint8_t guard[8];} guarded;memset(&guarded,0xa7,sizeof guarded);
      P(nvnMultisampleStateSetDefaults)(&guarded.value);
      P(nvnMultisampleStateSetAlphaToCoverageDither)(&guarded.value,0x101);
      P(nvnMultisampleStateSetRasterSamples)(&guarded.value,4);
      EXPECT("normal dither setter",1,P(nvnMultisampleStateGetAlphaToCoverageDither)(&guarded.value));
      EXPECT("normal raster setter",4,P(nvnMultisampleStateGetRasterSamples)(&guarded.value));
      EXPECT("inactive dither allowed",0,nvn_multisample_unsupported((ms_st *)&guarded.value,4));
      P(nvnMultisampleStateSetAlphaToCoverageEnable)(&guarded.value,1);
      EXPECT("active dither rejected",2,nvn_multisample_unsupported((ms_st *)&guarded.value,4));
      P(nvnMultisampleStateSetAlphaToCoverageDither)(&guarded.value,0x100);
      EXPECT("dither boolean low byte",0,P(nvnMultisampleStateGetAlphaToCoverageDither)(&guarded.value));
      EXPECT("matching raster supported",0,nvn_multisample_unsupported((ms_st *)&guarded.value,4));
      EXPECT("mixed raster rejected",1,nvn_multisample_unsupported((ms_st *)&guarded.value,2));
      P(nvnMultisampleStateSetRasterSamples)(&guarded.value,0);
      EXPECT("default raster supported",0,nvn_multisample_unsupported((ms_st *)&guarded.value,2));
      for(unsigned i=0;i<sizeof guarded.guard;i++)EXPECT("multisample setter guard",0xa7,guarded.guard[i]);
    }
    const char *batch_names[]={"nvnTextureBuilderGetStorageClass","nvnTextureGetStorageClass","nvnMultisampleStateGetAlphaToCoverageDither","nvnMultisampleStateGetRasterSamples","nvnDeviceBuilderGetFlags","nvnDeviceGetWindowOriginMode","nvnDeviceGetDepthMode","nvnQueueBuilderGetDevice","nvnQueueBuilderGetFlags","nvnQueueBuilderGetCommandMemorySize","nvnQueueBuilderGetComputeMemorySize","nvnQueueBuilderGetControlMemorySize","nvnQueueBuilderGetCommandFlushThreshold","nvnQueueBuilderGetMemorySize","nvnQueueBuilderGetMemory","nvnWindowBuilderGetDevice","nvnWindowBuilderGetNumTextures","nvnWindowBuilderGetNativeWindow","nvnWindowBuilderGetPresentInterval","nvnWindowBuilderGetTexture","nvnWindowGetNativeWindow","nvnWindowGetPresentInterval","nvnWindowGetCrop","nvnTexturePoolGetMemoryPool","nvnTexturePoolGetMemoryOffset","nvnTexturePoolGetSize","nvnSamplerPoolGetMemoryPool","nvnSamplerPoolGetMemoryOffset","nvnSamplerPoolGetSize","nvnTextureBuilderSetSize2D","nvnTextureBuilderSetSize3D","nvnTextureBuilderGetTarget","nvnTextureGetTarget","nvnTextureBuilderGetWidth","nvnTextureBuilderGetHeight","nvnTextureBuilderGetDepth","nvnTextureBuilderGetLevels","nvnTextureGetLevels","nvnTextureBuilderGetFormat","nvnTextureGetFormat","nvnTextureBuilderGetSamples","nvnTextureGetSamples","nvnTextureBuilderGetStride","nvnTextureGetStride","nvnTextureBuilderGetMemoryPool","nvnTextureBuilderGetMemoryOffset","nvnTextureGetMemoryPool","nvnTextureGetMemoryOffset","nvnTextureBuilderGetDevice","nvnTextureGetTextureAddress","nvnTextureGetDebugID","nvnTextureViewGetLevels","nvnTextureViewGetFormat","nvnTextureViewGetTarget","nvnTextureViewCompare","nvnSamplerBuilderGetDevice","nvnSamplerBuilderGetLodBias","nvnSamplerBuilderGetMaxAnisotropy","nvnSamplerBuilderGetLodClamp","nvnSamplerBuilderGetCompare","nvnSamplerBuilderGetBorderColor","nvnSamplerGetLodBias","nvnSamplerGetMaxAnisotropy","nvnSamplerGetLodClamp","nvnSamplerGetCompare","nvnSamplerGetBorderColor","nvnSamplerGetMinMagFilter","nvnSamplerGetWrapMode","nvnSamplerCompare","nvnBlendStateGetBlendTarget","nvnPolygonStateGetCullFace","nvnPolygonStateGetFrontFace","nvnPolygonStateGetPolygonMode","nvnPolygonStateGetPolygonOffsetEnables","nvnDepthStencilStateGetDepthTestEnable","nvnDepthStencilStateGetDepthWriteEnable","nvnDepthStencilStateGetDepthFunc","nvnDepthStencilStateGetStencilTestEnable","nvnVertexAttribStateGetStreamIndex","nvnVertexStreamStateGetStride","nvnVertexStreamStateGetDivisor","nvnColorStateGetLogicOp","nvnColorStateGetAlphaTest","nvnMultisampleStateGetMultisampleEnable","nvnMultisampleStateGetSamples","nvnMultisampleStateGetAlphaToCoverageEnable","nvnMultisampleStateGetSampleLocationsEnable","nvnColorStateGetBlendEnable","nvnChannelMaskStateGetChannelMask","nvnVertexAttribStateGetFormat","nvnBlendStateGetBlendFunc","nvnBlendStateGetBlendEquation","nvnDepthStencilStateGetStencilFunc","nvnDepthStencilStateGetStencilOp","nvnCommandBufferGetMemoryCallback","nvnCommandBufferGetMemoryCallbackData","nvnDeviceSetDebugLabel","nvnQueueSetDebugLabel","nvnWindowSetDebugLabel","nvnProgramSetDebugLabel","nvnTexturePoolSetDebugLabel","nvnSamplerPoolSetDebugLabel","nvnTextureSetDebugLabel","nvnSamplerSetDebugLabel","nvnCommandBufferSetDebugLabel","nvnSyncSetDebugLabel","nvnCommandBufferCallCommands","nvnCommandBufferBindVertexBuffer","nvnCommandBufferBindImage","nvnCommandBufferDrawElements","nvnCommandBufferDrawElementsBaseVertex","nvnCommandBufferSetViewport"};
    unsigned covered=0;for(unsigned i=0;i<sizeof batch_names/sizeof *batch_names;i++){unsigned j=0;while(j<NVN_NFUNC && strcmp(nvn_names[j],batch_names[i]))j++;if(j<NVN_NFUNC && nvn_slot[j].fn!=(void *)nvn_unimpl_entry && atomic_load(&nvn_slot[j].cnt)>0)covered++;}
    EXPECT("batch all implemented thunks exercised",112,covered);
    ((dev_t_ *)&dev)->origin=saved_origin;((dev_t_ *)&dev)->depth_mode=saved_depth;
}
