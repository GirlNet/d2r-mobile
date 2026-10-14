// 合成头验证 P5R 控制段边界、未知版本拒绝和 D2R 原范围；不包含游戏内容。
// Synthetic headers test P5R control bounds, unknown-version rejection and D2R's original span; no game content.
#include "../../gfx/nvn/nvn_shader_control.h"
#include <stdio.h>
static void put(uint8_t *b, size_t o, uint32_t v) { for (unsigned i = 0; i < 4; i++) b[o+i] = (uint8_t)(v >> (8*i)); }
int main(void) {
    uint8_t b[0x25] = {0}, *p = b + 1;
    put(p, 0, 0x98761234); put(p, 4, 1); put(p, 8, 15); put(p, 12, 0x120);
    put(p, 16, 11); put(p, 20, 0x848); put(p, 32, 0x850);
    if (nvn_control_hash_size(p, 0x24, 1) != 0x850 || nvn_control_hash_size(p, 0, 0) != 0x880) return 1;
    for (size_t n = 0; n < 0x24; n++) if (nvn_control_hash_size(p, n, 1)) return 1;
    const size_t fields[] = {0, 4, 8, 12, 16, 20, 32};
    for (unsigned i = 0; i < sizeof fields / sizeof fields[0]; i++) {
        p[fields[i]] ^= 1;
        if (nvn_control_hash_size(p, 0x24, 1)) return 1;
        p[fields[i]] ^= 1;
    }
    if (nvn_control_hash_size(NULL, 0x24, 1) || nvn_control_hash_size(NULL, 0x24, 0)) return 1;
    puts("SHADER CONTROL OK: exact P5R span, unaligned header, bounds, unknown layout, D2R default");
    return 0;
}
