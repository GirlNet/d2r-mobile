// 默认关闭的单条纯缓冲计算对照；保留两个独立着色器和管线，不替换正在使用的对象。
// Disabled-by-default single buffer-compute comparison; retain independent shaders/pipelines without replacing live objects.
static volatile int g_compute_probe_mode; // 0 原版，1 候选，2 按帧交替 | 0 original, 1 candidate, 2 alternating frames
static volatile int g_compute_probe_status; // 0 未准备，1 就绪，-1 拒绝 | 0 unprepared, 1 ready, -1 rejected
static volatile uint64_t g_compute_probe_original_dispatches, g_compute_probe_candidate_dispatches;
static NSDictionary *g_compute_probe_config;
static NvShader *g_compute_probe_original, *g_compute_probe_candidate;

static NSData *compute_probe_read(NSString *path, size_t limit) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY);struct stat st;
    if(fd<0)return nil;
    if(fstat(fd,&st)||st.st_size<=0||(uint64_t)st.st_size>limit){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];size_t done=0;
    while(done<data.length){ssize_t n=read(fd,(uint8_t *)data.mutableBytes+done,data.length-done);
        if(n<0&&errno==EINTR)continue;if(n<=0){close(fd);return nil;}done+=(size_t)n;}
    uint8_t extra;ssize_t n=read(fd,&extra,1);close(fd);return n==0?data:nil;
}
static NSString *compute_probe_digest(NSData *data) {
    if(!data)return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    char hex[65];for(unsigned i=0;i<sizeof digest;i++)snprintf(hex+i*2,3,"%02x",digest[i]);
    return @(hex);
}
static NvShader *compute_probe_reject(NvShader *original,const char *reason) {
    g_compute_probe_status=-1;g_compute_probe_mode=0;
    MLOG("[compute-probe] rejected: %s; original retained",reason);return original;
}
static int compute_probe_buffers(const NvShader *shader) {
    return shader && shader->stage==5 && !shader->builtin && shader->ae &&
        compute_batch_buffer_only(&shader->rf);
}
static NvShader *compute_probe_shader(NvShader *original) {
    if(dm_guest_d2r())return original;
    int mode=g_compute_probe_mode;
    if(!mode){if(original==g_compute_probe_original)g_compute_probe_original_dispatches++;return original;}
    if(mode<0||mode>2)return compute_probe_reject(original,"invalid mode");
    const char *temporary=getenv("DM_TEMP");
    if(!temporary||!temporary[0])return compute_probe_reject(original,"missing temporary directory");
    NSString *root=@(temporary);
    if(!g_compute_probe_config) {
        NSData *bytes=compute_probe_read([root stringByAppendingPathComponent:@"compute-probe.json"],16384);
        id config=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
        if(![config isKindOfClass:NSDictionary.class]||![config[@"version"] isEqual:@1])
            return compute_probe_reject(original,"invalid configuration");
        NSString *key=config[@"key"],*entry=config[@"entry"];
        NSCharacterSet *bad=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF_"] invertedSet];
        if(![key isKindOfClass:NSString.class]||!key.length||key.length>=sizeof original->key||
           [key rangeOfCharacterFromSet:bad].location!=NSNotFound||
           ![entry isKindOfClass:NSString.class]||!entry.length||entry.length>128)
            return compute_probe_reject(original,"invalid key or entry");
        for(NSString *name in @[@"original_sha256",@"candidate_sha256"]){
            id value=config[name];if(![value isKindOfClass:NSString.class]||[value length]!=64)
                return compute_probe_reject(original,"invalid digest");
        }
        g_compute_probe_config=config;
    }
    if(strcmp(original->key,[g_compute_probe_config[@"key"] UTF8String]))return original;
    if(!compute_probe_buffers(original))return compute_probe_reject(original,"buffer-only compute required");
    if(!g_compute_probe_candidate) {
        NSString *reference=[g_msl_dir stringByAppendingPathComponent:[g_compute_probe_config[@"key"] stringByAppendingString:@".metallib"]];
        NSData *before=compute_probe_read(reference,4*1024*1024);
        NSData *bytes=compute_probe_read([root stringByAppendingPathComponent:@"compute-probe.metallib"],4*1024*1024);
        if(![compute_probe_digest(before) isEqualToString:g_compute_probe_config[@"original_sha256"]]||
           ![compute_probe_digest(bytes) isEqualToString:g_compute_probe_config[@"candidate_sha256"]]||
           bytes.length<4||memcmp(bytes.bytes,"MTLB",4))return compute_probe_reject(original,"library digest or format mismatch");
        // 从已校验的同一份字节建库，避免再次打开文件造成校验与使用不一致。
        // Build from the exact validated bytes rather than reopening a file after verification.
        void *copy=malloc(bytes.length);if(!copy)return compute_probe_reject(original,"library allocation failed");
        memcpy(copy,bytes.bytes,bytes.length);
        dispatch_data_t data=dispatch_data_create(copy,bytes.length,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),DISPATCH_DATA_DESTRUCTOR_FREE);
        NSError *error=nil;id<MTLLibrary> library=[g_dev newLibraryWithData:data error:&error];
        id<MTLFunction> function=[library newFunctionWithName:g_compute_probe_config[@"entry"]];
        if(!function||function.functionType!=MTLFunctionTypeKernel||![function.name isEqualToString:original->fn.name])
            return compute_probe_reject(original,"kernel entry mismatch");
        id<MTLArgumentEncoder> encoder=[function newArgumentEncoderWithBufferIndex:original->rf.abi];
        NSUInteger length=original->arg_len?:original->ae.encodedLength;
        if(!encoder||encoder.encodedLength!=length||length>NVN_REFL_MAXB*8)
            return compute_probe_reject(original,"argument layout length mismatch");
        NvShader *candidate=[NvShader new];candidate->fn=function;candidate->rf=original->rf;
        candidate->ae=encoder;candidate->arg_len=length;candidate->stage=5;candidate->range_ro=original->range_ro;
        candidate->c1buf=original->c1buf;candidate->c1_gpu=original->c1_gpu;candidate->c1off=original->c1off;
        memcpy(candidate->key,original->key,sizeof candidate->key);
        g_compute_probe_original=original;g_compute_probe_candidate=candidate;g_compute_probe_status=1;
        MLOG("[compute-probe] ready; original and candidate pipelines retained independently");
    }
    if(original!=g_compute_probe_original)return original;
    if(mode==1||(mode==2&&(g_cur_frame&1))){g_compute_probe_candidate_dispatches++;return g_compute_probe_candidate;}
    g_compute_probe_original_dispatches++;return original;
}
static const char *compute_probe_label(NvShader *shader,const p_dispatch *dispatch) {
    int variant=shader==g_compute_probe_candidate?1:shader==g_compute_probe_original?0:-1;
    if(g_compute_probe_mode && variant>=0){
        // 记录派发尺寸，后续只比较相同工作量的样本；关闭实验后不格式化标签。
        // Record dispatch dimensions for matched-work comparisons; skip formatting when the experiment is off.
        static char label[24];int n=snprintf(label,sizeof label,"P%d:%d,%d,%d",variant,dispatch->x,dispatch->y,dispatch->z);
        return n>=0&&(size_t)n<sizeof label?label:"probe-unmatched";
    }
    return shader->key;
}
