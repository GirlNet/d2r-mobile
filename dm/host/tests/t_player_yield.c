// 通过真实 SVC 验证玩家包不再给让出线程计时，开发观测路径仍可用。
// Exercise the real SVC: player builds do not time yields, while developer observation still works.
#include "../dm.h"
#include "../dm_diagnostics.h"
#include <mach/mach_time.h>
#undef NDEBUG
#include <assert.h>
struct dm_flags g_flag;
uint64_t g_t0_ns;
static unsigned clocks,profiles;
void crash_thread_init(void) {}
void guest_thread_init(void) {}
void dm_thread_enter(uint64_t entry,uint64_t arg,uint64_t sp) { (void)entry;(void)arg;(void)sp;abort(); }
void *guest_sym(const char *name) { (void)name;return NULL; }
module_t *module_of(const void *address) { (void)address;return NULL; }
void dm_prof_add(int id,uint64_t ns,uint64_t bytes) { (void)id;(void)ns;(void)bytes;profiles++; }
uint64_t now_ns(void) { clocks++;return mach_absolute_time(); }
uint64_t guest_ns(void) { return now_ns(); }
int dm_detclock_enabled(void) { return 0; }
int svc_thread(int num,uint64_t *regs);
uint32_t svc_thread_main_init(void);
void dm_main_yield_stats(uint64_t *n,uint64_t *ns);
int main(void) {
    assert(svc_thread_main_init()==0x1001);g_flag.bootprof=1;clocks=profiles=0;
    for(int i=0;i<3000;i++) { uint64_t regs[32]={(uint64_t)-(i%3)};assert(svc_thread(0x0b,regs)==1); }
    uint64_t n,ns;dm_main_yield_stats(&n,&ns);
#if DM_RUNTIME_DIAGNOSTICS
    assert(n==3000 && clocks>=6000 && profiles>=3000);
#else
    assert(n==0 && ns==0 && clocks==0 && profiles==0);
#endif
    uint64_t regs[32]={1};assert(svc_thread(0x0b,regs)==1);
    puts(DM_RUNTIME_DIAGNOSTICS?"DEVELOPER YIELD OK: original timing available":"PLAYER YIELD OK: 3000 SVC yields with no observation clocks/counters");
}
