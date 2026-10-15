// 将平台 SDK 初始化与游戏专用启动钩子分离，按符号解析并在执行前检查全部入口。
// 顺序依据原宿主和本机 Switch P5R SDK 的 Start；不使用游戏或 SDK 固定偏移。
// Separate platform SDK initialization from game-specific bootstrap hooks; resolve and check every entry before execution.
// Order follows the original host and local Switch P5R SDK Start; uses no fixed game or SDK offsets.
#include "guest_bootstrap.h"
#include <stdatomic.h>
#include <string.h>

static _Atomic int g_profile;
int dm_guest_profile_select(const char *name) {
#ifdef DM_P5R_ONLY
    int value = !name || !*name || !strcmp(name, "p5r") ? 2 : 0;
#else
    int value = !name || !*name || !strcmp(name, "d2r") ? 1 : !strcmp(name, "p5r") ? 2 : 0;
#endif
    if (!value) return 0;
    int expected = 0;
    return atomic_compare_exchange_strong(&g_profile, &expected, value) || expected == value;
}
int dm_guest_profile_p5r(void) { return atomic_load(&g_profile) == 2; }
const char *dm_guest_profile_name(void) { return dm_guest_profile_p5r() ? "p5r" : "d2r"; }
const char *dm_guest_argument_name(void) { return dm_guest_profile_p5r() ? "P5R" : "D2R"; }

int dm_guest_sdk_bootstrap(const dm_guest_boot_ops *ops, uint64_t main_handle,
                           uint64_t argument_area, int argc, char **argv,
                           const char **missing_symbol) {
    static const char *names[] = {
        "_init_libc0", "nnosInitialize", "_init_libc1", "nninitInitializeSdkModule",
        "nninitStartup", "_init_libc2", "_ZN2nn2os11SetHostArgcEi", "_ZN2nn2os11SetHostArgvEPPc", "nnMain"
    };
    void *entries[sizeof names / sizeof *names];
    if (missing_symbol) *missing_symbol = NULL;
    if (!ops || !ops->symbol || !ops->module_inits || argc < 1 || !argv) return 0;
    for (unsigned i = 0; i < sizeof names / sizeof *names; i++) {
        entries[i] = ops->symbol(names[i]);
        if (!entries[i]) { if (missing_symbol) *missing_symbol = names[i]; return 0; }
    }
    ((void (*)(void))entries[0])();
    ((void (*)(uint64_t, uint64_t))entries[1])(main_handle, argument_area);
    ((void (*)(void))entries[2])();
    ((void (*)(void))entries[3])();
    ((void (*)(void))entries[4])();
    ((void (*)(void))entries[5])();
    if (ops->phase) ops->phase(1);
    ops->module_inits();
    if (ops->phase) ops->phase(2);
    ((void (*)(int))entries[6])(argc);
    ((void (*)(char **))entries[7])(argv);
    if (!dm_guest_profile_p5r() && ops->d2r_before_main) ops->d2r_before_main();
    ((void (*)(void))entries[8])();
    return 1;
}
