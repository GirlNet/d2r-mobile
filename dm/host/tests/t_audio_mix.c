// 合成独立声道脉冲验证 5.1 转立体声：中置两侧可闻、左右与环绕方向、低频、饱和及保护字节。
// Synthetic isolated-channel impulses verify 5.1 to stereo: center audible on both sides, left/right/surround direction, LFE, saturation and byte guards.
#include "../audio_mix.h"
#include <stdio.h>
#include <string.h>
#define CHECK(value) do{if(!(value)){fprintf(stderr,"audio mix check failed at line %d: %s\n",__LINE__,#value);return 1;}}while(0)
int main(void) {
    const int16_t expected[6][2]={{10000,0},{0,10000},{7071,7071},{5000,5000},{7071,0},{0,7071}};
    for(int channel=0;channel<6;channel++)for(int sign=-1;sign<=1;sign+=2) {
        int16_t input[6]={0},output[4]={0,0,12345,-23456};input[channel]=(int16_t)(10000*sign);
        dm_audio_51_stereo(output,input,1);
        CHECK(output[0]==expected[channel][0]*sign && output[1]==expected[channel][1]*sign);
        CHECK(output[2]==12345 && output[3]==-23456);
    }
    const int16_t extremes[12]={32767,32767,32767,32767,32767,32767,-32768,-32768,-32768,-32768,-32768,-32768};
    int16_t output[6]={0,0,0,0,12345,-23456};dm_audio_51_stereo(output,extremes,2);
    CHECK(output[0]==32767 && output[1]==32767 && output[2]==-32768 && output[3]==-32768);
    CHECK(output[4]==12345 && output[5]==-23456);
    const int16_t stereo[6]={1234,-5678,0,0,0,0};dm_audio_51_stereo(output,stereo,1);
    CHECK(output[0]==1234 && output[1]==-5678);
    int16_t saved[6];memcpy(saved,output,sizeof saved);dm_audio_51_stereo(output,extremes,0);CHECK(!memcmp(saved,output,sizeof saved));
    puts("AUDIO MIX OK: 12 signed isolated-channel impulses, center/LFE to both speakers, front/surround direction, clipping, guards and zero frames");
    return 0;
}
