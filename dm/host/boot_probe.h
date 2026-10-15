// P5R 初始化诊断：选择在模块或游戏主函数前停止，并持久化检查点；始终阻止图形初始化，旧宿主保持无操作。
// P5R initialization probe: persist checkpoints and stop before modules or game main; always block graphics initialization and keep legacy hooks inert.
#pragma once
#ifdef DM_P5R_ONLY
int dm_boot_probe_begin(const char *directory);
int dm_boot_probe_begin_modules(const char *directory);
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
