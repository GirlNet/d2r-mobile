// CPU encoding is serialized; GPU execution remains asynchronous. Keep the
// persistent NVN state on the queue rather than on whichever thread last ran.
@interface NvQueueState : NSObject {
@public
    typeof(S) state;
    typeof(R) render;
    int visibility_on, visibility_counting;
    uint64_t visibility_base;
    NvVisPrefix *visibility_prefix;
    NSMutableDictionary<NSNumber *,NSMutableArray<NSString *> *> *debug_groups;
    NSString *debug_marker;
}
@end
@implementation NvQueueState
@end

void mtl_queue_restore(void **handle) {
    if(dm_guest_d2r())return;
    if(g_cb)MDIE("Queue state restore during active Metal encoding");
    NvQueueState *q=*handle?(__bridge NvQueueState *)*handle:nil;
    if(!q) {
        q=[NvQueueState new];state_reset();memset(&R,0,sizeof R);
        q->state=S;q->render=R;
        *handle=(__bridge_retained void *)q;
    }
    S=q->state;R=q->render;
    vis_clear();g_vis_on=q->visibility_on;g_vis_counting=q->visibility_counting;g_vis_base=q->visibility_base;
    g_vis_prefix=q->visibility_prefix;
    g_debug_groups=q->debug_groups;g_debug_marker=q->debug_marker;
    g_pso_dirty=g_dss_dirty=1;args_dirty_all();
}
void mtl_queue_capture(void *handle) {
    if(!handle)return;
    if(g_cb)MDIE("Queue state capture before Metal commit");
    // 异步路径已在 GPU 上折叠到不可变前缀，环形槽重用不会改写累计值。
    // 旧路径及运行时回退仍先等待，保留原有 CPU 折叠语义。
    // The async path has folded into an immutable GPU prefix before ring reuse.
    // The legacy path and runtime fallback still wait before folding on the CPU.
    if(g_nvs || (!p5r_async_visibility_on() && g_vis_prefix)) {
        if(!mtl_wait(mtl_last_fence(),5000000000ull) || mtl_last_commit_error())MDIE("Queue visibility capture synchronization failed");
        vis_fold_completed();
    }
    NvQueueState *q=(__bridge NvQueueState *)handle;
    q->state=S;q->render=R;q->visibility_on=g_vis_on;q->visibility_counting=g_vis_counting;q->visibility_base=g_vis_base;
    q->visibility_prefix=g_vis_prefix;
    q->debug_groups=g_debug_groups;q->debug_marker=g_debug_marker;
}
void mtl_queue_release(void *handle) { if(handle)CFRelease(handle); }
