#include "../../ios/p5r/stick_math.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    int32_t x,y;
    p5r_stick(0,0,50,&x,&y);assert(!x&&!y);
    p5r_stick(5,2,50,&x,&y);assert(!x&&!y);
    p5r_stick(50,0,50,&x,&y);assert(x==32767&&!y);
    p5r_stick(0,-100,50,&x,&y);assert(!x&&y==32767);
    p5r_stick(-100,0,50,&x,&y);assert(x==-32767&&!y);
    p5r_stick(0,50,50,&x,&y);assert(!x&&y==-32767);
    p5r_stick(25,0,50,&x,&y);assert(x>=14148&&x<=14150&&!y);
    p5r_stick(100,-100,50,&x,&y);assert(x==23170&&y==23170);
    const float bad[][3]={{NAN,0,50},{0,INFINITY,50},{1,1,0},{1,1,-5},{1,1,NAN}};
    for(unsigned i=0;i<sizeof bad/sizeof *bad;i++){p5r_stick(bad[i][0],bad[i][1],bad[i][2],&x,&y);assert(!x&&!y);}
    for(int dx=-100;dx<=100;dx++)for(int dy=-100;dy<=100;dy++) {
        p5r_stick(dx,dy,50,&x,&y);assert(x>=-32767&&x<=32767&&y>=-32767&&y<=32767);
        assert((double)x*x+(double)y*y<=(32768.0*32768.0));
    }
    puts("P5R STICK OK: deadzone, Nintendo axes, radial clamp and invalid coordinates");return 0;
}
