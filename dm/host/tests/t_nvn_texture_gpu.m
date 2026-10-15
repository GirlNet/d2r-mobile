// 无游戏内容的 GPU 自检命令行入口；与 iOS 壳复用同一实现。
// Game-free GPU self-test command-line entry; shares its implementation with the iOS shell.
#include "../../gfx/nvn/nvn_texture_selftest.h"
int main(void) { return nvn_texture_selftest(); }
