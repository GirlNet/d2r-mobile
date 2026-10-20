// P5R font provisioning.
// The game links Nintendo's font engine (nn::font::ll) and asks the platform layer
// (nn::pl) for the console's shared font. That call never leaves the guest module, so an
// import-level HLE entry cannot see it; this file patches the function entry with a jump
// into the host and records what the engine asks for.
// P5R 字体供给：游戏静态链接了 nn::font::ll，并向平台层（nn::pl）索取主机共享字体。
// 这个调用不跨模块，导入级 HLE 看不到；这里在装载后把函数入口改成跳进宿主，记录引擎要什么。
#include "dm.h"
#include "hle.h"
#include <stdatomic.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>

void *module_sym(module_t *m, const char *name);
extern module_t g_mod[];
extern int g_nmod;

static int patch_jump(void *fn, const void *target) {
    if (!fn) return 0;
    uintptr_t page = (uintptr_t)fn & ~(uintptr_t)0x3fff;   // 16 KB page on Apple silicon
    size_t len = 0x8000;
    if (mprotect((void *)page, len, PROT_READ | PROT_WRITE)) return 0;
    uint32_t code[2] = {0x58000050u, 0xD61F0200u};   // ldr x16, #8 ; br x16
    memcpy(fn, code, 8);
    memcpy((uint8_t *)fn + 8, &target, sizeof target);
    sys_icache_invalidate(fn, 16);   // Darwin：刷新指令缓存（__builtin___clear_cache 在 Apple 上不可链接） | Darwin: flush the instruction cache
    mprotect((void *)page, len, PROT_READ | PROT_EXEC);
    return 1;
}

static void *find_symbol(const char *name) {
    for (int i = 0; i < g_nmod; i++) {
        void *p = module_sym(&g_mod[i], name);
        if (p) return p;
    }
    return NULL;
}

static _Atomic int g_pl_calls;
static void pl_note(const char *what, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    if (atomic_fetch_add(&g_pl_calls, 1) < 60)
        LOG("P5R font call %s a0=%#llx a1=%#llx a2=%#llx a3=%#llx", what,
            (unsigned long long)a0, (unsigned long long)a1, (unsigned long long)a2, (unsigned long long)a3);
}

// Same signatures as nn::pl; the host answers "no font" for now so the engine's behaviour
// is unchanged, but the call itself becomes visible.
static uint32_t font_GetSharedFont(int *count, void *out, int max, uint32_t lang) {
    pl_note("GetSharedFont", (uint64_t)(uintptr_t)count, (uint64_t)(uintptr_t)out, (uint64_t)(unsigned)max, lang);
    if (count) *count = 0;
    return 0;
}
static uint64_t font_GetSharedFontAddress(int type) {
    pl_note("GetSharedFontAddress", (uint64_t)(unsigned)type, 0, 0, 0);
    return 0;
}
static uint64_t font_GetSharedFontSize(int type) {
    pl_note("GetSharedFontSize", (uint64_t)(unsigned)type, 0, 0, 0);
    return 0;
}
static uint32_t font_RequestSharedFontLoad(int type) {
    pl_note("RequestSharedFontLoad", (uint64_t)(unsigned)type, 0, 0, 0);
    return 0;
}
static uint32_t font_GetSharedFontLoadState(int type) {
    pl_note("GetSharedFontLoadState", (uint64_t)(unsigned)type, 0, 0, 0);
    return 0;
}

// Font engine entry points (nn::font::ll::ScalableFontEngine). These are guest definitions too,
// so they are reached the same way: patch the entry and jump into the host.
// 字体引擎入口（nn::font::ll::ScalableFontEngine）：同样是客体定义，用同样的方式拦截。
static _Atomic int g_fe_calls;
static void fe_note(const char *what, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    if (atomic_fetch_add(&g_fe_calls, 1) < 60)
        LOG("P5R font engine %s a0=%#llx a1=%#llx a2=%#llx a3=%#llx", what,
            (unsigned long long)a0, (unsigned long long)a1, (unsigned long long)a2, (unsigned long long)a3);
}
// LoadFont(char* name, const void* data, u32 size, u32 index): log the data pointer and its first bytes.
static uint32_t fe_LoadFont(char *name, const void *data, uint32_t size, uint32_t index) {
    fe_note("LoadFont", (uint64_t)(uintptr_t)name, (uint64_t)(uintptr_t)data, (uint64_t)size, (uint64_t)index);
    if (name) LOG("P5R font engine LoadFont name=%s", name);
    if (data) {
        const uint8_t *p = data; char hex[80]; size_t o = 0;
        for (int i = 0; i < 24 && o + 3 < sizeof hex; i++) o += snprintf(hex + o, sizeof hex - o, "%02x", p[i]);
        LOG("P5R font engine data head=%s", hex);
    }
    return 0;   // "loaded": the engine already behaves as if no font data arrived | 视为已加载：行为与现在一致
}
static uint32_t fe_SetFont(char *name) {
    fe_note("SetFont", (uint64_t)(uintptr_t)name, 0, 0, 0);
    if (name) LOG("P5R font engine SetFont name=%s", name);
    return 0;
}
static void *fe_AcquireGlyphmap(uint32_t cp, uint16_t size) {
    fe_note("AcquireGlyphmap", (uint64_t)cp, (uint64_t)size, 0, 0);
    return NULL;
}
static uint32_t fe_Initialize(void *a, uint32_t b) {
    fe_note("Initialize", (uint64_t)(uintptr_t)a, (uint64_t)b, 0, 0);
    return 0;
}

void dm_font_patch(void) {
    if (dm_guest_d2r()) return;
    struct { const char *name; void *fn; } tab[] = {
        {"_ZN2nn2pl13GetSharedFontEPiPNS0_14SharedFontDataEiNS_8settings12LanguageCodeE", (void *)font_GetSharedFont},
        {"_ZN2nn2pl20GetSharedFontAddressENS0_14SharedFontTypeE", (void *)font_GetSharedFontAddress},
        {"_ZN2nn2pl17GetSharedFontSizeENS0_14SharedFontTypeE", (void *)font_GetSharedFontSize},
        {"_ZN2nn2pl21RequestSharedFontLoadENS0_14SharedFontTypeE", (void *)font_RequestSharedFontLoad},
        {"_ZN2nn2pl22GetSharedFontLoadStateENS0_14SharedFontTypeE", (void *)font_GetSharedFontLoadState},
        {"_ZN2nn6fontll18ScalableFontEngine8LoadFontEPcPKvjj", (void *)fe_LoadFont},
        {"_ZN2nn6fontll18ScalableFontEngine7SetFontEPc", (void *)fe_SetFont},
        {"_ZN2nn6fontll18ScalableFontEngine15AcquireGlyphmapEjt", (void *)fe_AcquireGlyphmap},
        {"_ZN2nn6fontll18ScalableFontEngine10InitializeEPvj", (void *)fe_Initialize},
    };
    int ok = 0, miss = 0;
    for (unsigned i = 0; i < sizeof tab / sizeof *tab; i++) {
        void *sym = find_symbol(tab[i].name);
        if (!sym) { miss++; continue; }
        if (patch_jump(sym, tab[i].fn)) ok++;
    }
    LOG("P5R font hook: patched %d entry points, %d not found", ok, miss);
}
