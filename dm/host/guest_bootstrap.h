// 通用 SDK 启动契约：顺序依据原宿主与本机 P5R SDK 的 nn::init::Start；不包含游戏地址。
// Generic SDK bootstrap contract: ordered from the existing host and local P5R SDK nn::init::Start; contains no game addresses.
#pragma once
#include <stdint.h>

typedef struct {
    void *(*symbol)(const char *name);
    void (*module_inits)(void);
    void (*phase)(int phase);
    void (*d2r_before_main)(void);
} dm_guest_boot_ops;

int dm_guest_profile_select(const char *name);
int dm_guest_profile_p5r(void);
const char *dm_guest_profile_name(void);
const char *dm_guest_argument_name(void);
int dm_guest_sdk_bootstrap(const dm_guest_boot_ops *ops, uint64_t main_handle,
                           uint64_t argument_area, int argc, char **argv,
                           const char **missing_symbol);
