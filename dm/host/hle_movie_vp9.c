// The observed P5R decoder is VP9 / I420 / buffer mode (3,4,1).
// Keep the SDK extractor, MediaData, Buffer and event objects; replace only
// this decoder, which otherwise selects Horizon's OMX.Nvidia.vp9.decode.
#if defined(DM_P5R_ONLY) || defined(DM_P5R_MOVIE_TEST)
#include "hle.h"
#include "movie_vp9.h"

enum { MV_OK=0, MV_ERROR=0x1000, MV_AGAIN=0x1008, MV_BAD=0x100b, MV_STATE=0x100c, MV_EOS=0x2000 };
enum { VP9_SLOTS=9, VP9_INPUT_CAP=16*1024*1024 }; // eight-frame superframe plus EOS
typedef struct {
    pthread_mutex_t lock;
    dm_vp9 *decoder;
    uint8_t *input;
    dm_vp9_frame frames[VP9_SLOTS];
    unsigned flags[VP9_SLOTS];
    unsigned char occupied[VP9_SLOTS], acquired[VP9_SLOTS];
    int queue[VP9_SLOTS], head, count, width, height;
    int configured, running, input_leased, eos, error;
    uint64_t decoded_frames;
    void *input_event, *output_event;
} movie_vp9;
typedef struct { void **vtable; movie_vp9 *state; } movie_self;
static void *vp9_vtable[21], *vp9_original[19];
static void (*vp9_original_ctor)(void *, int, int, int, int);
static int (*vp9_find_int)(const void *, const char *, int *);
static void (*vp9_set_int)(void *, const char *, int);
static void (*vp9_set_rect)(void *, const char *, int, int, int, int);
static void (*vp9_buffer_dtor)(void *), (*vp9_buffer_ctor)(void *, void *, size_t);
static void (*vp9_buffer_range)(void *, int, int);
static void (*vp9_signal)(void *);
static pthread_once_t vp9_symbols_once=PTHREAD_ONCE_INIT;
static void vp9_symbols(void);
static movie_vp9 *vp9_state(void *self) {
    movie_self *s=self;
    return s && s->vtable==vp9_vtable+2 ? s->state : NULL;
}
static void vp9_notify(void *event) { if(event) vp9_signal(event); }
static void vp9_clear(movie_vp9 *s) {
    dm_vp9_destroy(s->decoder); s->decoder=NULL;
    for(int i=0;i<VP9_SLOTS;i++) { free(s->frames[i].data); memset(&s->frames[i],0,sizeof s->frames[i]); s->occupied[i]=s->acquired[i]=0; s->flags[i]=0; }
    s->head=s->count=s->input_leased=s->eos=s->error=0;
}
// Decode is synchronous with respect to the guest producer; VT's callback
// finishes before dm_vp9_decode returns. Other guest calls wait on s->lock.
static int vp9_output(void *user, dm_vp9_frame *frame) {
    movie_vp9 *s=user;
    for(int i=0;i<VP9_SLOTS;i++) if(!s->occupied[i]) {
        s->frames[i]=*frame; s->occupied[i]=1; s->flags[i]=0;
        s->queue[(s->head+s->count)%VP9_SLOTS]=i; s->count++;
        s->width=frame->width; s->height=frame->height;
        if(++s->decoded_frames<=3) LOG("P5R VP9 decoded frame %llu: %dx%d, %zu I420 bytes, pts=%lld us",(unsigned long long)s->decoded_frames,frame->width,frame->height,frame->size,(long long)frame->pts_us);
        return 1;
    }
    return 0;
}
static int vp9_empty(movie_vp9 *s) {
    for(int i=0;i<VP9_SLOTS;i++) if(s->occupied[i]) return 0;
    return 1;
}
static void vp9_construct(void *self,int type,int format,int mode,int priority) {
    pthread_once(&vp9_symbols_once,vp9_symbols);
    if(dm_guest_d2r() || type!=3 || format!=4 || mode!=1) {
        vp9_original_ctor(self,type,format,mode,priority); return;
    }
    movie_vp9 *s=calloc(1,sizeof *s);
    if(!s || pthread_mutex_init(&s->lock,NULL)) die("P5R VP9: decoder allocation failed");
    s->input=malloc(VP9_INPUT_CAP);
    if(!s->input) die("P5R VP9: input buffer allocation failed");
    ((movie_self *)self)->vtable=vp9_vtable+2; ((movie_self *)self)->state=s;
    LOG("P5R VP9: host decoder constructed, planar I420 buffer output");
}
static void vp9_destruct(void *self,int deleting) {
    movie_vp9 *s=vp9_state(self);
    if(s) {
        pthread_mutex_lock(&s->lock); vp9_clear(s); free(s->input); pthread_mutex_unlock(&s->lock);
        pthread_mutex_destroy(&s->lock); free(s); ((movie_self *)self)->state=NULL;
    }
    // The original destructor restores the guest vtable and, for D0, uses
    // the original guest operator delete. Never free a guest object via libc.
    ((void (*)(void *))vp9_original[deleting?1:0])(self);
}
static int vp9_configure(void *self,void *metadata) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *,void *))vp9_original[2])(self,metadata);
    int width=0,height=0;
    if(!metadata || !(vp9_find_int(metadata,"width",&width)&1) || !(vp9_find_int(metadata,"height",&height)&1) || width<1 || height<1 || width>8192 || height>8192) return MV_BAD;
    pthread_mutex_lock(&s->lock);
    if(s->running) { pthread_mutex_unlock(&s->lock); return MV_STATE; }
    vp9_clear(s); s->width=width; s->height=height; s->configured=1;
    pthread_mutex_unlock(&s->lock); return MV_OK;
}
static int vp9_events(void *self,void **events) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *,void **))vp9_original[3])(self,events);
    if(!events) return MV_BAD;
    pthread_mutex_lock(&s->lock); s->input_event=events[0]; s->output_event=events[1]; pthread_mutex_unlock(&s->lock); return MV_OK;
}
static int vp9_metadata(movie_vp9 *s,void *metadata,const dm_vp9_frame *frame) {
    if(!metadata) return MV_BAD;
    int w=frame?frame->width:s->width, h=frame?frame->height:s->height;
    vp9_set_int(metadata,"width",w); vp9_set_int(metadata,"height",h);
    vp9_set_int(metadata,"stride",w); vp9_set_int(metadata,"slice-height",h);
    vp9_set_int(metadata,"color-format",19); // OMX_COLOR_FormatYUV420Planar
    vp9_set_int(metadata,"crop-width",w); vp9_set_int(metadata,"crop-height",h);
    vp9_set_rect(metadata,"crop",0,0,w-1,h-1);
    return MV_OK;
}
static int vp9_format(void *self,void *metadata) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *,void *))vp9_original[4])(self,metadata);
    pthread_mutex_lock(&s->lock); int result=s->configured?vp9_metadata(s,metadata,NULL):MV_STATE; pthread_mutex_unlock(&s->lock); return result;
}
static int vp9_start(void *self) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *))vp9_original[5])(self);
    pthread_mutex_lock(&s->lock);
    if(!s->configured) { pthread_mutex_unlock(&s->lock); return MV_STATE; }
    s->running=1; void *event=s->input_event; pthread_mutex_unlock(&s->lock); vp9_notify(event); return MV_OK;
}
static int vp9_stop(void *self,int slot) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *))vp9_original[slot])(self);
    pthread_mutex_lock(&s->lock); vp9_clear(s);
    if(slot!=8) s->running=0;
    if(slot==7) s->configured=0;
    void *event=s->running?s->input_event:NULL;
    pthread_mutex_unlock(&s->lock); vp9_notify(event); return MV_OK;
}
static int vp9_acquire_input(void *self,int *index,int *remaining) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *,int *,int *))vp9_original[9])(self,index,remaining);
    if(!index || !remaining) return MV_BAD;
    pthread_mutex_lock(&s->lock); *index=-1; *remaining=0;
    int result=MV_AGAIN;
    if(s->running && !s->eos && !s->input_leased && vp9_empty(s) && !s->error) { s->input_leased=1; *index=0; result=MV_OK; }
    pthread_mutex_unlock(&s->lock); return result;
}
static void vp9_set_buffer(void *buffer,void *data,size_t size) {
    // Reconstruct a non-owning original Buffer; its destructor must not free
    // decoder-owned memory, even when the caller reuses a previously owned one.
    vp9_buffer_dtor(buffer); vp9_buffer_ctor(buffer,data,size); vp9_buffer_range(buffer,0,(int)size);
}
static int vp9_input_buffer(void *self,int index,void *buffer) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *,int,void *))vp9_original[10])(self,index,buffer);
    if(!buffer || index) return MV_BAD;
    pthread_mutex_lock(&s->lock); int result=s->input_leased?MV_OK:MV_STATE;
    if(!result) vp9_set_buffer(buffer,s->input,VP9_INPUT_CAP);
    pthread_mutex_unlock(&s->lock); return result;
}
static int vp9_send(void *self,int index,int offset,int size,int64_t pts,unsigned flags) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *,int,int,int,int64_t,unsigned))vp9_original[11])(self,index,offset,size,pts,flags);
    if(index || offset<0 || size<0 || offset>VP9_INPUT_CAP || size>VP9_INPUT_CAP-offset) return MV_BAD;
    pthread_mutex_lock(&s->lock);
    if(!s->running || !s->input_leased || s->eos) { pthread_mutex_unlock(&s->lock); return MV_STATE; }
    int error=0; s->input_leased=0;
    if(size && !(flags&2)) { // codec configuration data is not a VP9 frame
        if(!s->decoder) s->decoder=dm_vp9_create(vp9_output,s);
        error=s->decoder?dm_vp9_decode(s->decoder,s->input+offset,(size_t)size,pts):-1;
    }
    if(error) { s->error=error; LOG("P5R VP9 decode failed: %d, packet=%d bytes, pts=%lld us",error,size,(long long)pts); }
    if(!error && (flags&4)) {
        int i=0; while(i<VP9_SLOTS && s->occupied[i]) i++;
        if(i==VP9_SLOTS) error=s->error=-2;
        else { s->eos=1; s->occupied[i]=1; s->flags[i]=4; s->frames[i].pts_us=pts; s->queue[(s->head+s->count)%VP9_SLOTS]=i; s->count++; }
    }
    void *out=s->count?s->output_event:NULL, *in=(!s->eos && !error && vp9_empty(s))?s->input_event:NULL;
    pthread_mutex_unlock(&s->lock); vp9_notify(out); vp9_notify(in); return error?MV_ERROR:MV_OK;
}
static int vp9_acquire_output(void *self,int *index,int64_t *pts,unsigned *flags,int *remaining) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *,int *,int64_t *,unsigned *,int *))vp9_original[12])(self,index,pts,flags,remaining);
    if(!index || !pts || !flags || !remaining) return MV_BAD;
    pthread_mutex_lock(&s->lock); int result=MV_AGAIN; *index=-1; *remaining=0;
    if(s->count) { int i=s->queue[s->head]; s->head=(s->head+1)%VP9_SLOTS; s->count--; s->acquired[i]=1; *index=i; *pts=s->frames[i].pts_us; *flags=s->flags[i]; *remaining=s->count; result=MV_OK; }
    else if(s->error) result=MV_ERROR;
    pthread_mutex_unlock(&s->lock); return result;
}
static int vp9_output_buffer(void *self,int index,void *buffer) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *,int,void *))vp9_original[13])(self,index,buffer);
    if(!buffer || index<0 || index>=VP9_SLOTS) return MV_BAD;
    pthread_mutex_lock(&s->lock); int result=s->acquired[index]?MV_OK:MV_STATE;
    if(!result) vp9_set_buffer(buffer,s->frames[index].data,s->frames[index].size);
    pthread_mutex_unlock(&s->lock); return result;
}
static int vp9_buffer_size(void *self,int *bytes,int *alignment) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *,int *,int *))vp9_original[14])(self,bytes,alignment);
    if(!bytes || !alignment) return MV_BAD;
    pthread_mutex_lock(&s->lock); *bytes=s->width*s->height+2*((s->width+1)/2)*((s->height+1)/2); *alignment=1;
    int result=s->configured?MV_OK:MV_STATE; pthread_mutex_unlock(&s->lock); return result;
}
static int vp9_release(void *self,int index) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *,int))vp9_original[15])(self,index);
    if(index<0 || index>=VP9_SLOTS) return MV_BAD;
    pthread_mutex_lock(&s->lock);
    if(!s->acquired[index]) { pthread_mutex_unlock(&s->lock); return MV_STATE; }
    free(s->frames[index].data); memset(&s->frames[index],0,sizeof s->frames[index]); s->occupied[index]=s->acquired[index]=0; s->flags[index]=0;
    void *in=s->running && !s->eos && vp9_empty(s)?s->input_event:NULL;
    pthread_mutex_unlock(&s->lock); vp9_notify(in); return MV_OK;
}
static int vp9_last_error(void *self) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *))vp9_original[16])(self);
    pthread_mutex_lock(&s->lock); int error=s->error; pthread_mutex_unlock(&s->lock); return error?MV_ERROR:MV_OK;
}
static int vp9_output_format(void *self,int index,void *metadata) {
    movie_vp9 *s=vp9_state(self); if(!s) return ((int (*)(void *,int,void *))vp9_original[18])(self,index,metadata);
    if(index<0 || index>=VP9_SLOTS || !metadata) return MV_BAD;
    pthread_mutex_lock(&s->lock); int result=MV_STATE;
    if(s->acquired[index]) result=s->flags[index]&4?MV_EOS:vp9_metadata(s,metadata,&s->frames[index]);
    pthread_mutex_unlock(&s->lock); return result;
}
static int vp9_output_with_format(void *self,int index,void *buffer,void *metadata) {
    if(!vp9_state(self)) return ((int (*)(void *,int,void *,void *))vp9_original[17])(self,index,buffer,metadata);
    int result=vp9_output_buffer(self,index,buffer); return result?result:vp9_output_format(self,index,metadata);
}

