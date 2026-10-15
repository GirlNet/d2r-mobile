// 合成缓冲地址验证驱动表、计算 uniform 与 storage 隔离以及坏范围拒绝；不读取游戏文件。
// Synthetic buffer addresses test driver tables, compute uniform/storage isolation and invalid-range rejection without game files.
#include "../../gfx/nvn/nvn_buffer_bindings.h"
#include <stdio.h>

#define CHECK(e) do { if (!(e)) { fprintf(stderr, "NVN buffer check failed at %d\n", __LINE__); return 1; } } while (0)

int main(void) {
    uint8_t driver[0xa00], saved[0xa00];
    uint64_t address; uint32_t bytes, reserved;
    for (int stage = 0; stage < 6; stage++) for (int uniform = 0; uniform < 2; uniform++) {
        int base = uniform ? (stage == 5 ? 0x210 : -1) : stage == 0 ? 0x110 : stage == 1 ? 0x510 : stage == 5 ? 0x310 : -1;
        for (int slot = 0; slot < 16; slot++) {
            memset(driver, 0xa5, sizeof driver); memcpy(saved, driver, sizeof driver);
            int ok = nvn_write_buffer_driver(driver, sizeof driver, stage, uniform, slot, UINT64_C(0x1234567800) + slot * 256, 0x100 + slot);
            CHECK(ok == (base >= 0));
            if (base < 0) { CHECK(!memcmp(driver, saved, sizeof driver)); continue; }
            int offset = base + slot * 16;
            memcpy(&address, driver + offset, 8); memcpy(&bytes, driver + offset + 8, 4); memcpy(&reserved, driver + offset + 12, 4);
            CHECK(address == UINT64_C(0x1234567800) + slot * 256 && bytes == (uint32_t)(0x100 + slot) && !reserved);
            CHECK(!memcmp(driver, saved, offset) && !memcmp(driver + offset + 16, saved + offset + 16, sizeof driver - offset - 16));
            CHECK(nvn_write_buffer_driver(driver, sizeof driver, stage, uniform, slot, 0, 0));
            CHECK(!memcmp(driver + offset, (uint8_t[16]){0}, 16));
        }
    }
    memset(driver, 0xa5, sizeof driver); memcpy(saved, driver, sizeof driver);
    CHECK(!nvn_write_buffer_driver(driver, 0x31f, 5, 0, 0, 1, 2));
    CHECK(!nvn_write_buffer_driver(driver, 0, 5, 0, 0, 1, 2));
    CHECK(!nvn_write_buffer_driver(driver, sizeof driver, 5, 0, -1, 1, 2));
    CHECK(!nvn_write_buffer_driver(driver, sizeof driver, 5, 0, 16, 1, 2));
    CHECK(!nvn_write_buffer_driver(driver, sizeof driver, 6, 0, 0, 1, 2));
    CHECK(!nvn_write_buffer_driver(NULL, sizeof driver, 5, 0, 0, 1, 2));
    CHECK(!memcmp(driver, saved, sizeof driver));
    CHECK(nvn_write_buffer_driver(driver, sizeof driver, 5, 1, 0, 11, 22));
    CHECK(nvn_write_buffer_driver(driver, sizeof driver, 5, 0, 0, 33, 44));
    memcpy(&address, driver + 0x210, 8); CHECK(address == 11);
    memcpy(&address, driver + 0x310, 8); CHECK(address == 33);
    puts("NVN BUFFERS OK: stage tables, compute uniform/storage isolation, bounds and unbind");
    return 0;
}
