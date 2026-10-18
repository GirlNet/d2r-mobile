// 着色器反射 json（B：Switch 原版翻译，tools/dmsh_build.py 出）→ 定长 C 数组（nvn_refl.h）
// Shader reflection json (B: produced by translating the original Switch shaders, output of tools/dmsh_build.py) → fixed-length C arrays (nvn_refl.h)
#import "nvn_refl.h"
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include "nvn_shader_control.h"

// 哑贴图类型：与原 dummy_tex 同一套前缀判定（未绑贴图槽按 D3D 语义读出 0）
// Dummy texture type: same prefix rules as the original dummy_tex (an unbound texture slot reads 0 per D3D semantics)
static void dummy_kind(NSString *t, uint8_t *tt, uint8_t *pf) {
    MTLTextureType y = MTLTextureType2D;
    if ([t hasPrefix:@"texture2d_array"] || [t hasPrefix:@"depth2d_array"]) y = MTLTextureType2DArray;
    else if ([t hasPrefix:@"texturecube_array"] || [t hasPrefix:@"depthcube_array"]) y = MTLTextureTypeCubeArray;
    else if ([t hasPrefix:@"texturecube"] || [t hasPrefix:@"depthcube"]) y = MTLTextureTypeCube;
    else if ([t hasPrefix:@"texture3d"]) y = MTLTextureType3D;
    else if ([t hasPrefix:@"texture1d_array"]) y = MTLTextureType1DArray;
    else if ([t hasPrefix:@"texture1d"]) y = MTLTextureType1D;
    *tt = (uint8_t)y;
    *pf = [t hasPrefix:@"depth"] ? NVN_DPF_DEPTH : [t containsString:@"<uint"] ? NVN_DPF_UINT : [t containsString:@"<int"] ? NVN_DPF_SINT : NVN_DPF_FLOAT;
}

