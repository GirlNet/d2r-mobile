// Exercise the production adapters, record the exact forwarded range and then
// call Darwin on real allocated memory. No guest programs or GPU work are needed.
#include <libkern/OSCacheControl.h>
static void test_dcache_flush(void *, size_t);
static void test_icache_invalidate(void *, size_t);
#define sys_dcache_flush test_dcache_flush
#define sys_icache_invalidate test_icache_invalidate
#include "../hle_cache.c"
#undef sys_dcache_flush
#undef sys_icache_invalidate
#include <assert.h>

static void *expected_address;
static size_t expected_size;
static unsigned data_calls, instruction_calls, notes;
static int probing;
int dm_boot_probe_active(void) { return probing; }
void dm_boot_probe_note(const char *event, const char *detail) {
    assert(!strcmp(event, "host_data_cache_flushed"));
    assert(strstr(detail, "Darwin data-cache maintenance completed"));
    notes++;
}
static void test_dcache_flush(void *address, size_t size) {
    assert(address == expected_address && size == expected_size);
    data_calls++;
    sys_dcache_flush(address, size);
}
static void test_icache_invalidate(void *address, size_t size) {
    assert(address == expected_address && size == expected_size);
    instruction_calls++;
    sys_icache_invalidate(address, size);
}
int main(void) {
    assert(!strcmp(hle_force_h_cache_flush.name, "_ZN2nn2os14FlushDataCacheEPKvm"));
    assert(hle_force_h_cache_flush.fn == (void *)h_cache_flush);
    assert(!strcmp(hle_force_h_cache_clear.name, "__clear_cache"));
    assert(hle_force_h_cache_clear.fn == (void *)h_cache_clear);
    enum { N = 32768 };
    unsigned char *bytes = malloc(N);
    assert(bytes);
    for (unsigned i = 0; i < N; i++) bytes[i] = (unsigned char)(i * 37);
    const size_t offsets[] = {0, 1, 31, 63, 127, 128, 4095, 16383};
    const size_t sizes[] = {1, 31, 64, 127, 128, 2048, 4097, 16384};
    for (unsigned p = 0; p < 2; p++) {
        probing = p;
        for (unsigned a = 0; a < sizeof offsets / sizeof *offsets; a++)
            for (unsigned n = 0; n < sizeof sizes / sizeof *sizes; n++) {
                expected_address = bytes + offsets[a]; expected_size = sizes[n];
                h_cache_flush(expected_address, expected_size);
                h_cache_clear(expected_address, (unsigned char *)expected_address + expected_size);
            }
    }
    assert(data_calls == 128 && instruction_calls == 128 && notes == 1);
    h_cache_flush(NULL, 0); h_cache_clear(NULL, NULL);
    h_cache_clear(bytes + 1, bytes);
    assert(data_calls == 128 && instruction_calls == 128 && notes == 1);
    for (unsigned i = 0; i < N; i++) assert(bytes[i] == (unsigned char)(i * 37));
    free(bytes);
    puts("CACHE ADAPTERS OK: 256 Darwin range calls, optional forced symbols, unaligned ranges, empty/reversed ranges, unchanged bytes, bounded probe note");
    return 0;
}
