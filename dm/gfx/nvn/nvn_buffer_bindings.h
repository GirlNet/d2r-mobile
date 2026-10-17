// NVN 驱动缓冲地址表：依据原版 SDK 图形绑定命令及计算队列绑定处理；阶段号使用回放层编号。
// NVN driver buffer address tables: based on original SDK graphics binding commands and compute queue binding handlers; stage numbers use replay-layer numbering.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

static inline int nvn_buffer_driver_offset(int stage, int uniform, int index) {
    if (index < 0 || index >= 16) return -1;
    int base = uniform ? (stage == 5 ? 0x210 : -1) :
        stage == 0 ? 0x110 : stage == 1 ? 0x510 : stage == 5 ? 0x310 : -1;
    return base < 0 ? -1 : base + index * 16;
}

static inline int nvn_write_buffer_driver(void *destination, size_t size, int stage, int uniform,
                                           int index, uint64_t address, uint32_t bytes) {
    int offset = nvn_buffer_driver_offset(stage, uniform, index);
    if (!destination || offset < 0 || (size_t)offset > size || size - (size_t)offset < 16) return 0;
    uint8_t *entry = (uint8_t *)destination + offset;
    memset(entry, 0, 16);
    memcpy(entry, &address, 8); memcpy(entry + 8, &bytes, 4);
    return 1;
}
