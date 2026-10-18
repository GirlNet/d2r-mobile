// Debug commands retain copied labels and independent domain stacks. They feed
// submission diagnostics, without changing draw state or silently losing text.
static NSMutableDictionary<NSNumber *,NSMutableArray<NSString *> *> *g_debug_groups;
static NSString *g_debug_marker;
static void replay_report_value(const p_report_value *c) {
    // The SDK requests a four-word report (payload + timestamp), not a one-word
    // semaphore. Field definitions: NVIDIA open-gpu-doc, clb197.h, 0x1b00-0x1b0c.
    void *native=NULL;uint64_t offset=0;
    if((c->address&15) || !mtl_addr(c->address,16,&native,&offset))MDIE("ReportValue destination invalid");
    id<MTLBuffer> buffer=(__bridge id<MTLBuffer>)native;
    if(!buffer.contents)MDIE("ReportValue destination is not CPU-readable");
    post((post_op){.kind=4,.v=c->value,.addr=(uint64_t)((uint8_t *)buffer.contents+offset)});
    // Make the report visible before a later GPU copy/dispatch can read it.
    // This includes callback completion, unlike waiting only for the GPU event.
    uint64_t fence=mtl_sub_commit();
    if(!mtl_wait(fence,5000000000ull) || mtl_last_commit_error())MDIE("ReportValue synchronization failed");
    vis_fold_completed();mtl_sub_begin();
}
static void replay_debug_marker(const p_debug_marker *m) {
    if(m->length>4096 || m->text[m->length])MDIE("Invalid recorded debug label");
    NSString *text=[[NSString alloc] initWithBytes:m->text length:m->length encoding:NSUTF8StringEncoding];
    if(!text)text=[NSString stringWithFormat:@"<non-UTF8 label, %u bytes>",m->length];
    if(!g_debug_groups)g_debug_groups=[NSMutableDictionary dictionary];
    NSNumber *domain=@(m->domain);NSMutableArray<NSString *> *stack=g_debug_groups[domain];
    if(m->action==0) {
        if(!stack){stack=[NSMutableArray array];g_debug_groups[domain]=stack;}
        if(stack.count>=256)MDIE("NVN debug group nesting exceeds 256");
        [stack addObject:text];
    } else if(m->action==1) {
        if(stack.count)[stack removeLastObject];
        if(!stack.count)[g_debug_groups removeObjectForKey:domain];
    } else if(m->action!=2)MDIE("Invalid recorded debug action");
    g_debug_marker=[NSString stringWithFormat:@"domain=%u action=%u %@",m->domain,m->action,text];
    PD("debug %s",g_debug_marker.UTF8String);
}
static void replay_command_sync(const p_command_sync *c) {
    sync_t *s=c->sync;
    if(!s || s->magic!=MAGIC('S','Y','N','C') || s->dev!=c->dev)MDIE("Command sync object/device changed before replay");
    if(c->wait) {
        if(!__atomic_load_n(&s->fenced,__ATOMIC_ACQUIRE))MDIE("Command wait references an unfenced sync");
        uint64_t dependency=__atomic_load_n(&s->fence,__ATOMIC_ACQUIRE);
        if(dependency>mtl_last_fence())MDIE("Command wait references an unsubmitted fence");
        // Submit prior work before the queue dependency, so later commands
        // cannot accidentally enter the command buffer preceding the wait.
        mtl_sub_commit();mtl_queue_wait(dependency);mtl_sub_begin();
    } else {
        uint64_t fence=mtl_sub_commit();
        __atomic_store_n(&s->fence,fence,__ATOMIC_RELEASE);
        __atomic_store_n(&s->fenced,1,__ATOMIC_RELEASE);
        mtl_sub_begin();
    }
}
