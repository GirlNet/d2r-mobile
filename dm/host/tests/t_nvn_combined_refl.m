// 合成反射验证组合纹理/采样器落到独立状态槽，并拒绝越界参数；不读取游戏缓存。
// Synthetic reflection verifies independent combined texture/sampler state slots and rejects out-of-range arguments without reading game caches.
#import "../../gfx/nvn/nvn_refl.h"
#include <stdio.h>

#define CHECK(expression) do { if (!(expression)) { fprintf(stderr, "NVN reflection check failed at %d: %s\n", __LINE__, err); return 1; } } while (0)

static NSDictionary *binding(NSString *kind, int reg, int aid) {
    return @{@"kind":kind, @"reg":@(reg), @"arg_id":@(aid), @"msl_type":@"texture2d<float>", @"msl_name":@"synthetic"};
}

int main(void) { @autoreleasepool {
    nvn_refl reflection; char err[160] = "";
    for (NSDictionary *markers in @[@{@"diagnostic_only":@YES}, @{@"resource_facts_verified":@NO},
                                    @{@"runtime_ready":@NO}, @{@"profile":@"p5r"},
                                    @{@"diagnostic_only":@"false"}, @{@"resource_facts_verified":[NSNull null]}]) {
        NSMutableDictionary *plan = [@{@"route":@"B", @"bindings":@[]} mutableCopy];
        [plan addEntriesFromDictionary:markers];
        CHECK(nvn_refl_from_json(plan, &reflection, err, sizeof err));
        CHECK(reflection.nb == 0);
    }
    CHECK(!nvn_refl_from_json(@{@"route":@"B", @"bindings":@[], @"profile":@"p5r", @"diagnostic_only":@NO,
                               @"resource_facts_verified":@YES, @"runtime_ready":@YES}, &reflection, err, sizeof err));
    NSArray *bindings = @[binding(@"tex", 0, 0), binding(@"tex_combined", 0, 1),
                          binding(@"samp_combined", 0, 2), binding(@"tbuf_combined", 31, 3)];
    CHECK(!nvn_refl_from_json(@{@"route":@"B", @"bindings":bindings}, &reflection, err, sizeof err));
    CHECK(reflection.nb == 4 && reflection.b[0].reg == 0);
    CHECK(reflection.b[1].reg == NVN_COMBINED_TEX_FIRST && reflection.b[1].kind == NVN_RB_TEX);
    CHECK(reflection.b[2].reg == NVN_COMBINED_TEX_FIRST && reflection.b[2].kind == NVN_RB_SAMPT);
    CHECK(reflection.b[3].reg == NVN_TEX_SLOTS - 1 && reflection.b[3].kind == NVN_RB_TBUF);
    for (NSString *kind in @[@"tex_combined", @"samp_combined", @"tbuf_combined"])
        for (NSNumber *reg in @[@(-1), @32, @128])
            CHECK(nvn_refl_from_json(@{@"route":@"B", @"bindings":@[binding(kind, reg.intValue, 0)]}, &reflection, err, sizeof err));
    for (NSNumber *aid in @[@(-1), @(NVN_REFL_MAXB)])
        CHECK(nvn_refl_from_json(@{@"route":@"B", @"bindings":@[binding(@"tex_combined", 0, aid.intValue)]}, &reflection, err, sizeof err));
    CHECK(!nvn_refl_from_json(@{@"route":@"B", @"stage":@"cs", @"bindings":@[], @"threadgroup_size":@[@32,@2,@1]}, &reflection, err, sizeof err));
    CHECK(reflection.tg[0] == 32 && reflection.tg[1] == 2 && reflection.tg[2] == 1);
    for (id group in @[[NSNull null], @[], @[@0,@1,@1], @[@1,@0,@1], @[@1,@1,@0], @[@65536,@1,@1], @[@1024,@2,@1], @[@(-1),@1,@1], @[@1.5,@1,@1], @[@"32",@1,@1]])
        CHECK(nvn_refl_from_json(@{@"route":@"B", @"stage":@"cs", @"bindings":@[], @"threadgroup_size":group}, &reflection, err, sizeof err));
    CHECK(nvn_refl_from_json(@{@"route":@"B", @"stage":@"cs", @"bindings":@[]}, &reflection, err, sizeof err));
    NSMutableDictionary *candidate=[@{@"route":@"B",@"profile":@"p5r",@"stage":@"vs",@"bindings":@[],
        @"diagnostic_only":@NO,@"resource_facts_verified":@NO,@"runtime_ready":@NO,
        @"binding_coverage_complete":@YES,@"missing_descriptors":@[],@"drv_reads":@{},
        @"execution_mode":@"guarded_candidate",@"runtime_contract":@{@"version":@1,@"pipeline":@"p5r_nvn11",
        @"resources":@"per_binding",@"coordinates":@"normalized",@"storage":@"exact_gpu_pointer"}} mutableCopy];
    CHECK(nvn_refl_from_json(candidate,&reflection,err,sizeof err));
    CHECK(!nvn_refl_from_json_candidate(candidate,&reflection,err,sizeof err));CHECK(reflection.guarded_candidate);
    candidate[@"runtime_ready"]=@YES;CHECK(nvn_refl_from_json_candidate(candidate,&reflection,err,sizeof err));candidate[@"runtime_ready"]=@NO;
    candidate[@"runtime_contract"]=@{@"version":@1};CHECK(nvn_refl_from_json_candidate(candidate,&reflection,err,sizeof err));
    puts("NVN COMBINED REFLECTION OK: independent slots, sampler source, upper bound, invalid arguments");
    return 0;
} }
