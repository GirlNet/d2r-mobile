#ifndef P5R_STICK_MATH_H
#define P5R_STICK_MATH_H
#include <math.h>
#include <stdint.h>
static inline void p5r_stick(float dx,float dy,float radius,int32_t *x,int32_t *y) {
    *x=*y=0;
    if(!isfinite(dx)||!isfinite(dy)||!isfinite(radius)||radius<=0)return;
    float distance=hypotf(dx,dy),normalized=distance/radius;
    if(normalized<=.12f)return;
    float magnitude=fminf((normalized-.12f)/.88f,1.f)*32767.f;
    *x=(int32_t)lrintf(dx/distance*magnitude);
    *y=(int32_t)lrintf(-dy/distance*magnitude);
}
#endif
