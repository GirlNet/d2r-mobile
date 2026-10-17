#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>
// Maxwell compares counter values at 0 and 16; the intervening timestamps are
// not operands. NVN modes 0/1 select equal/not-equal. Invalid input preserves out.
static inline int nvn_conditional_render_decode(int mode,const void *data,size_t bytes,int *out) {
    if(!data || !out || bytes<24 || (mode!=0 && mode!=1))return 0;
    uint64_t left,right;memcpy(&left,data,8);memcpy(&right,(const uint8_t *)data+16,8);
    *out=mode==0?left==right:left!=right;return 1;
}