HLE_FORCE_OPTIONAL("_ZN5movie7DecoderD1Ev", "P5R VP9 host decoding preserves movie buffer and event contracts", void, h_p5r_vp9_d1, void *self) { vp9_destruct(self,0); }

HLE_FORCE_OPTIONAL("_ZN5movie7DecoderD0Ev", "P5R VP9 host decoding preserves movie buffer and event contracts", void, h_p5r_vp9_d0, void *self) { vp9_destruct(self,1); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder9ConfigureEPNS_9MediaDataE", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_configure, void *self,void *metadata) { return vp9_configure(self,metadata); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder20RegisterClientEventsEPNS_13DecoderEventsE", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_events, void *self,void **events) { return vp9_events(self,events); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder15GetOutputFormatEPNS_9MediaDataE", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_format, void *self,void *metadata) { return vp9_format(self,metadata); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder5StartEv", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_start, void *self) { return vp9_start(self); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder4StopEv", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_stop, void *self) { return vp9_stop(self,6); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder5ResetEv", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_reset, void *self) { return vp9_stop(self,7); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder5FlushEv", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_flush, void *self) { return vp9_stop(self,8); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder23AcquireInputBufferIndexEPiS1_", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_acquire_input, void *self,int *index,int *remaining) { return vp9_acquire_input(self,index,remaining); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder14GetInputBufferEiPNS_6BufferE", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_input, void *self,int index,void *buffer) { return vp9_input_buffer(self,index,buffer); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder24SendInputBufferForDecodeEiiilj", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_send, void *self,int index,int offset,int size,int64_t pts,unsigned flags) { return vp9_send(self,index,offset,size,pts,flags); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder24AcquireOutputBufferIndexEPiPlPjS1_", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_acquire_output, void *self,int *index,int64_t *pts,unsigned *flags,int *remaining) { return vp9_acquire_output(self,index,pts,flags,remaining); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder15GetOutputBufferEiPNS_6BufferE", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_output, void *self,int index,void *buffer) { return vp9_output_buffer(self,index,buffer); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder19GetOutputBufferSizeEPiS1_", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_size, void *self,int *bytes,int *alignment) { return vp9_buffer_size(self,bytes,alignment); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder24ReleaseOutputBufferIndexEi", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_release, void *self,int index) { return vp9_release(self,index); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder12GetLastErrorEv", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_error, void *self) { return vp9_last_error(self); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder15GetOutputBufferEiPNS_6BufferEPNS_9MediaDataE", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_output_format, void *self,int index,void *buffer,void *metadata) { return vp9_output_with_format(self,index,buffer,metadata); }

