// Executable command families: sync points and copied diagnostic breadcrumbs.
#include <math.h>
static void record_dynamic_float(NVNcommandBuffer *c, unsigned kind, float value) {
    if(!isfinite(value) || (kind<2 && value<=0))die("Invalid dynamic raster value: kind=%u value=%g",kind,value);
    p_dynamic_state *p=REC(c,OP_DYNAMIC_STATE,p_dynamic_state);p->kind=kind;p->f[0]=value;
}
NVN(nvnCommandBufferSetPointSize, void, NVNcommandBuffer *c, float value) {record_dynamic_float(c,0,value);}
NVN(nvnCommandBufferSetLineWidth, void, NVNcommandBuffer *c, float value) {record_dynamic_float(c,1,value);}
NVN(nvnCommandBufferSetAlphaRef, void, NVNcommandBuffer *c, float value) {record_dynamic_float(c,2,value);}
NVN(nvnCommandBufferSetConservativeRasterDilate, void, NVNcommandBuffer *c, float value) {record_dynamic_float(c,3,value);}
NVN(nvnCommandBufferSetSubpixelPrecisionBias, void, NVNcommandBuffer *c, int x, int y) {
    p_dynamic_state *p=REC(c,OP_DYNAMIC_STATE,p_dynamic_state);p->kind=4;p->i[0]=x;p->i[1]=y;
}
NVN(nvnCommandBufferSetViewportSwizzles, void, NVNcommandBuffer *c, int first, int n, const NVNviewportSwizzle *swizzles) {
    if(!uniform_viewport_batch("SetViewportSwizzles",first,n,swizzles,4*sizeof *swizzles))return;
    p_dynamic_state *p=REC(c,OP_DYNAMIC_STATE,p_dynamic_state);p->kind=5;memcpy(p->i,swizzles,16);
}
NVN(nvnCommandBufferSetTiledCacheAction, void, NVNcommandBuffer *c, NVNtiledCacheAction action) {
    if(action<1 || action>6)die("Invalid tiled cache action %d",action);
    p_dynamic_state *p=REC(c,OP_CACHE_HINT,p_dynamic_state);p->kind=6;p->i[0]=action;
}
NVN(nvnCommandBufferSetTiledCacheTileSize, void, NVNcommandBuffer *c, int width, int height) {
    if(width<0 || height<0)die("Invalid tiled cache size %dx%d",width,height);
    p_dynamic_state *p=REC(c,OP_DYNAMIC_STATE,p_dynamic_state);p->kind=7;p->i[0]=width;p->i[1]=height;
}
NVN(nvnCommandBufferReportValue, void, NVNcommandBuffer *c, uint32_t value, NVNbufferAddress address) {
    *REC(c,OP_REPORT_VALUE,p_report_value)=(p_report_value){address,value};
}
static void record_command_sync(NVNcommandBuffer *c, NVNsync *s, int wait, int condition, int flags) {
    const sync_t *sync=(const sync_t *)s;
    if(!sync || sync->magic!=MAGIC('S','Y','N','C') || sync->dev!=CB(c)->dev)
        die("Command sync object/device mismatch");
    if(!wait && (condition<0 || condition>1 || (flags & ~1)))
        die("Unsupported command sync condition/flags: %d/%#x",condition,flags);
    *REC(c,OP_COMMAND_SYNC,p_command_sync)=(p_command_sync){(sync_t *)s,CB(c)->dev,wait,condition,flags};
}
NVN(nvnCommandBufferFenceSync, void, NVNcommandBuffer *c, NVNsync *s, NVNsyncCondition condition, int flags) {
    record_command_sync(c,s,0,condition,flags);
}
NVN(nvnCommandBufferWaitSync, void, NVNcommandBuffer *c, const NVNsync *s) {
    record_command_sync(c,(NVNsync *)s,1,0,0);
}
static void record_debug_marker(NVNcommandBuffer *c, unsigned action, uint32_t domain, const char *text) {
    size_t n=text?strnlen(text,4097):0;
    if(n>4096)die("NVN debug label exceeds 4096 bytes");
    p_debug_marker *m=rec(c,OP_DEBUG_MARKER,sizeof *m+n+1);
    m->action=action;m->domain=domain;m->length=(uint32_t)n;
    if(n)memcpy(m->text,text,n);m->text[n]=0;
}
NVN(nvnCommandBufferPushDebugGroupStatic, void, NVNcommandBuffer *c, uint32_t domain, const char *text) {record_debug_marker(c,0,domain,text);}
NVN(nvnCommandBufferPushDebugGroupDynamic, void, NVNcommandBuffer *c, uint32_t domain, const char *text) {record_debug_marker(c,0,domain,text);}
NVN(nvnCommandBufferPushDebugGroup, void, NVNcommandBuffer *c, const char *text) {record_debug_marker(c,0,0,text);}
NVN(nvnCommandBufferPopDebugGroup, void, NVNcommandBuffer *c) {record_debug_marker(c,1,0,NULL);}
NVN(nvnCommandBufferPopDebugGroupId, void, NVNcommandBuffer *c, uint32_t domain) {record_debug_marker(c,1,domain,NULL);}
NVN(nvnCommandBufferInsertDebugMarkerStatic, void, NVNcommandBuffer *c, uint32_t domain, const char *text) {record_debug_marker(c,2,domain,text);}
NVN(nvnCommandBufferInsertDebugMarkerDynamic, void, NVNcommandBuffer *c, uint32_t domain, const char *text) {record_debug_marker(c,2,domain,text);}
NVN(nvnCommandBufferInsertDebugMarker, void, NVNcommandBuffer *c, const char *text) {record_debug_marker(c,2,0,text);}
