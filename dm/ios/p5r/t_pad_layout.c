// 真实屏幕比例、安全区、坏偏好与边缘拖动的布局回归。
// Layout regression for real screen ratios, safe areas, corrupt preferences and edge dragging.
#include "pad_layout.h"
#include "player_config.h"
#undef NDEBUG
#include <assert.h>
#include <stdio.h>
static void screen(double left,double top,double width,double height) {
    P5RPadLayout p={0};double x=-1,y=-1;
    assert(!p5r_pad_layout_point(&p,0,left,top,width,height,27,27,&x,&y));
    assert(p5r_pad_layout_move(&p,0,.28,.72));
    assert(p5r_pad_layout_point(&p,0,left,top,width,height,27,27,&x,&y));
    assert(fabs(x-left-width*.28)<1e-9 && fabs(y-top-height*.72)<1e-9);
    assert(p5r_pad_layout_move(&p,P5R_PAD_STICK,-20,30));
    assert(p5r_pad_layout_point(&p,P5R_PAD_STICK,left,top,width,height,77,77,&x,&y));
    assert(x==left+77 && y==top+height-77);
    P5RPadLayout saved=p;
    assert(!p5r_pad_layout_load(&p,0,INFINITY,.5));
    assert(!p5r_pad_layout_move(&p,0,NAN,.5));
    assert(!p5r_pad_layout_load(&p,0,1.01,.5));
    assert(!p5r_pad_layout_load(&p,-1,.5,.5));
    assert(!p5r_pad_layout_load(&p,12,.5,.5));
    assert(!p5r_pad_layout_load(&p,19,.5,.5));
    assert(memcmp(&saved,&p,sizeof p)==0);
    assert(!p5r_pad_layout_point(&p,0,left,top,0,height,27,27,&x,&y));
    assert(p5r_pad_layout_point(&p,0,left,top,20,10,77,77,&x,&y));
    assert(x==left+10 && y==top+5);
    p5r_pad_layout_clear(&p);assert(!p.mask);
}
int main(void) {
    screen(59,0,814,409);screen(0,24,1194,790);
    assert(p5r_player_config_allowed("DM_P5R_NO_DEPTHBOUNDS","1"));
    assert(p5r_player_config_allowed("DM_P5R_SKIP_DEPTH_DRAW","0"));
    assert(p5r_player_config_allowed("DM_P5R_COND_IGNORE","1"));
    const char *blocked[]={"DM_NVN_PROF","DM_SLOWFRAME","DM_NVN_SUBPROF","DM_NVN_PASSGPU","DM_NVN_UB","DM_NVN_SHOT","DM_P5R_COMPUTE_BATCH","DM_ROMFS","DM_OPMODE"};
    for(unsigned i=0;i<sizeof blocked/sizeof *blocked;i++)assert(!p5r_player_config_allowed(blocked[i],"1"));
    assert(!p5r_player_config_allowed("DM_P5R_SKIP_DEPTH_DRAW","1"));
    assert(!p5r_player_config_allowed(NULL,"1"));
    puts("PAD LAYOUT OK: phone/tablet safe areas, invalid preferences, reset and player config");
}
