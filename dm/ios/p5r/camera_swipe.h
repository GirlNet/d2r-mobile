// P5R 相对滑动视角：将手指速度映射为右摇杆，短时无移动即归零；不读取游戏内存。
// P5R relative camera swipes: map finger velocity to the right stick and expire idle motion promptly, without reading game memory.
#ifndef P5R_CAMERA_SWIPE_H
#define P5R_CAMERA_SWIPE_H
#include <math.h>
#include <stdint.h>

typedef struct {
    uintptr_t finger;
    double x, y, time, height, vx, vy, hold;
} P5RCameraSwipe;

static inline void p5r_camera_reset(P5RCameraSwipe *s) { *s=(P5RCameraSwipe){0}; }
static inline int p5r_camera_begin(P5RCameraSwipe *s,uintptr_t finger,double x,double y,double time,double height) {
    if(s->finger || !finger || !isfinite(x) || !isfinite(y) || !isfinite(time) || !isfinite(height) || height<1)return 0;
    *s=(P5RCameraSwipe){.finger=finger,.x=x,.y=y,.time=time,.height=height};
    return 1;
}
static inline void p5r_camera_move(P5RCameraSwipe *s,uintptr_t finger,double x,double y,double time) {
    if(!s->finger || s->finger!=finger)return;
    if(!isfinite(x) || !isfinite(y) || !isfinite(time) || time<s->time) { p5r_camera_reset(s);return; }
    double dt=fmin(fmax(time-s->time,1.0/240),1.0/30);
    double vx=(x-s->x)/(s->height*.75*dt),vy=-(y-s->y)/(s->height*.75*dt);
    if(!isfinite(vx) || !isfinite(vy)) { p5r_camera_reset(s);return; }
    s->x=x;s->y=y;s->time=time;s->vx=vx;s->vy=vy;
    // 仅跨过相邻触摸事件保持速度，最多 50 ms，避免 60 Hz 触摸在 120 Hz 刷新下隔帧归零。
    // Hold velocity only between adjacent touch events, for at most 50 ms, avoiding alternating zeroes with 60 Hz touches on a 120 Hz display.
    s->hold=fmin(fmax(dt*2,1.0/60),1.0/20);
}
static inline void p5r_camera_end(P5RCameraSwipe *s,uintptr_t finger) {
    if(s->finger==finger)p5r_camera_reset(s);
}
static inline void p5r_camera_axes(const P5RCameraSwipe *s,double time,int32_t *x,int32_t *y) {
    *x=*y=0;
    if(!s->finger || !isfinite(time) || time<s->time || time-s->time>=s->hold)return;
    double length=hypot(s->vx,s->vy),scale=length>1?1/length:1;
    *x=(int32_t)lrint(s->vx*scale*32767);*y=(int32_t)lrint(s->vy*scale*32767);
}
#endif
