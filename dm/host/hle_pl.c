// P5R: probes for the platform ("pl") shared-font entry points.
// The game ships only small Latin bitmap fonts in its CPK; arbitrary Chinese text is rasterized at run
// time by nn::font::ll from the console's shared font, which is served by the "pl:u" system service.
// This host has no IPC/service layer, so those calls cannot reach a font. These probes only record which
// entry points the game actually calls (arguments included) and keep the previous "no font" behaviour.
// P5R：平台（pl）共享字体入口的探针。游戏 CPK 里只有小号拉丁点阵字体；任意中文文本由
// nn::font::ll 在运行时用主机的共享字体现画，而共享字体来自系统服务 "pl:u"。本宿主没有 IPC / 服务层，
// 这些调用拿不到字体。探针只记录游戏到底调了哪些入口（含参数），行为保持原来的「没有字体」。
#include "dm.h"
#include "hle.h"
#include <stdatomic.h>

static void pl_note(const char *what, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    static _Atomic int n;
    if (atomic_fetch_add(&n, 1) < 40)
        LOG("P5R pl probe %s a0=%#llx a1=%#llx a2=%#llx a3=%#llx", what,
            (unsigned long long)a0, (unsigned long long)a1, (unsigned long long)a2, (unsigned long long)a3);
}

// Result GetSharedFont(int* count, SharedFontData* out, int max, settings::LanguageCode)
HLE_FORCE_OPTIONAL("_ZN2nn2pl13GetSharedFontEPiPNS0_14SharedFontDataEiNS_8settings12LanguageCodeE",
          "P5R shared-font probe (count/out/max/language)", Result, h_pl_GetSharedFont,
          uint64_t *count, uint64_t out, int max, uint32_t lang) {
    pl_note("GetSharedFont", (uint64_t)(uintptr_t)count, out, (uint64_t)(unsigned)max, (uint64_t)lang);
    if (count) *count = 0;
    return RES_OK;
}

// void* GetSharedFontAddress(SharedFontType)
HLE_FORCE_OPTIONAL("_ZN2nn2pl20GetSharedFontAddressENS0_14SharedFontTypeE",
          "P5R shared-font probe (address)", uintptr_t, h_pl_GetSharedFontAddress, int type) {
    pl_note("GetSharedFontAddress", (uint64_t)(unsigned)type, 0, 0, 0);
    return 0;
}

// size_t GetSharedFontSize(SharedFontType)
HLE_FORCE_OPTIONAL("_ZN2nn2pl17GetSharedFontSizeENS0_14SharedFontTypeE",
          "P5R shared-font probe (size)", uint64_t, h_pl_GetSharedFontSize, int type) {
    pl_note("GetSharedFontSize", (uint64_t)(unsigned)type, 0, 0, 0);
    return 0;
}

// Result RequestSharedFontLoad(SharedFontType)
HLE_FORCE_OPTIONAL("_ZN2nn2pl21RequestSharedFontLoadENS0_14SharedFontTypeE",
          "P5R shared-font probe (request load)", Result, h_pl_RequestSharedFontLoad, int type) {
    pl_note("RequestSharedFontLoad", (uint64_t)(unsigned)type, 0, 0, 0);
    return RES_OK;
}

// Result GetSharedFontLoadState(SharedFontType)
HLE_FORCE_OPTIONAL("_ZN2nn2pl22GetSharedFontLoadStateENS0_14SharedFontTypeE",
          "P5R shared-font probe (load state)", Result, h_pl_GetSharedFontLoadState, int type) {
    pl_note("GetSharedFontLoadState", (uint64_t)(unsigned)type, 0, 0, 0);
    return RES_OK;
}

// Result GetSharedFontInOrderOfPriority(int* count, SharedFontType*, const void**, size_t*, int, LanguageCode)
HLE_FORCE_OPTIONAL("_ZN2nn2pl30GetSharedFontInOrderOfPriorityEPiPNS0_14SharedFontTypeEPPKvPmiNS_8settings12LanguageCodeE",
          "P5R shared-font probe (priority list)", Result, h_pl_GetSharedFontInOrderOfPriority,
          uint64_t *count, uint64_t types, uint64_t addrs, uint64_t sizes, int max, uint32_t lang) {
    pl_note("GetSharedFontInOrderOfPriority", (uint64_t)(uintptr_t)count, types, addrs, sizes);
    pl_note("  max/lang", (uint64_t)(unsigned)max, (uint64_t)lang, 0, 0);
    if (count) *count = 0;
    return RES_OK;
}
