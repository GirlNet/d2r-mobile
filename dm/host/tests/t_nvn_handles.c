// 合成句柄测试：验证组合/分离状态隔离、阶段隔离、边界与驱动表布局，不包含游戏内容。
// Synthetic handles test combined/separate state isolation, stage isolation, bounds and driver table layout without game content.
#include "../../gfx/nvn/nvn_refl.h"
#include <limits.h>
#include <stdio.h>

#define CHECK(expression) do { if (!(expression)) { fprintf(stderr, "NVN handle check failed at %d\n", __LINE__); return 1; } } while (0)

int main(void) {
    uint64_t table[6][NVN_TEX_SLOTS] = {{0}}, samplers[128] = {0};
    uint64_t separate = 17, combined = nvn_combined_handle(23, 11);
    CHECK(combined == UINT64_C(0x100b00017));
    CHECK(nvn_combined_handle(23, 0) == UINT64_C(0x100000017));
    CHECK(nvn_combined_handle(0xfffff, 0xfff) == UINT64_MAX);
    CHECK(nvn_handle_sampler_id(combined) == 11);
    CHECK(nvn_handle_sampler_id(UINT64_MAX) == 0xfff);
    CHECK(nvn_handle_texture_id(UINT64_MAX) == 0xfffff);
    CHECK(nvn_apply_handles(table, NVN_TEX_SLOTS, 1, 0, 1, &separate));
    CHECK(nvn_apply_handles(table, NVN_TEX_SLOTS, 1, NVN_COMBINED_TEX_FIRST, 1, &combined));
    CHECK(table[1][0] == separate && table[1][NVN_COMBINED_TEX_FIRST] == combined && !table[0][0]);
    CHECK(!nvn_apply_handles(table, NVN_TEX_SLOTS, 1, NVN_COMBINED_TEX_FIRST, 1, &combined));
    uint64_t snapshot[6][NVN_TEX_SLOTS]; memcpy(snapshot, table, sizeof table);
    const int invalid[][3] = {{-1,0,1},{6,0,1},{1,-1,1},{1,159,2},{1,160,1},{1,INT_MAX,1},{1,0,-1},{1,0,33}};
    for (unsigned i = 0; i < sizeof invalid / sizeof *invalid; i++)
        CHECK(!nvn_apply_handles(table, NVN_TEX_SLOTS, invalid[i][0], invalid[i][1], invalid[i][2], &combined));
    CHECK(!nvn_apply_handles(table, NVN_TEX_SLOTS, 1, 0, 1, NULL));
    CHECK(!nvn_apply_handles(table, NVN_TEX_SLOTS, 1, NVN_TEX_SLOTS, 0, NULL));
    CHECK(!memcmp(snapshot, table, sizeof table));
    CHECK(nvn_handle_range(5, 31, 1, NVN_COMBINED_TEX_SLOTS));
    CHECK(!nvn_handle_range(5, 32, 1, NVN_COMBINED_TEX_SLOTS));
    CHECK(!nvn_handle_range(0, 127, 2, NVN_SEPARATE_TEX_SLOTS));
    uint8_t driver[0xa00], saved[0xa00]; memset(driver, 0xa5, sizeof driver); memcpy(saved, driver, sizeof driver);
    CHECK(!nvn_fill_texture_driver(driver, 0x967, table[1], samplers));
    CHECK(!memcmp(driver, saved, sizeof driver));
    memset(driver, 0, sizeof driver); samplers[0] = UINT64_C(7) << 20;
    CHECK(nvn_fill_texture_driver(driver, sizeof driver, table[1], samplers));
    uint64_t got; memcpy(&got, driver + 0x20, 8); CHECK(got == combined);
    memcpy(&got, driver + 0x168, 8); CHECK(got == separate);
    memcpy(&got, driver + 0x568, 8); CHECK(got == samplers[0]);
    for (int i = 0x120; i < 0x168; i++) CHECK(driver[i] == 0);
    uint64_t zero = 0;
    CHECK(nvn_apply_handles(table, NVN_TEX_SLOTS, 1, NVN_COMBINED_TEX_FIRST, 1, &zero));
    CHECK(table[1][0] == separate && !table[1][NVN_COMBINED_TEX_FIRST]);
    uint64_t images[NVN_IMAGE_SLOTS] = {0}; images[31] = 91;
    nvn_rbind binding = {.kind = NVN_RB_TEX, .reg = 0};
    CHECK(nvn_rbind_handle(&binding, table[1], samplers, images) == separate);
    table[1][159] = combined;
    for (unsigned kind = 0; kind <= NVN_RB_UBOP; kind++) {
        binding.kind = kind; binding.reg = 159;
        uint64_t expected = kind == NVN_RB_TEX || kind == NVN_RB_TBUF || kind == NVN_RB_SAMPT ? combined : 0;
        CHECK(nvn_rbind_handle(&binding, table[1], samplers, images) == expected);
        binding.reg = UINT16_MAX;
        CHECK(!nvn_rbind_handle(&binding, table[1], samplers, images));
    }
    binding.kind = NVN_RB_IMG; binding.reg = 31;
    CHECK(nvn_rbind_handle(&binding, table[1], samplers, images) == 91);
    binding.reg = 32; CHECK(!nvn_rbind_handle(&binding, table[1], samplers, images));
    binding.kind = NVN_RB_SAMP; binding.reg = 0;
    CHECK(nvn_rbind_handle(&binding, table[1], samplers, images) == samplers[0]);
    CHECK(!nvn_rbind_handle(&binding, table[1], NULL, images));
    CHECK(!nvn_rbind_handle(NULL, table[1], samplers, images));
    uint64_t mixed[2] = {1, UINT64_C(1) << 63};
    CHECK(nvn_fetch_slot_blocked(mixed, 0) && nvn_fetch_slot_blocked(mixed, 127));
    CHECK(!nvn_fetch_slot_blocked(mixed, 63) && !nvn_fetch_slot_blocked(mixed, 64));
    for (unsigned reg = 128; reg < NVN_TEX_SLOTS; reg++) CHECK(nvn_fetch_slot_blocked(mixed, reg));
    CHECK(nvn_fetch_slot_blocked(mixed, UINT_MAX) && nvn_fetch_slot_blocked(NULL, 0));
    puts("NVN HANDLES OK: combined/separate isolation, stages, invalid ranges, driver bytes, unbind");
    return 0;
}
