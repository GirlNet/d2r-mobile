// 无游戏资源的相对镜头滑动回归：多指所有权、停手、取消、尺寸与输入／刷新频率。
// Game-free relative camera swipe regression: multi-finger ownership, idle expiry, cancellation, dimensions and input/display rates.
#include "camera_swipe.h"
// 即使构建配置定义 NDEBUG，也必须执行触控断言。
// Execute input assertions even when the build configuration defines NDEBUG.
#undef NDEBUG
#include <assert.h>
#include <stdio.h>

static void rates(double height,int events,int ticks) {
    P5RCameraSwipe s={0};int32_t x,y;double xsum=0;int samples=0;
    assert(p5r_camera_begin(&s,1,100,100,1,height));
    int moved=0;
    for(int tick=1;tick<=ticks;tick++) {
        double now=1+(double)tick/ticks;
        while(moved<events && 1+(double)(moved+1)/events<=now+1e-10) {
            moved++;double t=1+(double)moved/events;
            p5r_camera_move(&s,1,100+height*.1875*(t-1),100,t);
        }
        p5r_camera_axes(&s,now,&x,&y);assert(y==0);
        if(tick*events>=ticks) { assert(x>0);xsum+=x;samples++; }
    }
    assert(fabs(xsum/samples-8192)<1);
    p5r_camera_axes(&s,2.051,&x,&y);assert(x==0 && y==0 && s.finger==1);
    p5r_camera_end(&s,1);assert(s.finger==0);
}
int main(void) {
    P5RCameraSwipe s={0};int32_t x,y;
    assert(p5r_camera_begin(&s,1,600,200,10,430));
    p5r_camera_axes(&s,10,&x,&y);assert(x==0 && y==0);
    assert(!p5r_camera_begin(&s,2,700,100,10,430));
    p5r_camera_move(&s,2,900,50,10.01);p5r_camera_axes(&s,10.01,&x,&y);assert(x==0 && y==0);
    p5r_camera_move(&s,1,605,195,10.02);p5r_camera_axes(&s,10.02,&x,&y);assert(x>0 && y>0);
    p5r_camera_end(&s,2);assert(s.finger==1);
    p5r_camera_axes(&s,10.071,&x,&y);assert(x==0 && y==0);
    p5r_camera_move(&s,1,600,200,11);p5r_camera_axes(&s,11,&x,&y);assert(x<0 && y<0);
    p5r_camera_end(&s,1);p5r_camera_axes(&s,11,&x,&y);assert(x==0 && y==0);
    assert(p5r_camera_begin(&s,2,900,100,12,430));
    p5r_camera_axes(&s,12,&x,&y);assert(x==0 && y==0);
    p5r_camera_move(&s,2,1900,-900,12.001);p5r_camera_axes(&s,12.001,&x,&y);
    assert(x>0 && y>0 && hypot(x,y)<32768);
    p5r_camera_reset(&s);p5r_camera_move(&s,2,2000,100,13);p5r_camera_axes(&s,13,&x,&y);assert(x==0 && y==0);
    assert(!p5r_camera_begin(&s,0,100,100,1,430));
    assert(!p5r_camera_begin(&s,1,NAN,100,1,430));
    assert(!p5r_camera_begin(&s,1,100,100,INFINITY,430));
    assert(!p5r_camera_begin(&s,1,100,100,1,0));
    assert(p5r_camera_begin(&s,1,100,100,1,430));
    p5r_camera_move(&s,1,NAN,100,2);assert(s.finger==0);
    assert(p5r_camera_begin(&s,1,100,100,3,430));
    p5r_camera_move(&s,1,105,100,2);assert(s.finger==0);
    const double heights[]={320,430,768,1024};
    const int inputs[]={30,60,120},displays[]={30,60,120};
    for(unsigned h=0;h<sizeof heights/sizeof *heights;h++)
        for(unsigned i=0;i<sizeof inputs/sizeof *inputs;i++)
            for(unsigned d=0;d<sizeof displays/sizeof *displays;d++)rates(heights[h],inputs[i],displays[d]);
    puts("P5R CAMERA SWIPE OK: 36 input/display/size combinations, relative motion, idle expiry, ownership, release, reset and bounds");
    return 0;
}
