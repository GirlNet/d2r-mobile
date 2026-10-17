#include "../nvn/nvn_vertex_bits.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char source[]="struct main0_in\n{\nfloat4 position [[attribute(0)]];\nfloat2 bone [[attribute(3)]];\n};\n"
    "struct output { float4 p [[position]]; };\nvertex output main0(constant uint *b [[buffer(0)]], main0_in in [[stage_in]], uint id [[vertex_id]])\n{\nreturn {in.position+float4(in.bone,0,0)};\n}\n";
int main(int argc,char **argv) {
    uint8_t kinds[16]={0};char *output=NULL,error[160];uint32_t mask;
    assert(!nvn_vertex_bits_source(source,kinds,&output,&mask,error,sizeof error));assert(!mask&&!strcmp(output,source));free(output);
    kinds[3]=1;assert(!nvn_vertex_bits_source(source,kinds,&output,&mask,error,sizeof error));assert(mask==(1u<<6));
    assert(strstr(output,"uint2 bone [[attribute(3)]]"));assert(strstr(output,"in.bone = as_type<float2>(dm_raw_vertex.bone)"));
    assert(strstr(output,"in.position = dm_raw_vertex.position"));assert(strstr(output,"return {in.position+float4(in.bone,0,0)};"));free(output);
    kinds[0]=2;assert(!nvn_vertex_bits_source(source,kinds,&output,&mask,error,sizeof error));assert(mask==66);
    assert(strstr(output,"int4 position [[attribute(0)]]"));assert(strstr(output,"in.position = as_type<float4>(dm_raw_vertex.position)"));
    char *again=NULL;assert(nvn_vertex_bits_source(output,kinds,&again,&mask,error,sizeof error));assert(!again);free(output);
    const char *bad[]={"struct In { float x [[attribute(16)]]; }; vertex float v(In i [[stage_in]]){return i.x;}",
      "struct In { float x [[attribute(0)]]; float y [[attribute(0)]]; }; vertex float v(In i [[stage_in]]){return i.x;}",
      "struct In { float x [[attribute(0)]]; float y[2]; }; vertex float v(In i [[stage_in]]){return i.x;}",
      "struct In { int x [[attribute(0)]]; }; vertex float v(In i [[stage_in]]){return i.x;}",
      "vertex float v(In i [[stage_in]],In j [[stage_in]]){return i.x;}"};
    for(unsigned i=0;i<sizeof bad/sizeof *bad;i++){assert(nvn_vertex_bits_source(bad[i],kinds,&output,&mask,error,sizeof error));assert(!output);}
    kinds[0]=3;assert(nvn_vertex_bits_source(source,kinds,&output,&mask,error,sizeof error));kinds[0]=2;
    for(int i=1;i<argc;i++) {
        FILE *file=fopen(argv[i],"rb");assert(file);fseek(file,0,SEEK_END);long n=ftell(file);assert(n>=0);rewind(file);
        char *data=malloc((size_t)n+1);assert(data&&fread(data,1,n,file)==(size_t)n);fclose(file);data[n]=0;
        for(unsigned slot=0;slot<16;slot++)kinds[slot]=slot%2+1;
        if(nvn_vertex_bits_source(data,kinds,&output,&mask,error,sizeof error)){fprintf(stderr,"Unsupported input: %s\n",error);return 1;}
        free(output);free(data);
    }
    printf("VERTEX BITS OK: mixed fetch classes, unchanged body, strict grammar; %d local sources checked\n",argc-1);return 0;
}
