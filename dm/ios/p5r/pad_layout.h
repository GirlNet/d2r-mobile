// 虚拟手柄布局的安全区归一化位置；用于编辑预览和游戏内同一套几何计算。
// Safe-area-normalized pad positions shared by the editor preview and in-game geometry.
#ifndef P5R_PAD_LAYOUT_H
#define P5R_PAD_LAYOUT_H
#include <math.h>
#include <stdint.h>
#include <string.h>
enum { P5R_PAD_STICK=16, P5R_PAD_DPAD=17, P5R_PAD_SWITCH=18, P5R_PAD_LAYOUT_COUNT=19 };
typedef struct { uint32_t mask; double x[P5R_PAD_LAYOUT_COUNT],y[P5R_PAD_LAYOUT_COUNT]; } P5RPadLayout;
static inline int p5r_pad_layout_id(int id) { return (id>=0 && id<12) || (id>=P5R_PAD_STICK && id<P5R_PAD_LAYOUT_COUNT); }
static inline void p5r_pad_layout_clear(P5RPadLayout *p) { memset(p,0,sizeof *p); }
static inline int p5r_pad_layout_load(P5RPadLayout *p,int id,double x,double y) {
    if(!p5r_pad_layout_id(id) || !isfinite(x) || !isfinite(y) || x<0 || x>1 || y<0 || y>1)return 0;
    p->x[id]=x;p->y[id]=y;p->mask|=UINT32_C(1)<<id;return 1;
}
static inline int p5r_pad_layout_move(P5RPadLayout *p,int id,double x,double y) {
    if(!isfinite(x) || !isfinite(y))return 0;
    return p5r_pad_layout_load(p,id,fmax(0,fmin(1,x)),fmax(0,fmin(1,y)));
}
static inline int p5r_pad_layout_point(const P5RPadLayout *p,int id,double left,double top,double width,double height,
                                      double radiusX,double radiusY,double *x,double *y) {
    if(!p5r_pad_layout_id(id) || !(p->mask&(UINT32_C(1)<<id)) || width<=0 || height<=0)return 0;
    double rx=fmin(fmax(radiusX,0),width/2),ry=fmin(fmax(radiusY,0),height/2);
    *x=left+fmax(rx,fmin(width-rx,p->x[id]*width));
    *y=top+fmax(ry,fmin(height-ry,p->y[id]*height));return 1;
}
#endif
