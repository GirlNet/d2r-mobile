// Synthetic layout contract checks, without game data or Metal.
#include "../nvn_deswizzle.h"
#include <stdio.h>
#include <string.h>

#define CHECK(x) do { checks++;if(!(x)){fprintf(stderr,"linear layout check failed at %d\n",__LINE__);return 1;} } while(0)
int main(void) {
    unsigned checks=0;
    const int flags[]={0x10,0x14,0x40,0x44,0x50,0x54};
    const unsigned widths[]={1,7,16,31,100},heights[]={1,3,16,37};
    for(unsigned f=0;f<6;f++)for(unsigned w=0;w<5;w++)for(unsigned h=0;h<4;h++) {
        unsigned alignment=flags[f]&0x40 ? 128 : 32;
        unsigned stride=(widths[w]*4+alignment-1)&~(alignment-1);
        nvn_texdesc d={.target=1,.format=0x25,.flags=flags[f],.width=widths[w],.height=heights[h],.depth=1,.levels=1,.stride=stride};
        nvn_texlayout l;nvn_tex_layout(&d,&l);
        CHECK(nvn_tex_is_linear(&d));CHECK(l.align==alignment);CHECK(l.size==(uint64_t)stride*heights[h]);CHECK(l.layer_size==l.size);
        CHECK(l.tileH==0 && l.tileD==0 && l.layers==1);CHECK(nvn_tex_level_offset(&d,1)==0);
        uint32_t rb,rows,slices,bpb;uint64_t base;unsigned th,td;
        CHECK(nvn_deswizzle_geom(&d,0,0,&rb,&rows,&slices,&base,&th,&td,&bpb)==-1);
        // Both conversion directions must reject before touching either buffer.
        unsigned char source[64],dest[64],before[64];memset(source,0x5a,64);memset(dest,0xa5,64);memcpy(before,dest,64);
        CHECK(nvn_deswizzle(&d,0,0,source,dest,stride)==-1);CHECK(!memcmp(dest,before,64));
        CHECK(nvn_swizzle(&d,0,0,source,stride,dest)==-1);CHECK(!memcmp(dest,before,64));
    }
    nvn_texdesc tiled={.target=1,.format=0x25,.width=16,.height=16,.depth=1,.levels=1};nvn_texlayout l;nvn_tex_layout(&tiled,&l);
    CHECK(!nvn_tex_is_linear(&tiled));CHECK(l.size==1024 && l.align==512);
    printf("linear texture layout: %u checks passed\n",checks);return 0;
}
