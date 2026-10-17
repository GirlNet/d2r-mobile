// Use Darwin's cache maintenance API instead of executing Horizon's CTR_EL0
// reads and DC/IC loops. The guest and Metal share host virtual addresses.
#include "hle.h"
#include "boot_probe.h"
#include <libkern/OSCacheControl.h>
#include <stdatomic.h>

// https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/sys_dcache_flush.3.html
// Darwin writes back and invalidates the range; do not replace this with a
// fence alone or issue the guest's cache-line instructions on Apple CPUs.
HLE_FORCE_OPTIONAL("_ZN2nn2os14FlushDataCacheEPKvm", "Horizon cache maintenance uses registers unavailable on Apple CPUs; forward to Darwin", void, h_cache_flush, const void *address, size_t size) {
    if (!size) return;
    sys_dcache_flush((void *)address, size);
    static _Atomic int noted;
    if (dm_boot_probe_active() && !atomic_exchange(&noted, 1)) {
        char detail[96];
        snprintf(detail, sizeof detail, "bytes=%zu; Darwin data-cache maintenance completed", size);
        dm_boot_probe_note("host_data_cache_flushed", detail);
    }
}

// Compiler runtime ABI: [begin,end), whereas Darwin takes (address,length).
// This is a separate instruction-cache operation, never a texture upload or
// proof that a guest-generated code page is executable under iOS signing.
HLE_FORCE_OPTIONAL("__clear_cache", "Compiler cache maintenance must use Darwin rather than guest CTR_EL0/DC/IC instructions", void, h_cache_clear, void *begin, void *end) {
    uintptr_t first = (uintptr_t)begin, last = (uintptr_t)end;
    if (last <= first) return;
    sys_icache_invalidate(begin, last - first);
}
