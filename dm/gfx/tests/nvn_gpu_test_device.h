#pragma once
// Distinguish missing devices/backends from executed output comparisons.
static int nvn_gpu_test_device(void) {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device)return 77;
#if !DM_NVN_M3
    if(![device supportsFamily:MTLGPUFamilyMetal4])return 78;
#endif
    return 0;
}
