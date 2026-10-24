// Real service adapters, opaque lifetimes, output guards and concurrent layers.
#include "../hle_vi.c"
#include <assert.h>
static void *vi_worker(void *owner) {
    for(unsigned i=0;i<1000;i++) {
        void *layer=NULL,*window=NULL;assert(h_vi_CreateLayer(&layer,owner)==0&&layer);
        assert(h_vi_GetNativeWindow(&window,layer)==0&&window==layer);
        h_vi_DestroyLayer(layer);
    }
    return NULL;
}
int main(void) {
    struct { uint64_t before;void *value;uint64_t after; } out={0x12345678,(void *)0x777,0x87654321};
    assert(h_vi_OpenDefaultDisplay(&out.value)==RES_FAIL&&out.value==(void *)0x777);
    h_vi_Initialize();h_vi_Initialize();h_vi_Finalize();assert(vi_refs==1);
    assert(h_vi_OpenDefaultDisplay(NULL)==RES_FAIL);assert(h_vi_OpenDefaultDisplay(&out.value)==0);
    void *display=out.value,*other=NULL,*layer=NULL,*second=NULL;assert(h_vi_OpenDefaultDisplay(&other)==0&&other!=display);
    assert(h_vi_CreateLayer(&layer,display)==0&&h_vi_CreateLayer(&second,other)==0&&layer!=second);
    assert(h_vi_GetNativeWindow(&out.value,layer)==0&&out.value==layer);
    assert(out.before==0x12345678&&out.after==0x87654321);
    assert(h_vi_GetNativeWindow(&out.value,display)==RES_FAIL&&out.value==layer);
    assert(h_vi_CreateLayer(&out.value,(void *)1)==RES_FAIL&&out.value==layer);
    assert(h_vi_GetNativeWindow(NULL,layer)==RES_FAIL&&h_vi_CreateLayer(NULL,display)==RES_FAIL);
    h_vi_DestroyLayer(layer);assert(h_vi_GetNativeWindow(&out.value,layer)==RES_FAIL&&out.value==layer);
    h_vi_DestroyLayer(second);h_vi_CloseDisplay(other);
    pthread_t workers[4];for(unsigned i=0;i<4;i++)assert(!pthread_create(&workers[i],NULL,vi_worker,display));
    for(unsigned i=0;i<4;i++)assert(!pthread_join(workers[i],NULL));
    void *layers[VI_HANDLES];for(unsigned i=0;i<VI_HANDLES;i++)assert(h_vi_CreateLayer(&layers[i],display)==0);
    out.value=(void *)0x777;assert(h_vi_CreateLayer(&out.value,display)==RES_FAIL&&out.value==(void *)0x777);
    for(unsigned i=0;i<VI_HANDLES;i++)h_vi_DestroyLayer(layers[i]);h_vi_CloseDisplay(display);
    void *displays[VI_HANDLES];for(unsigned i=0;i<VI_HANDLES;i++)assert(h_vi_OpenDefaultDisplay(&displays[i])==0);
    assert(h_vi_OpenDefaultDisplay(&out.value)==RES_FAIL&&out.value==(void *)0x777);
    for(unsigned i=0;i<VI_HANDLES;i++)h_vi_CloseDisplay(displays[i]);
    h_vi_Finalize();assert(!vi_refs);assert(h_vi_OpenDefaultDisplay(&out.value)==RES_FAIL);
    puts("VI HOST OK: seven service adapters, guarded outputs, bounded lifetimes and 4000 concurrent layer/window cycles");return 0;
}