static int parse_reflection(NSDictionary *j, nvn_refl *o, char *err, int errlen, int allow_candidate) {
    memset(o, 0, sizeof *o);
    #define FAIL(...) do { snprintf(err, errlen, __VA_ARGS__); return 1; } while (0)
    if (![j[@"route"] isEqual:@"B"]) FAIL("不是 B 反射（route ≠ B；A 路线 / PC 链反射已退役）");
    BOOL candidate = allow_candidate && [j[@"execution_mode"] isEqual:@"guarded_candidate"] &&
        [j[@"profile"] isEqual:@"p5r"];
    if (candidate) {
        NSDictionary *expected=@{@"version":@1,@"pipeline":@"p5r_nvn11",@"resources":@"per_binding",@"coordinates":@"normalized",@"storage":@"exact_gpu_pointer"};
        if (![j[@"runtime_contract"] isEqual:expected] || ![j[@"diagnostic_only"] isEqual:@NO] ||
            ![j[@"resource_facts_verified"] isEqual:@NO] || ![j[@"runtime_ready"] isEqual:@NO] ||
            ![j[@"binding_coverage_complete"] isEqual:@YES] ||
            ![j[@"missing_descriptors"] isKindOfClass:NSArray.class] || [j[@"missing_descriptors"] count] ||
            ![j[@"drv_reads"] isKindOfClass:NSDictionary.class] || [j[@"drv_reads"] count])
            FAIL("Invalid guarded P5R execution contract");
        if ([j[@"stage"] isEqual:@"cs"] && ![j[@"compute_memory_audit"][@"memory_unused_proven"] isEqual:@YES])
            FAIL("Guarded compute requires unused local/shared memory evidence");
        o->guarded_candidate=1;
    }
    // 诊断草案具有相似绑定字段，但未经验证；保留无这些标记的旧版 D2R 反射兼容性。
    // Diagnostic plans have similar binding fields but are unverified; retain compatibility with legacy D2R reflections lacking these markers.
    if (!candidate && ((j[@"diagnostic_only"] && ![j[@"diagnostic_only"] isEqual:@NO]) ||
        (j[@"resource_facts_verified"] && ![j[@"resource_facts_verified"] isEqual:@YES]) ||
        (j[@"runtime_ready"] && ![j[@"runtime_ready"] isEqual:@YES]))) FAIL("Diagnostic or unverified reflection is not loadable");
    if (!candidate && [j[@"profile"] isEqual:@"p5r"] &&
        (![j[@"diagnostic_only"] isEqual:@NO] || ![j[@"resource_facts_verified"] isEqual:@YES] ||
         ![j[@"runtime_ready"] isEqual:@YES])) FAIL("Missing verified P5R reflection markers");
    {   // Switch 原版翻译：种类与 NVN 槽号已由 dmsh_build.py 从 MSL 成员名解出 | Translated original Switch shaders: kind and NVN slot number are already parsed from the MSL member names by dmsh_build.py
        NSArray *bs = j[@"bindings"];
        if (![bs isKindOfClass:[NSArray class]]) FAIL("缺 bindings");
        if (bs.count > NVN_REFL_MAXB) FAIL("绑定 %lu 个，超上限 %d", (unsigned long)bs.count, NVN_REFL_MAXB);
        o->route_b = 1; o->abi = 0;   // spirv-cross 第 0 组 → [[buffer(0)]] | spirv-cross set 0 → [[buffer(0)]]
        uint64_t argument_ids=0;
        for (NSDictionary *b in bs) {
            NSString *k = b[@"kind"]; nvn_rbind *r = &o->b[o->nb];
            id rg = b[@"reg"]; int reg = [rg isKindOfClass:[NSNumber class]] ? [rg intValue] : -1, aid = [b[@"arg_id"] intValue];
            if (candidate) {
                NSSet *allowed=[NSSet setWithArray:@[@"support",@"c1",@"cbuf",@"sbuf",@"ubo_ptr",@"tex",@"tex_combined",@"samp",@"samp_tex",@"samp_combined"]];
                if (![allowed containsObject:k] || ![b[@"slot_mapping_verified"] isEqual:@YES] ||
                    ![b[@"arg_id"] isKindOfClass:NSNumber.class] || [b[@"arg_id"] doubleValue]!=(double)aid || aid<0 || aid>=NVN_REFL_MAXB ||
                    (argument_ids & (UINT64_C(1)<<aid))) FAIL("Invalid guarded binding/index");
                argument_ids |= UINT64_C(1)<<aid;
                if (([k isEqual:@"tex"] || [k isEqual:@"tex_combined"]) &&
                    ![b[@"msl_type"] isEqual:@"texture2d<float>"] && ![b[@"msl_type"] isEqual:@"texturecube<float>"])
                    FAIL("Unsupported guarded texture declaration");
                if (reg>=0 && (([k isEqual:@"cbuf"] || [k isEqual:@"sbuf"] || [k isEqual:@"ubo_ptr"]) ? reg>=16 :
                    ([k isEqual:@"tex"] || [k isEqual:@"samp"] || [k isEqual:@"samp_tex"]) ? reg>=128 : 0))
                    FAIL("Guarded resource register out of range");
            }
            r->aid = (uint16_t)aid; r->reg = reg < 0 ? 0 : (uint16_t)reg;
            if ([k isEqualToString:@"tex_combined"] || [k isEqualToString:@"samp_combined"] || [k isEqualToString:@"tbuf_combined"]) {
                if (reg < 0 || reg >= NVN_COMBINED_TEX_SLOTS) FAIL("Invalid combined texture slot");
                r->reg = (uint16_t)(NVN_COMBINED_TEX_FIRST + reg);
                if ([k isEqualToString:@"samp_combined"]) r->kind = NVN_RB_SAMPT;
                else { r->kind = [k isEqualToString:@"tbuf_combined"] ? NVN_RB_TBUF : NVN_RB_TEX; dummy_kind(b[@"msl_type"], &r->dtt, &r->dpf); }
            }
            else if ([k isEqualToString:@"cbuf"]) r->kind = NVN_RB_CBUF;
            else if ([k isEqualToString:@"samp"]) r->kind = NVN_RB_SAMP;
            else if ([k isEqualToString:@"samp_tex"]) r->kind = NVN_RB_SAMPT;
            else if ([k isEqualToString:@"tex"]) { r->kind = NVN_RB_TEX; dummy_kind(b[@"msl_type"], &r->dtt, &r->dpf); }
            else if ([k isEqualToString:@"img"]) { r->kind = NVN_RB_IMG; dummy_kind(b[@"msl_type"], &r->dtt, &r->dpf); }
            else if ([k isEqualToString:@"tbuf"]) { r->kind = NVN_RB_TBUF; uint8_t tt; dummy_kind(b[@"msl_type"], &tt, &r->dpf); }
            else if ([k isEqualToString:@"sbuf"]) { r->kind = NVN_RB_SBUFP; r->rw = [b[@"rw"] boolValue]; }
            else if ([k isEqualToString:@"ubo_ptr"]) r->kind = NVN_RB_UBOP;
            else if ([k isEqualToString:@"support"]) r->kind = NVN_RB_SUPPORT;
            else if ([k isEqualToString:@"c1"]) r->kind = NVN_RB_C1;
            else if ([k isEqualToString:@"drvcb"]) r->kind = [b[@"bank"] intValue] == 2 ? NVN_RB_DRV2 : NVN_RB_DRV0;
            else FAIL("B 绑定种类 %s 未实现（%s）", k.UTF8String, [b[@"msl_name"] UTF8String]);
            if (aid < 0 || aid >= NVN_REFL_MAXB) FAIL("Invalid argument buffer index");
            if ((r->kind == NVN_RB_CBUF || r->kind == NVN_RB_SAMP || r->kind == NVN_RB_SAMPT || r->kind == NVN_RB_TEX || r->kind == NVN_RB_IMG || r->kind == NVN_RB_TBUF || r->kind == NVN_RB_SBUFP || r->kind == NVN_RB_UBOP) && reg < 0)
                FAIL("B 绑定 %s 没解出槽号", [b[@"msl_name"] UTF8String]);
            o->nb++;
        }
        NSDictionary *dr = j[@"drv_reads"];
        if ([dr isKindOfClass:[NSDictionary class]]) { o->drv_read[0] = dr[@"0"] != nil; o->drv_read[2] = dr[@"2"] != nil; }
        NSArray *uf = j[@"drv_unfillable"];
        if ([uf isKindOfClass:[NSArray class]] && uf.count) FAIL("运行时读驱动段的回放层填不了的位置：%s", [[uf componentsJoinedByString:@" "] UTF8String]);
        NSString *c1 = j[@"c1"];
        if (c1.length % 2 || c1.length / 2 > sizeof o->c1) FAIL("c1 长 %lu 字节，超上限或不成对", (unsigned long)c1.length / 2);
        if (c1.length) { o->has_c1 = 1; o->c1_len = (uint16_t)(c1.length / 2); for (unsigned i = 0; i < o->c1_len; i++) o->c1[i] = (uint8_t)strtoul([[c1 substringWithRange:NSMakeRange(2 * i, 2)] UTF8String], NULL, 16); }
        for (NSDictionary *v in j[@"vertex_inputs"]) {   // [[attribute(n)]]：n 即 NVN 顶点属性号 | [[attribute(n)]]: n is the NVN vertex attribute number
            int loc = [v[@"location"] intValue]; NSString *t = v[@"msl_type"];
            if (loc < 0 || loc >= NVN_REFL_MAXV || o->nv >= NVN_REFL_MAXV) FAIL("B 顶点输入 %d 越界", loc);
            o->v[o->nv].loc = o->v[o->nv].nvn = (uint8_t)loc;
            o->v[o->nv].ct = [t hasPrefix:@"uint"] ? NVN_CT_UINT : [t hasPrefix:@"int"] ? NVN_CT_INT : NVN_CT_FLOAT;
            o->nv++;
        }
        NSDictionary *ra = j[@"raster"];
        o->pos_attr = -1; o->may_discard = 1; o->writes_smask = 1;
        if ([ra isKindOfClass:[NSDictionary class]]) {
            if (ra[@"pos_attr"]) { int pa = [ra[@"pos_attr"] intValue]; o->pos_attr = (int8_t)(pa >= 0 && pa < 16 ? pa : -1); o->pos_w1 = [ra[@"pos_w"] isEqual:@"one"]; }
            if (ra[@"discard"]) o->may_discard = [ra[@"discard"] intValue] != 0;
            if (ra[@"sample_mask"]) o->writes_smask = [ra[@"sample_mask"] intValue] != 0;
            for (NSNumber *c in ra[@"colors"]) if (c.intValue >= 0 && c.intValue < 8) o->color_mask |= (uint8_t)(1u << c.intValue);
        }
        memset(o->uv_attr, -1, sizeof o->uv_attr); memset(o->uv_aff_attr, -1, sizeof o->uv_aff_attr);
        NSDictionary *ua = [ra isKindOfClass:[NSDictionary class]] ? ra[@"uv_affine"] : nil;
        if ([ua isKindOfClass:[NSDictionary class]]) for (NSString *k in ua) { int l = k.intValue; NSDictionary *e = ua[k]; int a = [e[@"attr"] intValue];
            if (l < 0 || l >= 32 || a < 0 || a >= 16) continue;
            NSArray *refs[4] = {e[@"sx"], e[@"ox"], e[@"sy"], e[@"oy"]}; int ok = 1;
            for (int q = 0; q < 4; q++) { NSArray *r = refs[q]; if (![r isKindOfClass:[NSArray class]] || r.count != 3) { ok = 0; break; }
                int sl = [r[0] intValue], vec = [r[1] intValue], cmp = [r[2] intValue]; if (sl < 0 || sl > 15 || vec < 0 || vec > 63 || cmp < 0 || cmp > 3) { ok = 0; break; }
                o->uv_aff[l][q] = (uint16_t)(sl << 8 | vec << 2 | cmp); }
            if (ok) o->uv_aff_attr[l] = (int8_t)a; }
        NSDictionary *uv = [ra isKindOfClass:[NSDictionary class]] ? ra[@"uv_from_attr"] : nil;
        if ([uv isKindOfClass:[NSDictionary class]]) for (NSString *k in uv) { int l = k.intValue, a = [uv[k] intValue]; if (l >= 0 && l < 32 && a >= 0 && a < 16) o->uv_attr[l] = (int8_t)a; }
        NSDictionary *fe = j[@"fetch"];
        if ([fe isKindOfClass:[NSDictionary class]]) {
            for (NSDictionary *c in fe[@"calls"]) { int i = [c[@"fc"] intValue], r = [c[@"tex_reg"] intValue], l = [c[@"varying_locn"] intValue];
                if (i != o->nfc || i >= 32 || r < 0 || r >= 128 || l < 0 || l >= 32) FAIL("fetch 调用表不连续或越界（第 %d 条）", i);
                o->fc_reg[o->nfc] = (uint8_t)r; o->fc_locn[o->nfc] = (uint8_t)l; o->nfc++; }
            for (NSNumber *r in fe[@"mixed_regs"]) if (r.intValue >= 0 && r.intValue < 128) o->fc_mixed[r.intValue >> 6] |= 1ull << (r.intValue & 63);
            for (NSDictionary *u in fe[@"outputs"]) { if (o->nfo >= 4) FAIL("fetch 输出超过 4 个"); o->fo_color[o->nfo++] = (uint8_t)[u[@"color"] intValue]; }
        }
        NSArray *tg = j[@"threadgroup_size"];
        if ([j[@"stage"] isEqual:@"cs"]) {
            if (![tg isKindOfClass:[NSArray class]] || tg.count != 3) FAIL("Missing compute workgroup");
            uint32_t group[3];
            for (int i = 0; i < 3; i++) {
                if (![tg[i] isKindOfClass:[NSNumber class]] || [tg[i] doubleValue] != (double)[tg[i] unsignedIntValue]) FAIL("Invalid compute workgroup field");
                group[i] = [tg[i] unsignedIntValue];
            }
            if (!nvn_compute_group_valid(group)) FAIL("Invalid or unsupported compute workgroup");
            for (int i = 0; i < 3; i++) o->tg[i] = (uint16_t)group[i];
        } else if ([tg isKindOfClass:[NSArray class]] && tg.count == 3) for (int i = 0; i < 3; i++) o->tg[i] = (uint16_t)[tg[i] intValue];
        return 0;
    }
    #undef FAIL
}

int nvn_refl_from_json(NSDictionary *j,nvn_refl *o,char *err,int errlen) {
    return parse_reflection(j,o,err,errlen,0);
}
int nvn_refl_from_json_candidate(NSDictionary *j,nvn_refl *o,char *err,int errlen) {
    return parse_reflection(j,o,err,errlen,1);
}
