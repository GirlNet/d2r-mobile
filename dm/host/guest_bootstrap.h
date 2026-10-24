// 通用 SDK 启动契约：顺序依据原宿主与本机 P5R SDK 的 nn::init::Start；不包含游戏地址。
// Generic SDK bootstrap contract: ordered from the existing host and local P5R SDK nn::init::Start; contains no game addresses.
#pragma once
#include <stdint.h>

typedef struct {
    void *(*symbol)(const char *name);
    void (*module_inits)(void);
    void (*phase)(int phase);
    void (*d2r_before_main)(void);
    int (*checkpoint)(const char *entry, int completed);
} dm_guest_boot_ops;

// 检查点返回零时，在下一步执行前停止；不把诊断停止报告成 nnMain 已返回。
// A zero checkpoint result stops before the next step; a diagnostic stop is not reported as nnMain returning.
enum { DM_BOOT_FAILED = 0, DM_BOOT_COMPLETE = 1, DM_BOOT_STOPPED = 2 };

int dm_guest_profile_select(const char *name);
int dm_guest_profile_p5r(void);
const char *dm_guest_profile_name(void);
const char *dm_guest_argument_name(void);
int dm_guest_sdk_bootstrap(const dm_guest_boot_ops *ops, uint64_t main_handle,
                           uint64_t argument_area, int argc, char **argv,
                           const char **missing_symbol);