HLE_FORCE_OPTIONAL("_ZN5movie7Decoder21GetOutputBufferFormatEiPNS_9MediaDataE", "P5R VP9 host decoding preserves movie buffer and event contracts", int, h_p5r_vp9_frame_format, void *self,int index,void *metadata) { return vp9_output_format(self,index,metadata); }

HLE_FORCE_OPTIONAL("_ZN5movie7DecoderC1ENS_11DecoderTypeENS_19DecoderOutputFormatENS_11DecoderModeEi", "P5R VP9 uses the public host decoder instead of Horizon NVIDIA OMX", void, h_p5r_vp9_c1, void *self,int type,int format,int mode,int priority) { vp9_construct(self,type,format,mode,priority); }

HLE_FORCE_OPTIONAL("_ZN5movie7DecoderC2ENS_11DecoderTypeENS_19DecoderOutputFormatENS_11DecoderModeEi", "P5R VP9 uses the public host decoder instead of Horizon NVIDIA OMX", void, h_p5r_vp9_c2, void *self,int type,int format,int mode,int priority) { vp9_construct(self,type,format,mode,priority); }

static void *vp9_raw(const char *name) {
    for(int i=0;i<g_nmod;i++) if(!strcmp(g_mod[i].name,"subsdk0")) return module_sym(&g_mod[i],name);
    return NULL;
}
static void *vp9_required(const char *name) {
    void *p=vp9_raw(name); if(!p) die("P5R VP9: missing original SDK symbol %s",name); return p;
}
static void vp9_symbols(void) {
    static const char *const names[19]={
        "_ZN5movie7DecoderD1Ev",
        "_ZN5movie7DecoderD0Ev",
        "_ZN5movie7Decoder9ConfigureEPNS_9MediaDataE",
        "_ZN5movie7Decoder20RegisterClientEventsEPNS_13DecoderEventsE",
        "_ZN5movie7Decoder15GetOutputFormatEPNS_9MediaDataE",
        "_ZN5movie7Decoder5StartEv",
        "_ZN5movie7Decoder4StopEv",
        "_ZN5movie7Decoder5ResetEv",
        "_ZN5movie7Decoder5FlushEv",
        "_ZN5movie7Decoder23AcquireInputBufferIndexEPiS1_",
        "_ZN5movie7Decoder14GetInputBufferEiPNS_6BufferE",
        "_ZN5movie7Decoder24SendInputBufferForDecodeEiiilj",
        "_ZN5movie7Decoder24AcquireOutputBufferIndexEPiPlPjS1_",
        "_ZN5movie7Decoder15GetOutputBufferEiPNS_6BufferE",
        "_ZN5movie7Decoder19GetOutputBufferSizeEPiS1_",
        "_ZN5movie7Decoder24ReleaseOutputBufferIndexEi",
        "_ZN5movie7Decoder12GetLastErrorEv",
        "_ZN5movie7Decoder15GetOutputBufferEiPNS_6BufferEPNS_9MediaDataE",
        "_ZN5movie7Decoder21GetOutputBufferFormatEiPNS_9MediaDataE",
    };
    void *const replacements[19]={
        (void *)h_p5r_vp9_d1,
        (void *)h_p5r_vp9_d0,
        (void *)h_p5r_vp9_configure,
        (void *)h_p5r_vp9_events,
        (void *)h_p5r_vp9_format,
        (void *)h_p5r_vp9_start,
        (void *)h_p5r_vp9_stop,
        (void *)h_p5r_vp9_reset,
        (void *)h_p5r_vp9_flush,
        (void *)h_p5r_vp9_acquire_input,
        (void *)h_p5r_vp9_input,
        (void *)h_p5r_vp9_send,
        (void *)h_p5r_vp9_acquire_output,
        (void *)h_p5r_vp9_output,
        (void *)h_p5r_vp9_size,
        (void *)h_p5r_vp9_release,
        (void *)h_p5r_vp9_error,
        (void *)h_p5r_vp9_output_format,
        (void *)h_p5r_vp9_frame_format,
    };
    for(int i=0;i<19;i++) { vp9_original[i]=vp9_required(names[i]); vp9_vtable[i+2]=replacements[i]; }
    void **original=vp9_required("_ZTVN5movie7DecoderE");
    vp9_vtable[0]=original[0]; vp9_vtable[1]=original[1];
    vp9_original_ctor=vp9_required("_ZN5movie7DecoderC1ENS_11DecoderTypeENS_19DecoderOutputFormatENS_11DecoderModeEi");
    vp9_find_int=vp9_required("_ZNK5movie9MediaData9FindInt32EPKcPi");
    vp9_set_int=vp9_required("_ZN5movie9MediaData8SetInt32EPKci");
    vp9_set_rect=vp9_required("_ZN5movie9MediaData7SetRectEPKciiii");
    vp9_buffer_dtor=vp9_required("_ZN5movie6BufferD1Ev");
    vp9_buffer_ctor=vp9_required("_ZN5movie6BufferC1EPvm");
    vp9_buffer_range=vp9_required("_ZN5movie6Buffer8SetRangeEii");
    // The OS event implementation belongs to sdk, not subsdk0.
    vp9_signal=guest_sym("_ZN2nn2os11SignalEventEPNS0_9EventTypeE");
    if(!vp9_signal) die("P5R VP9: missing guest event signal");
}
#endif
