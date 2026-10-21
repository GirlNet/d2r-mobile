// 颜色附件同时被采样时先保存独立副本；依据 Metal 通道同步要求，保留视图的级、层、格式与分量映射。
// Snapshot sampled color attachments before drawing, per Metal pass synchronization rules, preserving view levels, layers, format and swizzle.
typedef struct { __strong id<MTLTexture> texture; uint64_t epoch; } color_feedback_slot;
static color_feedback_slot g_color_feedback_slots[16];
static uint64_t g_color_feedback_epoch, g_color_feedback_copies;

static id<MTLTexture> color_feedback_root(id<MTLTexture> texture,NSUInteger *level,NSUInteger *slice) {
    *level=*slice=0;
    while(texture.parentTexture) {
        *level+=texture.parentRelativeLevel;*slice+=texture.parentRelativeSlice;
        texture=texture.parentTexture;
    }
    return texture;
}
static NSUInteger color_feedback_slices(id<MTLTexture> texture) {
    return texture.arrayLength*((texture.textureType==MTLTextureTypeCube || texture.textureType==MTLTextureTypeCubeArray)?6:1);
}
static int color_feedback_overlap(id<MTLTexture> sampled,id<MTLTexture> attachment,NSUInteger level,NSUInteger slice) {
    if(!sampled || !attachment)return 0;
    NSUInteger sl,ss,al,as;
    id<MTLTexture> sr=color_feedback_root(sampled,&sl,&ss),ar=color_feedback_root(attachment,&al,&as);
    return sr==ar && al+level>=sl && al+level-sl<sampled.mipmapLevelCount &&
        (sampled.textureType==MTLTextureType3D || (as+slice>=ss && as+slice-ss<color_feedback_slices(sampled)));
}
static int color_feedback_shape(id<MTLTexture> a,id<MTLTexture> b) {
    if(!a || !b)return 0;
    MTLTextureSwizzleChannels sa=a.swizzle,sb=b.swizzle;
    return a.textureType==b.textureType && a.pixelFormat==b.pixelFormat && a.width==b.width && a.height==b.height &&
        a.depth==b.depth && a.mipmapLevelCount==b.mipmapLevelCount && a.arrayLength==b.arrayLength && !memcmp(&sa,&sb,sizeof sa);
}
static int color_feedback_needed(NvProg *program) {
    int found=0;pthread_mutex_lock(&g_rmu);
    for(int stage=0;stage<2 && !found;stage++) {
        NvShader *shader=program->sh[stage];if(!shader)continue;
        for(int i=0;i<shader->rf.nb && !found;i++) {
            const nvn_rbind *binding=&shader->rf.b[i];if(binding->kind!=NVN_RB_TEX)continue;
            int tid=(int)nvn_handle_texture_id(nvn_rbind_handle(binding,S.tex[stage],S.samp[stage],S.img[stage]));
            if(tid<=0 || tid>=g_ntreg || !g_treg[tid].ok)continue;
            for(int a=0;a<R.rt.n && a<8;a++)if(R.rt.color[a] && R.rt.color[a]->serial==g_treg[tid].t.serial){found=1;break;}
        }
    }
    pthread_mutex_unlock(&g_rmu);return found;
}
static id<MTLTexture> color_feedback_copy(id<MTLTexture> source,uint64_t epoch) {
    if(source.sampleCount!=1 || source.textureType==MTLTextureTypeTextureBuffer)
        MDIE("Unsupported sampled color attachment type=%lu samples=%lu",(unsigned long)source.textureType,(unsigned long)source.sampleCount);
    color_feedback_slot *slot=NULL;
    for(unsigned i=0;i<16;i++)if(g_color_feedback_slots[i].epoch!=epoch && color_feedback_shape(g_color_feedback_slots[i].texture,source)) {
        slot=&g_color_feedback_slots[i];break;
    }
    if(!slot)for(unsigned i=0;i<16;i++)if(!g_color_feedback_slots[i].texture){slot=&g_color_feedback_slots[i];break;}
    if(!slot)for(unsigned i=0;i<16;i++)if(g_color_feedback_slots[i].epoch!=epoch){slot=&g_color_feedback_slots[i];break;}
    id<MTLTexture> destination=slot?slot->texture:nil;
    if(!color_feedback_shape(destination,source)) {
        MTLTextureDescriptor *d=[MTLTextureDescriptor new];
        d.textureType=source.textureType;d.pixelFormat=source.pixelFormat;d.width=source.width;d.height=source.height;
        d.depth=source.depth;d.mipmapLevelCount=source.mipmapLevelCount;d.arrayLength=source.arrayLength;
        d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead;d.swizzle=source.swizzle;
        destination=[g_dev newTextureWithDescriptor:d];
        if(!destination)MDIE("Cannot snapshot sampled color attachment %lux%lu",(unsigned long)source.width,(unsigned long)source.height);
        res_add(destination);
        if(slot){defer_obj_release(slot->texture);slot->texture=destination;}
        else defer_obj_release(destination);
    }
    if(slot)slot->epoch=epoch;
    BENC copy=blit();
    for(NSUInteger level=0;level<source.mipmapLevelCount;level++) {
        MTLSize size=MTLSizeMake(MAX(source.width>>level,1u),MAX(source.height>>level,1u),
            source.textureType==MTLTextureType3D?MAX(source.depth>>level,1u):1);
        for(NSUInteger slice=0;slice<color_feedback_slices(source);slice++)
            enc_b_copy_texture(copy,source,slice,level,MTLOriginMake(0,0,0),size,destination,slice,level,MTLOriginMake(0,0,0));
    }
    g_color_feedback_copies++;
    return destination;
}
static void prepare_color_feedback(NvProg *program,id<MTLTexture> __strong vertex[NVN_REFL_MAXB],
                                    id<MTLTexture> __strong fragment[NVN_REFL_MAXB]) {
    if(!program || !R.has_rt || !R.rt.n || !color_feedback_needed(program))return;
    id<MTLTexture> attachments[8]={nil};
    for(int i=0;i<R.rt.n && i<8;i++)if(R.rt.color[i])attachments[i]=tex_mtl(R.rt.color[i]);
    id<MTLTexture> sources[NVN_REFL_MAXB*2]={nil},copies[NVN_REFL_MAXB*2]={nil};
    unsigned count=0;uint64_t epoch=++g_color_feedback_epoch;
    for(int stage=0;stage<2;stage++) {
        NvShader *shader=program->sh[stage];if(!shader)continue;
        id<MTLTexture> __strong *textures=stage?fragment:vertex;
        for(int i=0;i<shader->rf.nb;i++) {
            if(shader->rf.b[i].kind!=NVN_RB_TEX || !textures[i])continue;
            id<MTLTexture> source=textures[i];int overlap=0;
            for(int a=0;a<R.rt.n && a<8 && !overlap;a++) {
                const view_t *view=R.rt.has_cview[a]?&R.rt.cview[a]:NULL;
                overlap=color_feedback_overlap(source,attachments[a],view&&view->set_levels?view->base_level:0,
                    view&&view->set_layers?view->min_layer:0);
            }
            if(!overlap)continue;
            if(!count) {
                // 尚未开通道的清除也属于背景内容，先完成它们，再按序复制。
                // Pending clears are part of the background too; materialize them before the ordered copy.
                int clear=R.clear_d || R.clear_s;for(int a=0;a<8;a++)clear|=R.clear_c[a];
                if(clear)(void)rp_begin_ex(0);
                rp_end();
            }
            unsigned at=0;while(at<count && sources[at]!=source)at++;
            if(at==count){sources[count]=source;copies[count++]=color_feedback_copy(source,epoch);}
            textures[i]=copies[at];g_args_dirty[stage]=1;
            static unsigned logged;
            if(logged++<8)MLOG("Color feedback snapshot: shader=%s stage=%d slot=%d %lux%lu",shader->key,stage,shader->rf.b[i].reg,
                (unsigned long)source.width,(unsigned long)source.height);
        }
    }
}
