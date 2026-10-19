// Exercise the production movie adapter with a deterministic decoder backend.
// Real VP9 decoding is covered separately by t_vp9_decode on Apple hosts.
#define DM_P5R_MOVIE_TEST 1
#include "../hle_movie_vp9.c"
#include "../guest_bootstrap.h"

typedef struct { char key[32]; int value; } item;
typedef struct { item items[24]; int count; } metadata_t;
typedef struct { void *data; size_t capacity; int offset,size,owned; } buffer_t;
struct dm_vp9 { dm_vp9_output output; void *user; };
module_t g_mod[MAX_MOD]; int g_nmod=1;
static int checks,failures,original_calls,original_deletes,buffer_frees,backend_destroys;
static int input_signals,output_signals,format_signals,error_signals;
static void *legacy_vtable[21];
static int original_method(void *self,...) { (void)self; original_calls++; return 0x778; }
static void original_ctor(void *self,int type,int format,int mode,int priority) {
    (void)type;(void)format;(void)mode;(void)priority; original_calls++;
    ((movie_self *)self)->vtable=legacy_vtable+2; ((movie_self *)self)->state=NULL;
}
static void original_dtor(void *self) { ((movie_self *)self)->vtable=legacy_vtable+2; original_deletes++; }
static int find_int(const void *m,const char *key,int *value) {
    const metadata_t *metadata=m;
    for(int i=0;i<metadata->count;i++) if(!strcmp(metadata->items[i].key,key)) { *value=metadata->items[i].value;return 1; }
    return 0;
}
static void set_int(void *m,const char *key,int value) {
    metadata_t *metadata=m;
    for(int i=0;i<metadata->count;i++) if(!strcmp(metadata->items[i].key,key)) { metadata->items[i].value=value;return; }
    item *entry=&metadata->items[metadata->count++]; snprintf(entry->key,sizeof entry->key,"%s",key);entry->value=value;
}
static void set_rect(void *m,const char *key,int x,int y,int right,int bottom) {
    (void)key;set_int(m,"left",x);set_int(m,"top",y);set_int(m,"right",right);set_int(m,"bottom",bottom);
}
static void buffer_dtor(void *b) { buffer_t *v=b;if(v->owned) { free(v->data);buffer_frees++; } memset(v,0,sizeof *v); }
static void buffer_ctor(void *b,void *data,size_t size) { buffer_t *v=b;memset(v,0,sizeof *v);v->data=data;v->capacity=size; }
static void buffer_range(void *b,int offset,int size) { buffer_t *v=b;v->offset=offset;v->size=size; }
static void signal_event(void *event) { if(event==&input_signals) input_signals++;else if(event==&output_signals) output_signals++;else if(event==&format_signals) format_signals++;else if(event==&error_signals) error_signals++;else abort(); }
void *guest_sym(const char *name) { return !strcmp(name,"_ZN2nn2os11SignalEventEPNS0_9EventTypeE")?(void *)signal_event:NULL; }
void *module_sym(module_t *module,const char *name) {
    (void)module;
    if(!strcmp(name,"_ZTVN5movie7DecoderE")) return legacy_vtable;
    if(strstr(name,"7DecoderC1E")) return (void *)original_ctor;
    if(strstr(name,"7DecoderD")) return (void *)original_dtor;
    if(strstr(name,"9MediaData9FindInt32")) return (void *)find_int;
    if(strstr(name,"9MediaData8SetInt32")) return (void *)set_int;
    if(strstr(name,"9MediaData7SetRect")) return (void *)set_rect;
    if(strstr(name,"6BufferD1")) return (void *)buffer_dtor;
    if(strstr(name,"6BufferC1EPvm")) return (void *)buffer_ctor;
    if(strstr(name,"6Buffer8SetRange")) return (void *)buffer_range;
    if(strstr(name,"7Decoder")) return (void *)original_method;
    return NULL;
}
dm_vp9 *dm_vp9_create(dm_vp9_output output,void *user) { dm_vp9 *d=malloc(sizeof *d);d->output=output;d->user=user;return d; }
int dm_vp9_decode(dm_vp9 *d,const void *packet,size_t size,int64_t pts) {
    if(!size) return -1;
    unsigned frames=*(const unsigned char *)packet;
    if(frames==255) return -99;
    for(unsigned i=0;i<frames;i++) {
        dm_vp9_frame frame={malloc(12),12,4,2,pts+(int64_t)i};
        uint8_t *p=frame.data; memset(p,(int)(10+i),8); memset(p+8,(int)(20+i),2); memset(p+10,(int)(30+i),2);
        if(!d->output(d->user,&frame)) { free(frame.data);return -2; }
    }
    return 0;
}
void dm_vp9_destroy(dm_vp9 *d) { if(d) { backend_destroys++;free(d); } }
#define CHECK(test,message) do { checks++;if(!(test)) { failures++;printf("FAIL %s\n",message); } } while(0)
int main(int argc,char **argv) {
    if(argc!=2 || !dm_guest_profile_select(argv[1])) return 2;
    snprintf(g_mod[0].name,sizeof g_mod[0].name,"subsdk0");
    movie_self self={0};h_p5r_vp9_c1(&self,3,4,1,23);
    if(dm_guest_d2r()) {
        CHECK(self.vtable==legacy_vtable+2 && original_calls==1,"D2R keeps original constructor");
        CHECK(h_p5r_vp9_start(&self)==0x778,"D2R methods delegate to original SDK");
        h_p5r_vp9_d0(&self);CHECK(original_deletes==1,"D2R deleting destructor delegates");
    } else {
        CHECK(vp9_state(&self)!=NULL,"observed P5R VP9 decoder is intercepted");
        CHECK(h_p5r_vp9_start(&self)==MV_STATE,"unconfigured decoder cannot start");
        metadata_t metadata={0};set_int(&metadata,"width",4);set_int(&metadata,"height",2);
        CHECK(h_p5r_vp9_configure(&self,&metadata)==MV_OK,"original metadata configures host decoder");
        void *events[]={&input_signals,&output_signals,&format_signals,&error_signals};CHECK(h_p5r_vp9_events(&self,events)==MV_OK,"all original event objects are retained");
        CHECK(h_p5r_vp9_start(&self)==MV_OK && input_signals==1,"start signals input availability");
        int index=-1,remaining=-1,bytes=0,alignment=0;
        CHECK(h_p5r_vp9_size(&self,&bytes,&alignment)==MV_OK && bytes==12 && alignment==1,"NV12 output capacity matches dimensions");
        CHECK(h_p5r_vp9_acquire_input(&self,&index,&remaining)==MV_OK && index==0,"input lease acquired");
        CHECK(h_p5r_vp9_acquire_input(&self,&index,&remaining)==MV_INPUT_EMPTY && index==-1,"duplicate input lease returns exact SDK empty-input status");
        buffer_t buffer={malloc(4),4,0,0,1};
        CHECK(h_p5r_vp9_input(&self,0,&buffer)==MV_OK && buffer_frees==1 && !buffer.owned,"borrowed input buffer replaces owned storage safely");
        *(unsigned char *)buffer.data=1;
        CHECK(h_p5r_vp9_send(&self,0,VP9_INPUT_CAP,1,123456,0)==MV_BAD,"input bounds checked without consuming lease");
        CHECK(h_p5r_vp9_send(&self,0,0,1,123456,0)==MV_OK && output_signals==1 && format_signals==1,"first decoded frame signals format and output events");
        CHECK(h_p5r_vp9_acquire_input(&self,&index,&remaining)==MV_INPUT_EMPTY,"unreleased output applies backpressure");
        int64_t pts=0;unsigned flags=99;
        CHECK(h_p5r_vp9_acquire_output(&self,&index,&pts,&flags,&remaining)==MV_OK && pts==123456 && flags==0,"output preserves timestamp and flags");
        int output_index=index;
        CHECK(h_p5r_vp9_output(&self,index,&buffer)==MV_OK && buffer.size==12 && *(unsigned char *)buffer.data==10,"decoded image bytes reach original Buffer API");
        const uint8_t *gap=buffer.data;
        CHECK(gap[8]==20 && gap[9]==30 && gap[10]==20 && gap[11]==30,"NV12 chroma interleaves the I420 U/V planes");
        metadata_t output={0};CHECK(h_p5r_vp9_frame_format(&self,index,&output)==MV_OK,"per-frame output metadata available");
        int value=0;CHECK(find_int(&output,"color-format",&value) && value==21,"semi-planar colour format is reported");
        CHECK(find_int(&output,"nv12-y-offset",&value) && value==0,"NV12 Y offset starts the buffer");
        CHECK(find_int(&output,"nv12-uv-offset",&value) && value==8,"NV12 UV offset follows the Y plane");
        CHECK(find_int(&output,"nv12-y-stride",&value) && value==4,"NV12 Y stride matches the width");
        CHECK(find_int(&output,"nv12-uv-stride",&value) && value==4,"NV12 UV stride matches the width");
        CHECK(find_int(&output,"right",&value) && value==3,"crop uses inclusive right coordinate");
        CHECK(h_p5r_vp9_release(&self,output_index)==MV_OK && input_signals==2,"release returns input capacity");
        CHECK(h_p5r_vp9_release(&self,output_index)==MV_STATE,"duplicate output release rejected");
        CHECK(h_p5r_vp9_acquire_input(&self,&index,&remaining)==MV_OK,"next input acquired");
        CHECK(h_p5r_vp9_input(&self,0,&buffer)==MV_OK,"next input buffer available");
        *(unsigned char *)buffer.data=8;
        CHECK(h_p5r_vp9_send(&self,0,0,1,200000,4)==MV_OK,"eight-frame superframe plus EOS fits bounded queue");
        for(int i=0;i<9;i++) {
            CHECK(h_p5r_vp9_acquire_output(&self,&index,&pts,&flags,&remaining)==MV_OK,"queued frame acquired");
            CHECK(flags==(unsigned)(i==8?4:0),"EOS follows all decoded frames");
            CHECK(pts==200000+(i==8?0:i),"queue preserves presentation timestamps");
            CHECK(h_p5r_vp9_release(&self,index)==MV_OK,"queued frame released");
        }
        CHECK(h_p5r_vp9_acquire_input(&self,&index,&remaining)==MV_INPUT_EMPTY,"EOS cannot accept more input");
        CHECK(h_p5r_vp9_acquire_output(&self,&index,&pts,&flags,&remaining)==MV_OUTPUT_EMPTY && index==-1 && pts==0 && flags==0,"drained queue returns exact SDK empty-output status and clears outputs");
        CHECK(h_p5r_vp9_flush(&self)==MV_OK && backend_destroys==1,"flush resets references and backend");
        CHECK(h_p5r_vp9_acquire_input(&self,&index,&remaining)==MV_OK,"flush reopens input while running");
        h_p5r_vp9_input(&self,0,&buffer);*(unsigned char *)buffer.data=0;
        int signals=input_signals;
        CHECK(h_p5r_vp9_send(&self,0,0,1,300000,0)==MV_OK && input_signals==signals+1,"invisible reference frame permits further input");
        h_p5r_vp9_acquire_input(&self,&index,&remaining);h_p5r_vp9_input(&self,0,&buffer);*(unsigned char *)buffer.data=255;
        CHECK(h_p5r_vp9_send(&self,0,0,1,400000,0)==MV_ERROR && h_p5r_vp9_error(&self)==MV_ERROR && error_signals==1,"decode error signals original error event and never reports successful playback");
        CHECK(h_p5r_vp9_stop(&self)==MV_OK,"stop releases decoder state");
        h_p5r_vp9_d0(&self);CHECK(original_deletes==1 && !vp9_state(&self),"guest deleting destructor retains allocation ownership");
        movie_self other={0};h_p5r_vp9_c2(&other,1,4,1,23);
        CHECK(other.vtable==legacy_vtable+2 && original_calls==1,"other codecs keep original implementation");
    }
    printf("P5R MOVIE PROTOCOL %s: %d checks, %d failures\n",argv[1],checks,failures);
    return failures!=0;
}
