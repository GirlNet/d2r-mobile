// P5R 初始化诊断：持久化检查点，模块初始化/图形初始化前停止；旧宿主保持无操作。
// P5R initialization probe: persist checkpoints and stop before module/graphics initialization; the legacy host keeps no-op hooks.
#pragma once
#ifdef DM_P5R_ONLY
int dm_boot_probe_begin(const char *directory);
int dm_boot_probe_active(void);
void dm_boot_probe_note(const char *event, const char *detail);
void dm_boot_probe_failure(const char *reason);
int dm_boot_probe_checkpoint(const char *entry, int completed);
void dm_boot_probe_block(const char *boundary, const char *detail);
int dm_boot_probe_timeout(void);
#else
static inline int dm_boot_probe_active(void) { return 0; }
static inline void dm_boot_probe_note(const char *event, const char *detail) { (void)event; (void)detail; }
static inline void dm_boot_probe_failure(const char *reason) { (void)reason; }
static inline int dm_boot_probe_checkpoint(const char *entry, int completed) { (void)entry; (void)completed; return 1; }
static inline void dm_boot_probe_block(const char *boundary, const char *detail) { (void)boundary; (void)detail; }
#endif
