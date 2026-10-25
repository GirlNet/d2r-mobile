// P5R Metal 4：合并相邻的纯缓冲任务；依据统一计算编码器的显式阶段屏障保持读写顺序。
// P5R Metal 4: batch adjacent buffer-only work, preserving order with explicit unified-compute stage barriers.
// 保留真机调试开关与计数，防止发布优化删掉同包对照所需的观测点。
// Retain the device switch and counters so release optimization preserves same-package comparisons.
static volatile int g_p5r_compute_batch = -1;
static volatile uint64_t g_compute_batch_encoders, g_compute_batch_ops, g_compute_batch_barriers;
#if !DM_NVN_M3
static CENC g_compute_batch_encoder;
static unsigned g_compute_batch_count;
static int g_compute_batch_scope;
static int compute_batch_on(void) {
    if (g_p5r_compute_batch < 0) {
        const char *v = getenv("DM_P5R_COMPUTE_BATCH");
        // 长时间真机对照未证实收益；默认保持原路径，仅显式开启用于实验。
        // Sustained device comparisons did not establish a benefit; keep the original path unless explicitly testing.
        g_p5r_compute_batch = v && atoi(v) != 0;
    }
    return !dm_guest_d2r() && g_p5r_compute_batch && on_sub_thread();
}
static void compute_batch_flush(void) {
    CENC e = g_compute_batch_encoder;
    if (!e) return;
    g_compute_batch_encoder = nil;
    g_compute_batch_count = 0;
    if (g_blit == e) g_blit = nil;
    m4_end(e);
}
static void compute_batch_stop(void) {
    compute_batch_flush();
    g_compute_batch_scope = 0;
}
static int compute_batch_shared(id e) { return e && e == g_compute_batch_encoder; }
static CENC compute_batch_get(void) {
    if (!g_compute_batch_scope || !compute_batch_on()) return nil;
    if (!g_compute_batch_encoder) {
        CENC e = [g_cb computeCommandEncoder];
        [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        [e setArgumentTable:g_ct];
        pg4_begin(e, 'C', nil);
        g_compute_batch_encoder = e;
        g_compute_batch_count = 1;
        g_compute_batch_encoders++;
        g_compute_batch_ops++;
    }
    return g_compute_batch_encoder;
}
static void compute_batch_op(unsigned op) {
    int work = op == OP_DISPATCH || op == OP_UPDATE_UB || op == OP_COPY_B2B || op == OP_CLEAR_BUF;
    int binding = op == OP_BIND_PROGRAM || op == OP_BIND_UBO || op == OP_BIND_SSBO;
    if (!compute_batch_on() || (!work && !binding)) { compute_batch_stop(); return; }
    g_compute_batch_scope = 1;
    if (!work || !g_compute_batch_encoder) return;
    // 限制编码器寿命；每条任务间保留读后写、写后读和写后写依赖。
    // Bound encoder lifetime; retain WAR, RAW and WAW dependencies between work items.
    if (g_compute_batch_count >= 64) { compute_batch_flush(); return; }
    MTLStages stages = MTLStageDispatch | MTLStageBlit;
    [g_compute_batch_encoder barrierAfterEncoderStages:stages beforeEncoderStages:stages visibilityOptions:MTL4VisibilityOptionDevice];
    g_compute_batch_count++;
    g_compute_batch_ops++;
    g_compute_batch_barriers++;
}
#else
static void compute_batch_stop(void) {}
static void compute_batch_op(unsigned op) { (void)op; }
static int compute_batch_shared(id e) { (void)e; return 0; }
#endif
static int compute_batch_buffer_only(const nvn_refl *rf) {
    if (!rf->tg[0] || rf->nb < 0 || rf->nb > NVN_REFL_MAXB) return 0;
    for (int i = 0; i < rf->nb; i++) switch (rf->b[i].kind) {
        case NVN_RB_CBUF: case NVN_RB_SBUFP: case NVN_RB_UBOP:
        case NVN_RB_C1: case NVN_RB_SUPPORT: case NVN_RB_DRV0: break;
        default: return 0;
    }
    return 1;
}
