// 回放程序组合的有界缓存：按六阶段来源、初始化序号及宿主登记代号精确失效。
// Bounded replay composition cache, invalidated by all six sources, initialization serials and the host registry generation.
#pragma once
#include <stdint.h>
#include <string.h>

enum { NVN_PROGRAM_CACHE_SIZE = 16 };
typedef struct {
    uintptr_t source[6];
    uint64_t serial[6], generation;
} nvn_program_cache_key;
typedef struct {
    nvn_program_cache_key key;
    // 仅借用结果指针；调用方的组合字典负责持有对象。
    // Borrow the result pointer; the caller's composition dictionary owns the object.
    const void *value;
} nvn_program_cache_entry;
typedef struct { nvn_program_cache_entry entries[NVN_PROGRAM_CACHE_SIZE]; } nvn_program_cache;

static inline int nvn_program_cacheable(const nvn_program_cache_key *key) {
    // 没有初始化序号的程序仍逐次解析，不假定其控制段保持不变。
    // Keep resolving programs without initialization serials; their control data is not assumed immutable.
    for (unsigned i=0;i<6;i++) if (key->source[i] && !key->serial[i]) return 0;
    return 1;
}
static inline unsigned nvn_program_cache_slot(const nvn_program_cache_key *key) {
    uint64_t hash=14695981039346656037ull;
    for (unsigned i=0;i<6;i++) hash=(hash^(key->source[i]>>3)^key->serial[i])*1099511628211ull;
    return (unsigned)hash&(NVN_PROGRAM_CACHE_SIZE-1);
}
static inline const void *nvn_program_cache_find(const nvn_program_cache *cache,const nvn_program_cache_key *key) {
    if (!nvn_program_cacheable(key)) return NULL;
    const nvn_program_cache_entry *entry=&cache->entries[nvn_program_cache_slot(key)];
    return entry->key.generation==key->generation &&
        !memcmp(entry->key.source,key->source,sizeof key->source) &&
        !memcmp(entry->key.serial,key->serial,sizeof key->serial) ? entry->value : NULL;
}
static inline void nvn_program_cache_put(nvn_program_cache *cache,const nvn_program_cache_key *key,const void *value) {
    if (value && nvn_program_cacheable(key))
        cache->entries[nvn_program_cache_slot(key)]=(nvn_program_cache_entry){.key=*key,.value=value};
}
