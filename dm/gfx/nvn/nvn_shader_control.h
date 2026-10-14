// 控制段哈希范围：D2R 保留原范围；P5R 只接受本地确认的 NVN 11 布局，不能把后续代码算入哈希。
// Control hash span: keep D2R's range; P5R accepts only the locally inspected NVN 11 layout and excludes the following code.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

static inline uint32_t nvn_control_word(const void *p, size_t offset) {
    const uint8_t *b = (const uint8_t *)p + offset;
    return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
}
static inline size_t nvn_control_hash_size(const void *p, size_t header_bytes, int p5r) {
    if (!p) return 0;
    if (!p5r) return 0x880;
    if (header_bytes < 0x24 || nvn_control_word(p, 0) != 0x98761234 ||
        nvn_control_word(p, 4) != 1 || nvn_control_word(p, 8) != 15 ||
        nvn_control_word(p, 12) != 0x120 || nvn_control_word(p, 16) != 11 ||
        nvn_control_word(p, 20) != 0x848 || nvn_control_word(p, 32) != 0x850) return 0;
    return 0x850;
}
