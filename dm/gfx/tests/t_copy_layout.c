#include "../nvn/nvn_copy_layout.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>
int main(void) {
    size_t row=11,image=22,size=33;
    assert(nvn_copy_layout(7,3,2,1,1,4,256,2048,&row,&image,&size));
    assert(row==256 && image==2048 && size==4096);
    assert(nvn_copy_layout(7,3,2,1,1,4,0,0,&row,&image,&size));
    assert(row==28 && image==84 && size==168);
    assert(nvn_copy_layout(7,9,0,4,4,16,0,0,&row,&image,&size));
    assert(row==32 && image==96 && size==96);
    const int64_t invalid[][2]={{-1,0},{0,-1},{27,0},{256,767},{INT64_MAX,0},{256,INT64_MAX}};
    for(unsigned i=0;i<sizeof invalid/sizeof *invalid;i++) {
        row=11;image=22;size=33;
        assert(!nvn_copy_layout(7,3,3,1,1,4,invalid[i][0],invalid[i][1],&row,&image,&size));
        assert(row==11 && image==22 && size==33);
    }
    assert(!nvn_copy_layout(0,3,1,1,1,4,0,0,&row,&image,&size));
    assert(!nvn_copy_layout(7,-1,1,1,1,4,0,0,&row,&image,&size));
    assert(!nvn_copy_layout(7,3,-1,1,1,4,0,0,&row,&image,&size));
    puts("COPY LAYOUT OK: tight/padded/block-compressed bounds and overflow");return 0;
}
