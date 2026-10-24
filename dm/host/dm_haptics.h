#pragma once
#include <stdint.h>

// P5R HD 震动：把 nn::hid 的两个虚拟马达（左右 Joy-Con）混合成单路 Core Haptics 输出。
// 混合器（hle_hid.c）保存每个马达的 VibrationValue，清洗输入后合并频段能量并去重；
// iOS 前端（dm/ios/p5r/haptics.m）持有 Core Haptics 引擎并通过 dm_haptics_platform_apply 接收混合结果。
// P5R HD haptics: mix the two virtual nn::hid motors (left/right Joy-Con) into one Core Haptics output.
// The mixer (hle_hid.c) stores each motor's VibrationValue, sanitises input, merges band energy and dedupes;
// the iOS front end (dm/ios/p5r/haptics.m) owns the Core Haptics engine and receives the mix via dm_haptics_platform_apply.

typedef struct { float amplitude_low, frequency_low, amplitude_high, frequency_high; } dm_vibration_value;
typedef struct { uint32_t type, position; } dm_vibration_info;

typedef struct { float intensity, sharpness; uint64_t epoch; } dm_haptic_output;
typedef struct {
    uint64_t requests, nonzero_requests, output_changes, stops, epoch;
    unsigned supported, suspended;
    dm_haptic_output output;
} dm_haptic_status;

enum { DM_HAPTICS_INACTIVE = 1u, DM_HAPTICS_INTERRUPTED = 2u };
enum { DM_VIBRATION_LEFT = 0x53530001u, DM_VIBRATION_RIGHT = 0x53530002u };

void dm_haptics_configure(int supported);
void dm_haptics_suspend_for(unsigned reason, int suspended);
int dm_haptics_allowed(void);
void dm_haptics_initialize(uint32_t handle);
void dm_haptics_send(uint32_t handle, const dm_vibration_value *value);
dm_vibration_value dm_haptics_actual(uint32_t handle);
void dm_haptics_stop(void);
dm_haptic_status dm_haptics_status(void);

// iOS 前端拥有 Core Haptics 引擎；宿主的 CLI 无落点。由 dm/ios/p5r/haptics.m 提供。
// The iOS front end owns the Core Haptics engine; the host CLI has no sink. Provided by dm/ios/p5r/haptics.m.
void dm_haptics_ios_init(void);
void dm_haptics_platform_apply(dm_haptic_output output);
