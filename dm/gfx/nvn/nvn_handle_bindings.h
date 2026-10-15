// NVN 句柄表：组合槽与分离槽分别保存；布局依据 SDK 的 BindTextures/BindSeparateTextures 写入位置。
// NVN handle tables: retain combined and separate slots independently; layout follows SDK BindTextures/BindSeparateTextures writes.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum { NVN_SEPARATE_TEX_SLOTS = 128, NVN_COMBINED_TEX_FIRST = 128,
       NVN_COMBINED_TEX_SLOTS = 32, NVN_TEX_SLOTS = 160,
       NVN_IMAGE_SLOTS = 32, NVN_TRACKED_TEXTURE_SLOTS = 192 };

static inline int nvn_handle_range(int stage, int first, int count, int limit) {
    return stage >= 0 && stage < 6 && first >= 0 && first <= limit &&
           count >= 0 && count <= 32 && count <= limit - first;
}

static inline uint64_t nvn_combined_handle(int texture, int sampler) {
    uint32_t packed = (uint32_t)texture | (uint32_t)sampler << 20;
    return (uint64_t)(int64_t)(int32_t)packed | UINT64_C(0x100000000);
}

static inline unsigned nvn_handle_sampler_id(uint64_t handle) {
    return ((uint32_t)handle >> 20) & 0xfff;
}

static inline int nvn_apply_handles(void *table, int limit, int stage, int first,
                                    int count, const uint64_t *handles) {
    if (!table || !nvn_handle_range(stage, first, count, limit) || !count || !handles) return 0;
    uint64_t *destination = (uint64_t *)((uint8_t *)table + ((size_t)stage * limit + first) * 8);
    if (!memcmp(destination, handles, (size_t)count * 8)) return 0;
    memcpy(destination, handles, (size_t)count * 8);
    return 1;
}

static inline int nvn_fill_texture_driver(void *destination, size_t size,
                                           const uint64_t *textures, const uint64_t *samplers) {
    if (!destination || !textures || !samplers || size < 0x968) return 0;
    uint8_t *bytes = destination;
    for (int i = 0; i < NVN_COMBINED_TEX_SLOTS; i++)
        memcpy(bytes + 0x20 + 8 * i, textures + NVN_COMBINED_TEX_FIRST + i, 8);
    for (int i = 0; i < NVN_SEPARATE_TEX_SLOTS; i++) {
        uint32_t texture = (uint32_t)textures[i], sampler = (uint32_t)samplers[i];
        memcpy(bytes + 0x168 + 8 * i, &texture, 4);
        memcpy(bytes + 0x568 + 8 * i, &sampler, 4);
    }
    return 1;
}
