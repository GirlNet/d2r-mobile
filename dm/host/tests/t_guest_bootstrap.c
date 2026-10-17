// 用可调用的假 SDK 测试启动顺序、参数 ABI、缺入口时零执行与 P5R 的游戏钩子隔离。
// Use callable fake SDK entries to test startup order, argument ABI, zero execution on missing entries and P5R game-hook isolation.
#include "../guest_bootstrap.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int trace[32], count, absent = -1, resolved;
static uint64_t seen_handle, seen_area;
static int seen_argc;
static const char *stop_entry;
static int checkpoints;
static int checkpoint(const char *entry, int completed) {
    checkpoints++;
    return completed || !stop_entry || strcmp(entry,stop_entry);
}
static char **seen_argv;
static void note(int value) { assert(count < 32); trace[count++] = value; }
static void libc0(void) { note(0); }
static void osinit(uint64_t handle, uint64_t area) { seen_handle = handle; seen_area = area; note(1); }
static void libc1(void) { note(2); }
static void sdkinit(void) { note(3); }
static void startup(void) { note(4); }
static void libc2(void) { note(5); }
static void phase(int value) { note(value == 1 ? 6 : 8); }
static void modules(void) { note(7); }
static void setargc(int value) { seen_argc = value; note(9); }
static void setargv(char **value) { seen_argv = value; note(10); }
static void before(void) { note(11); }
static void entry(void) { note(12); }
static const char *names[] = {
    "_init_libc0", "nnosInitialize", "_init_libc1", "nninitInitializeSdkModule", "nninitStartup",
    "_init_libc2", "_ZN2nn2os11SetHostArgcEi", "_ZN2nn2os11SetHostArgvEPPc", "nnMain"
};
static void *lookup(const char *name) {
    void *functions[] = {(void *)libc0, (void *)osinit, (void *)libc1, (void *)sdkinit, (void *)startup,
                         (void *)libc2, (void *)setargc, (void *)setargv, (void *)entry};
    resolved++;
    for (int i = 0; i < 9; i++) if (!strcmp(name, names[i])) return i == absent ? NULL : functions[i];
    return NULL;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    assert(!dm_guest_profile_select("unknown"));
#ifdef DM_P5R_ONLY
    assert(!dm_guest_profile_select("d2r"));
    assert(dm_guest_profile_select(NULL));
#endif
    assert(dm_guest_profile_select(argv[1]));
    assert(dm_guest_profile_select(argv[1]));
    int p5r = !strcmp(argv[1], "p5r");
    assert(dm_guest_profile_p5r() == p5r);
    assert(!strcmp(dm_guest_argument_name(), p5r ? "P5R" : "D2R"));
    assert(!dm_guest_profile_select(p5r ? "d2r" : "p5r"));
    char *game_argv[] = {(char *)dm_guest_argument_name(), "test argument", NULL};
    const dm_guest_boot_ops ops = {lookup, modules, phase, before, NULL};
    const char *missing = NULL;
    for (absent = 0; absent < 9; absent++) {
        count = resolved = 0;
        assert(!dm_guest_sdk_bootstrap(&ops, 0x12345678, 0xABCDEF01, 2, game_argv, &missing));
        assert(missing && !strcmp(missing, names[absent]));
        assert(count == 0);
    }
    absent = -1;
    assert(dm_guest_sdk_bootstrap(&ops, 0x12345678, 0xABCDEF01, 2, game_argv, &missing));
    assert(!missing && seen_handle == 0x12345678 && seen_area == 0xABCDEF01);
    assert(seen_argc == 2 && seen_argv == game_argv);
    assert(count == (p5r ? 12 : 13));
    for (int i = 0; i < 11; i++) assert(trace[i] == i);
    if (!p5r) assert(trace[11] == 11);
    assert(trace[count - 1] == 12);
    dm_guest_boot_ops probe = ops; probe.checkpoint = checkpoint;
    for (int step = 0; step < 6; step++) {
        stop_entry = names[step]; count = checkpoints = 0;
        assert(dm_guest_sdk_bootstrap(&probe,0,0,2,game_argv,&missing) == DM_BOOT_STOPPED);
        assert(count == step && checkpoints == step * 2 + 1 && !missing);
    }
    stop_entry = "module_initializers"; count = checkpoints = 0;
    assert(dm_guest_sdk_bootstrap(&probe,0,0,2,game_argv,&missing) == DM_BOOT_STOPPED);
    assert(count == 7 && checkpoints == 13 && !missing);
    for (int i = 0; i < count; i++) assert(trace[i] == i);
    stop_entry = "nnMain"; count = checkpoints = 0;
    assert(dm_guest_sdk_bootstrap(&probe,0,0,2,game_argv,&missing) == DM_BOOT_STOPPED);
    assert(count == (p5r ? 11 : 12) && checkpoints == 19 && !missing);
    for (int i = 0; i < count; i++) assert(trace[i] == i);
    absent = 8; count = checkpoints = 0;
    assert(dm_guest_sdk_bootstrap(&probe,0,0,2,game_argv,&missing) == DM_BOOT_FAILED);
    assert(!count && !checkpoints && !strcmp(missing,"nnMain"));
    absent = -1;
    count = 0;
    assert(!dm_guest_sdk_bootstrap(NULL, 0, 0, 2, game_argv, &missing));
    assert(!dm_guest_sdk_bootstrap(&ops, 0, 0, 0, game_argv, &missing));
    assert(!dm_guest_sdk_bootstrap(&ops, 0, 0, 2, NULL, &missing));
    assert(count == 0);
    printf("BOOTSTRAP %s OK: call order, ABI, nine missing-entry checks, hook isolation\n", argv[1]);
    return 0;
}
