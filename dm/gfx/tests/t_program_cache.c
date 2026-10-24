// 使用合成程序身份验证生产组合缓存的重用与失效；不需要游戏数据或 GPU。
// Exercise production composition-cache reuse and invalidation with synthetic identities, without game data or a GPU.
#include "../nvn/nvn_program_cache.h"
#include <stdio.h>
#include <stdlib.h>

#define CHECK(x) do { if(!(x)) { fprintf(stderr,"program cache failed at %d\n",__LINE__);exit(1); } } while(0)
static int tokens[65536];
static unsigned objects[12];
static nvn_program_cache_key make_key(void) {
    nvn_program_cache_key key={.generation=1};
    key.source[0]=(uintptr_t)&objects[0];key.serial[0]=10;
    key.source[1]=(uintptr_t)&objects[1];key.serial[1]=11;
    return key;
}
static const void *reference(const unsigned bound[6],const unsigned shader[12]) {
    unsigned colour=0;
    for(unsigned stage=0;stage<6;stage++)colour=colour*31+(bound[stage]?shader[bound[stage]-1]:0);
    return &tokens[colour%65536];
}
int main(void) {
    nvn_program_cache cache={0};nvn_program_cache_key key=make_key();
    CHECK(!nvn_program_cache_find(&cache,&key));
    nvn_program_cache_put(&cache,&key,&tokens[1]);
    unsigned repeated_hits=0;
    for(unsigned i=0;i<100000;i++) {
        CHECK(nvn_program_cache_find(&cache,&key)==&tokens[1]);repeated_hits++;
    }
    for(unsigned stage=0;stage<6;stage++) {
        nvn_program_cache_key changed=key;
        changed.source[stage]=(uintptr_t)&objects[stage+2];changed.serial[stage]=100+stage;
        CHECK(!nvn_program_cache_find(&cache,&changed));
        changed=key;changed.serial[stage]++;
        CHECK(!nvn_program_cache_find(&cache,&changed));
    }
    nvn_program_cache_key changed=key;changed.generation++;
    CHECK(!nvn_program_cache_find(&cache,&changed));
    changed=key;changed.source[0]=changed.serial[0]=0;
    CHECK(!nvn_program_cache_find(&cache,&changed));
    changed=key;changed.serial[0]=0;
    nvn_program_cache_put(&cache,&changed,&tokens[2]);CHECK(!nvn_program_cache_find(&cache,&changed));
    CHECK(nvn_program_cache_find(&cache,&key)==&tokens[1]);
    // 人为制造槽碰撞，确认替换后不会返回旧组合。
    // Force a slot collision and ensure eviction never returns the previous composition.
    changed=key;
    do { changed.serial[1]++; } while(nvn_program_cache_slot(&changed)!=nvn_program_cache_slot(&key));
    CHECK(!nvn_program_cache_find(&cache,&changed));
    nvn_program_cache_put(&cache,&changed,&tokens[3]);
    CHECK(!nvn_program_cache_find(&cache,&key));CHECK(nvn_program_cache_find(&cache,&changed)==&tokens[3]);
    // 混合绘制、预判、解绑、同址重建和登记替换，并逐次与独立解析结果比较。
    // Mix draws, lookahead, unbinds, same-address reinitialization and registry replacement against an uncached reference.
    unsigned bound[6]={1,2,0,0,0,6},shader[12],serial[12];
    for(unsigned i=0;i<12;i++){shader[i]=i+1;serial[i]=i+10;}
    uint32_t random=0x12345678;unsigned hits=0,misses=0;
    uint64_t generation=5;unsigned next_serial=100;
    for(unsigned iteration=0;iteration<200000;iteration++) {
        random^=random<<13;random^=random>>17;random^=random<<5;
        unsigned stage=(random>>8)%6,index=(random>>16)%12;
        switch(random%16) {
            case 0:bound[stage]=index+1;break;
            case 1:bound[stage]=0;break;
            case 2:serial[index]=++next_serial;shader[index]++;break;
            case 3:generation++;shader[index]++;break;
            case 4:generation++;break;
            case 5:bound[stage]=index+1;serial[index]=0;shader[index]++;break;
            default:break;
        }
        key=(nvn_program_cache_key){.generation=generation};
        for(unsigned i=0;i<6;i++)if(bound[i]) {
            key.source[i]=(uintptr_t)&objects[bound[i]-1];key.serial[i]=serial[bound[i]-1];
        }
        const void *expected=reference(bound,shader),*actual=nvn_program_cache_find(&cache,&key);
        if(actual)hits++;
        else {misses++;actual=expected;nvn_program_cache_put(&cache,&key,actual);}
        CHECK(actual==expected);
    }
    CHECK(hits>0 && misses>0 && repeated_hits==100000);
    printf("PROGRAM CACHE OK: %u repeated hits; 200000 mixed resolutions (%u hits, %u misses), all stages, replacements, unbinds, zero serials and collisions\n",repeated_hits,hits,misses);
    return 0;
}
