// 按 Apple Metal 4 CounterHeap 接口，有限记录主提交的渲染／计算／拷贝时间戳。
// 默认关闭；每批独立持有计数堆，在 GPU 完成反馈中解析，不重用在途槽或改动屏障。
// Record bounded render/compute/copy timestamps using Apple's Metal 4 CounterHeap API.
// Off by default; each batch owns its heap until GPU feedback resolves it, with no in-flight reuse or barrier changes.
#define PG4_MAX_ENCODERS 1024
typedef struct {
    uint64_t frame, pass, draw_start;
    uint32_t slot, draws, width, height, color, depth;
    char kind, label[24];
} pg4_record;
@interface NvPassGpuBatch : NSObject {
@public
    id<MTL4CounterHeap> heap;
    pg4_record *records;
    unsigned count;
    uint64_t capture;
}
@end
@implementation NvPassGpuBatch
- (void)dealloc { free(records); }
@end

// 调试器只切换 enabled；先等待一分钟避开附加后的短时加速，再自动捕获 120 帧。
// The debugger only toggles enabled; wait a minute past attach's transient boost, then automatically capture 120 frames.
static int g_pg4_enabled, g_pg4_delay_ms=60000, g_pg4_frame_limit=120;
static uint64_t g_pg4_deadline, g_pg4_first_frame, g_pg4_capture;
static FILE *g_pg4_file;
static char g_pg4_path[4096];
static pthread_mutex_t g_pg4_file_mu=PTHREAD_MUTEX_INITIALIZER;
static NvPassGpuBatch *g_pg4_batch;
static __unsafe_unretained id g_pg4_encoder;
static unsigned g_pg4_open;
static _Atomic unsigned g_pg4_pending;

