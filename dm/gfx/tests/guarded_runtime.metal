#include <metal_stdlib>
using namespace metal;
vertex float4 guarded_vertex(uint i [[vertex_id]]) {
    float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
    return float4(p[i],.5,1);
}
fragment float4 guarded_fragment() { return float4(.25,.5,.75,1); }
struct Args { device uint *output [[id(0)]]; };
kernel void guarded_compute(constant Args &a [[buffer(0)]]) { a.output[0]=0x1234abcd; }
