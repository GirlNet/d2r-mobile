#include "../nvn/nvn_fragment_bits.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char source[]="struct O { float4 a [[color(0)]]; float2 b [[color(3)]]; float z [[depth(any)]]; uint mask [[sample_mask]]; };\n"
 "fragment O main0(uint n [[sample_id]]) { O out={}; if(n) { return out; } /* return bogus; } */ return out; }\n"
 "float helper(){return 1;}";
int main(int argc,char **argv) {
    uint8_t kinds[8]={0};char *output=NULL,error[160];uint16_t mask;
    assert(!nvn_fragment_bits_source(source,kinds,&output,&mask,error,sizeof error));assert(!mask&&!strcmp(output,source));free(output);
    kinds[0]=1;kinds[3]=2;assert(!nvn_fragment_bits_source(source,kinds,&output,&mask,error,sizeof error));assert(mask==129);
    assert(strstr(output,"uint4 a [[color(0)]]"));assert(strstr(output,"int2 b [[color(3)]]"));
    assert(strstr(output,"converted.a = as_type<uint4>(value.a)"));assert(strstr(output,"converted.b = as_type<int2>(value.b)"));
    assert(strstr(output,"converted.z = value.z"));assert(strstr(output,"converted.mask = value.mask"));
    assert(strstr(output,"if(n) { return dm_fragment_bits(out); } /* return bogus; } */ return dm_fragment_bits(out);"));
    assert(strstr(output,"float helper(){return 1;}"));char *again=NULL;
    assert(nvn_fragment_bits_source(output,kinds,&again,&mask,error,sizeof error));assert(!again);free(output);
    assert(!nvn_fragment_bits_source("fragment void main0(){}",kinds,&output,&mask,error,sizeof error));assert(!mask);free(output);
    const char *bad[]={"struct O {float4 x [[color(8)]];}; fragment O f(){O o;return o;}",
      "struct O {float4 x [[color(0)]];float4 y [[color(0)]];}; fragment O f(){O o;return o;}",
      "struct O {uint4 x [[color(0)]];}; fragment O f(){O o;return o;}",
      "struct O {float4 x [[color(0)]];}; fragment O f(){return O();}",
      "struct O {float4 x [[color(0)]];}; fragment O f(){O o;return o; /*",
      "struct O {float4 x [[color(0)]];}; fragment O f(){O o;return o;"};
    for(unsigned i=0;i<sizeof bad/sizeof *bad;i++){assert(nvn_fragment_bits_source(bad[i],kinds,&output,&mask,error,sizeof error));assert(!output);}
    kinds[0]=3;assert(nvn_fragment_bits_source(source,kinds,&output,&mask,error,sizeof error));kinds[0]=1;
    for(int i=1;i<argc;i++) {
        FILE *file=fopen(argv[i],"rb");assert(file);fseek(file,0,SEEK_END);long n=ftell(file);assert(n>=0);rewind(file);
        char *data=malloc((size_t)n+1);assert(data&&fread(data,1,n,file)==(size_t)n);fclose(file);data[n]=0;
        for(unsigned slot=0;slot<8;slot++)kinds[slot]=slot%2+1;
        if(nvn_fragment_bits_source(data,kinds,&output,&mask,error,sizeof error)){fprintf(stderr,"Unsupported output %s: %s\n",argv[i],error);return 1;}
        free(output);free(data);
    }
    printf("FRAGMENT BITS OK: mixed export classes, multiple returns, depth/mask, strict grammar; %d local sources checked\n",argc-1);return 0;
}