static void pg4_sub_begin(void) {
    g_pg4_batch=nil;g_pg4_encoder=nil;
    if(!g_pg4_enabled){g_pg4_deadline=0;return;}
    uint64_t now=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if(!g_pg4_deadline) {
        g_pg4_deadline=now+(uint64_t)MAX(g_pg4_delay_ms,0)*1000000;
        g_pg4_first_frame=UINT64_MAX;g_pg4_capture++;
    }
    if(now<g_pg4_deadline)return;
    uint64_t frame=atomic_load(&g_cur_frame);
    if(g_pg4_first_frame==UINT64_MAX)g_pg4_first_frame=frame;
    if(frame-g_pg4_first_frame>=(uint64_t)MAX(g_pg4_frame_limit,1) || now-g_pg4_deadline>=10000000000ull) {
        g_pg4_enabled=0;g_pg4_deadline=0;
        MLOG("[passgpu4] bounded capture %llu finished",(unsigned long long)g_pg4_capture);return;
    }
    if(!g_pg4_file) {
        const char *temporary=getenv("DM_TEMP");if(!temporary)temporary=".";
        int length=snprintf(g_pg4_path,sizeof g_pg4_path,"%s/p5r-metal4-passes-%d-%llu.tsv",temporary,getpid(),(unsigned long long)now);
        if(length<0 || (size_t)length>=sizeof g_pg4_path || !(g_pg4_file=fopen(g_pg4_path,"w"))) {
            MLOG("[passgpu4] cannot open output; capture disabled");g_pg4_enabled=0;return;
        }
        fprintf(g_pg4_file,"# Raw GPU ticks; spans can overlap and are not additive. Validate tick units against cb_ms.\n");
        fprintf(g_pg4_file,"capture\tframe\tpass\tkind\tw\th\tcolor\tdepth\tdraws\tlabel\tstart0\tstart1\tend0\tend1\tvalid\tcb_ms\n");
        MLOG("[passgpu4] raw timestamps -> %s",g_pg4_path);
    }
    NvPassGpuBatch *batch=[NvPassGpuBatch new];
    MTL4CounterHeapDescriptor *descriptor=[MTL4CounterHeapDescriptor new];
    descriptor.type=MTL4CounterHeapTypeTimestamp;descriptor.count=PG4_MAX_ENCODERS*4;
    NSError *error=nil;batch->heap=[g_dev newCounterHeapWithDescriptor:descriptor error:&error];
    batch->records=calloc(PG4_MAX_ENCODERS,sizeof(pg4_record));batch->capture=g_pg4_capture;
    if(!batch->heap || !batch->records) {
        MLOG("[passgpu4] counter allocation unavailable: %s",error.localizedDescription.UTF8String);
        g_pg4_enabled=0;return;
    }
    [batch->heap invalidateCounterRange:NSMakeRange(0,PG4_MAX_ENCODERS*4)];
    g_pg4_batch=batch;
}
static void pg4_timestamp(id encoder,pg4_record *record,int end) {
    id<MTL4CounterHeap> heap=g_pg4_batch->heap;
    if(record->kind=='R') {
        id<MTL4RenderCommandEncoder> render=encoder;
        [render writeTimestampWithGranularity:MTL4TimestampGranularityPrecise afterStage:MTLRenderStageVertex intoHeap:heap atIndex:record->slot+(end?2:0)];
        [render writeTimestampWithGranularity:MTL4TimestampGranularityPrecise afterStage:MTLRenderStageFragment intoHeap:heap atIndex:record->slot+(end?3:1)];
    } else {
        [(id<MTL4ComputeCommandEncoder>)encoder writeTimestampWithGranularity:MTL4TimestampGranularityPrecise intoHeap:heap atIndex:record->slot+(end?1:0)];
    }
}
static void pg4_begin(id encoder,char kind,RPD *descriptor) {
    if(!g_pg4_batch || !encoder || g_pg4_batch->count==PG4_MAX_ENCODERS)return;
    g_pg4_open=g_pg4_batch->count++;
    pg4_record *record=&g_pg4_batch->records[g_pg4_open];
    record->frame=atomic_load(&g_cur_frame);record->pass=g_stat_pass+(kind=='R');
    record->draw_start=g_stat_draw;record->slot=g_pg4_open*4;record->kind=kind;
    if(descriptor) {
        NSUInteger width,height;pass_dims(descriptor,8,&width,&height);
        record->width=(uint32_t)width;record->height=(uint32_t)height;
        for(int i=0;i<8 && !record->color;i++)record->color=(uint32_t)descriptor.colorAttachments[i].texture.pixelFormat;
        record->depth=(uint32_t)descriptor.depthAttachment.texture.pixelFormat;
    }
    g_pg4_encoder=encoder;pg4_timestamp(encoder,record,0);
}
static void pg4_note(const char *label) {
    if(!on_sub_thread() || !g_pg4_encoder)return;
    pg4_record *record=&g_pg4_batch->records[g_pg4_open];
    if(!record->label[0] && label)snprintf(record->label,sizeof record->label,"%.23s",label);
}
static void pg4_end(id encoder) {
    if(encoder!=g_pg4_encoder || !g_pg4_batch)return;
    pg4_record *record=&g_pg4_batch->records[g_pg4_open];
    if(record->kind=='R')record->draws=(uint32_t)(g_stat_draw-record->draw_start);
    pg4_timestamp(encoder,record,1);g_pg4_encoder=nil;
}
static void pg4_commit(MTL4CommitOptions *options) {
    NvPassGpuBatch *batch=g_pg4_batch;g_pg4_batch=nil;g_pg4_encoder=nil;
    if(!batch || !batch->count)return;
    atomic_fetch_add(&g_pg4_pending,1);
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        @autoreleasepool {
            NSData *data=feedback.error?nil:[batch->heap resolveCounterRange:NSMakeRange(0,batch->count*4)];
            const MTL4TimestampHeapEntry *entries=data.bytes;
            int complete=data.length>=(size_t)batch->count*4*sizeof(*entries);
            pthread_mutex_lock(&g_pg4_file_mu);
            for(unsigned i=0;i<batch->count;i++) {
                const pg4_record *record=&batch->records[i];uint64_t ticks[4]={0};
                if(complete)for(int j=0;j<4;j++)ticks[j]=entries[record->slot+j].timestamp;
                int valid=ticks[0] && ticks[0]!=UINT64_MAX && ticks[1] && ticks[1]!=UINT64_MAX;
                if(record->kind=='R')valid=valid && ticks[2]>=ticks[0] && ticks[2]!=UINT64_MAX && ticks[3]>=ticks[1] && ticks[3]!=UINT64_MAX;
                else valid=valid && ticks[1]>=ticks[0];
                fprintf(g_pg4_file,"%llu\t%llu\t%llu\t%c\t%u\t%u\t%u\t%u\t%u\t%s\t%llu\t%llu\t%llu\t%llu\t%d\t%.6f\n",
                    (unsigned long long)batch->capture,(unsigned long long)record->frame,(unsigned long long)record->pass,record->kind,
                    record->width,record->height,record->color,record->depth,record->draws,record->label,
                    (unsigned long long)ticks[0],(unsigned long long)ticks[1],(unsigned long long)ticks[2],(unsigned long long)ticks[3],valid,
                    (feedback.GPUEndTime-feedback.GPUStartTime)*1000.0);
            }
            fflush(g_pg4_file);pthread_mutex_unlock(&g_pg4_file_mu);
        }
        atomic_fetch_sub(&g_pg4_pending,1);
    }];
}
