// 合成贴图自检返回值；不运行游戏，不修改运行时资源的就绪标记。
// Synthetic texture self-test results; never runs the game or modifies runtime resource readiness.
#pragma once
enum { NVN_TEXTURE_SELFTEST_NO_DEVICE = 77, NVN_TEXTURE_SELFTEST_METAL4_UNSUPPORTED = 78 };
// 0：两种 API 全部通过；1：失败；77：无设备；78：Metal 3 通过、Metal 4 不支持。
// 0: both APIs passed; 1: failed; 77: no device; 78: Metal 3 passed and Metal 4 unsupported.
int nvn_texture_selftest(void);
