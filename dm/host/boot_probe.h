// P5R 分阶段初始化诊断：可停止在模块、游戏主函数或图形初始化前，或在后端初始化完成后；持久化检查点，旧宿主保持无操作。
// P5R staged initialization probes: stop before modules, game main or graphics initialization, or after backend setup; persist checkpoints and keep legacy hooks inert.
#pragma once
#include "dm_diagnostics.h"
#if defined(DM_P5R_ONLY) && DM_RUNTIME_DIAGNOSTICS
int dm_boot_probe_begin(const char *directory);
int dm_boot_probe_begin_modules(const char *directory);
int dm_boot_probe_begin_startup(const char *directory);
int dm_boot_probe_begin_gpu_setup(const char *directory);
int dm_boot_probe_begin_pre_submit(const char *directory);
int dm_boot_probe_gpu_begin(void);
void dm_boot_probe_gpu_complete(const char *backend, const char *device);
int dm_boot_probe_active(void);
int dm_boot_probe_capture_command(const char *name, unsigned count, const unsigned long long *arguments);
void dm_boot_probe_note(const char *event, const char *detail);
void dm_boot_probe_failure(const char *reason);
int dm_boot_probe_checkpoint(const char *entry, int completed);
void dm_boot_probe_block(const char *boundary, const char *detail);
int dm_boot_probe_timeout(void);
#else
static inline int dm_boot_probe_begin(const char *directory) { (void)directory; return 0; }
static inline int dm_boot_probe_begin_modules(const char *directory) { (void)directory; return 0; }
static inline int dm_boot_probe_begin_startup(const char *directory) { (void)directory; return 0; }
static inline int dm_boot_probe_begin_gpu_setup(const char *directory) { (void)directory; return 0; }
static inline int dm_boot_probe_begin_pre_submit(const char *directory) { (void)directory; return 0; }
static inline int dm_boot_probe_gpu_begin(void) { return 0; }
static inline void dm_boot_probe_gpu_complete(const char *backend, const char *device) { (void)backend; (void)device; }
static inline int dm_boot_probe_active(void) { return 0; }
static inline int dm_boot_probe_capture_command(const char *name, unsigned count, const unsigned long long *arguments) { (void)name; (void)count; (void)arguments; return 0; }
static inline void dm_boot_probe_note(const char *event, const char *detail) { (void)event; (void)detail; }
static inline void dm_boot_probe_failure(const char *reason) { (void)reason; }
static inline int dm_boot_probe_checkpoint(const char *entry, int completed) { (void)entry; (void)completed; return 1; }
static inline void dm_boot_probe_block(const char *boundary, const char *detail) { (void)boundary; (void)detail; }
static inline int dm_boot_probe_timeout(void) { return 0; }
#endif

// GPU 提交必须在求值前经过诊断边界；驻留集元数据 commit 不属于命令提交。
// GPU submission must pass the probe boundary before evaluation; residency-set metadata commits are not command submissions.
#define DM_GPU_SUBMIT(...) do { dm_boot_probe_block("guest_gpu_submission",__func__); __VA_ARGS__; } while (0)
