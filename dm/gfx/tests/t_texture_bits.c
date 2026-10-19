#include "../nvn/nvn_texture_bits.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"texture bits check failed at %d\n",__LINE__);return 1;}}while(0)
int main(void) {
    uint8_t kinds[64]={0};char *out=NULL,error[160];uint64_t applied=0;unsigned cases=0;
    const char *source="struct Args{texture2d<float> stencil [[id(7)]];texture2d<float> color [[id(8)]];};\n"
      "// args.stencil.sample(x) is a comment\n"
      "float4 f(constant Args &a){int w=a.stencil.get_width();int h=a.stencil.get_height(0);"
      "return a.stencil.read(uint2(w-1,h-1),0)+a.color.read(uint2(0));}\n";
    CHECK(!nvn_texture_bits_source(source,kinds,&out,&applied,error,sizeof error));CHECK(!strcmp(source,out)&&!applied);free(out);
    for(unsigned kind=1;kind<=2;kind++) {
        kinds[7]=kind;CHECK(!nvn_texture_bits_source(source,kinds,&out,&applied,error,sizeof error));
        CHECK(applied==(UINT64_C(1)<<7));CHECK(strstr(out,kind==1?"texture2d<uint> stencil":"texture2d<int> stencil"));
        CHECK(strstr(out,"as_type<float4>(a.stencil.read(uint2(w-1,h-1),0))"));
        CHECK(strstr(out,"texture2d<float> color")&&strstr(out,"a.color.read(uint2(0))"));
        CHECK(strstr(out,"a.stencil.get_width()")&&strstr(out,"// args.stencil.sample(x)"));free(out);cases++;
    }
    for(unsigned aid=0;aid<64;aid++) {
        char text[512];snprintf(text,sizeof text,"struct Args{texture2d_array<float> t[[id(%u)]];};float4 f(constant Args&a){return a.t.read(uint2(0),0,0);}",aid);
        memset(kinds,0,sizeof kinds);kinds[aid]=1;
        CHECK(!nvn_texture_bits_source(text,kinds,&out,&applied,error,sizeof error));CHECK(applied==(UINT64_C(1)<<aid));
        CHECK(strstr(out,"texture2d_array<uint> t")&&strstr(out,"as_type<float4>(a.t.read(uint2(0),0,0))"));free(out);cases++;
    }
    const char *bad[]={
      "struct A{texture2d<float> t[[id(0)]];};float4 f(constant A&a){return a.t.sample(s,float2(0));}",
      "struct A{texture2d<float> t[[id(0)]];};void f(constant A&a){other(a.t);}",
      "struct A{texture2d<float> t[[id(0)]];texture2d<float> u[[id(0)]];};",
      "struct A{texture2d<float> t[[id(1)]];};",
      "struct A{texture2d<uint> t[[id(0)]];};",
      "struct A{texture2d<float> t[[id(0)]];};void f(){t.read(uint2(0));}",
      "struct A{texture2d<float> t[[id(0)]];};void f(constant A&a){a.t.read(uint2(0);}",
      "struct A{texture2d<float> t[[id(0)]];}; /* unclosed",
      "struct A{texture2d<float> t[[id(0)]];};\"unclosed",
      "struct A{texture2d<float> t[[id(0)]];};void f(constant A&a){nested.a.t.read(uint2(0));}"
    };
    memset(kinds,0,sizeof kinds);kinds[0]=1;
    for(unsigned i=0;i<sizeof bad/sizeof *bad;i++) {
        applied=UINT64_MAX;out=(char *)1;CHECK(nvn_texture_bits_source(bad[i],kinds,&out,&applied,error,sizeof error));
        CHECK(!out&&!applied&&error[0]);cases++;
    }
    const char *nested="struct A{texture2d<float> t[[id(0)]];texture2d<float> u[[id(1)]];};"
       "float4 f(constant A&a){return a.t.read(uint2(as_type<uint>(a.u.read(uint2(0)).x),0));}";
    kinds[1]=1;CHECK(!nvn_texture_bits_source(nested,kinds,&out,&applied,error,sizeof error));
    CHECK(strstr(out,"as_type<float4>(a.t.read(uint2(as_type<uint>(as_type<float4>(a.u.read(uint2(0))).x),0)))"));free(out);cases++;
    kinds[1]=3;CHECK(nvn_texture_bits_source(source,kinds,&out,&applied,error,sizeof error)&&!out);cases++;
    printf("TEXTURE BITS OK: %u load/query, argument ID, bit-preservation and rejection cases\n",cases);return 0;
}
