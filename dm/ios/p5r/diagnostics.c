// P5R 通用诊断：真实阶段时间和性能计数，不接入 D2R 的 UI、角色或固定地址观测。
// P5R generic diagnostics: real phase timing and performance counters without D2R UI, character or fixed-address observations.
#include "dm.h"
#include "dm_diagnostics.h"
#include <stdatomic.h>

#if DM_RUNTIME_DIAGNOSTICS
static _Atomic uint64_t elapsed[PROF_N], transferred[PROF_N], frames;
void dm_prof_add(int id, uint64_t ns, uint64_t bytes) {
    if (id < 0 || id >= PROF_N) return;
    atomic_fetch_add(elapsed + id, ns); atomic_fetch_add(transferred + id, bytes);
}
void dm_prof_mark(const char *phase) {
    if (g_flag.bootprof) LOG("P5R phase %.3f s: %s", (now_ns() - g_t0_ns) / 1e9, phase);
}
void dm_perf_present(double interval) {
    uint64_t frame = atomic_fetch_add(&frames, 1) + 1;
    if (getenv("DM_PRESENT_LOG") && (frame == 1 || frame % 300 == 0)) LOG("P5R present %llu interval %.3f ms", frame, interval);
}
void crash_sample_self(void) {
    if (getenv("DM_SAMPLE")) LOG("P5R sampling uses crash dumps; D2R tick sampling is unavailable");
}
#else
void dm_prof_add(int id, uint64_t ns, uint64_t bytes) { (void)id; (void)ns; (void)bytes; }
void dm_prof_mark(const char *phase) { (void)phase; }
void dm_perf_present(double interval) { (void)interval; }
void crash_sample_self(void) {}
#endif
