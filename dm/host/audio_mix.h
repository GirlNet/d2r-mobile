// 按 PCM 5.1 的 L/R/C/LFE/Ls/Rs 顺序合成立体声；中置与环绕衰减 3 dB，低频衰减 6 dB，最后饱和到 PCM16。
// Fold PCM 5.1 in L/R/C/LFE/Ls/Rs order into stereo; attenuate center/surrounds by 3 dB and LFE by 6 dB, then saturate to PCM16.
#ifndef DM_AUDIO_MIX_H
#define DM_AUDIO_MIX_H
#include <stddef.h>
#include <stdint.h>

static inline int16_t dm_audio_clip16(float value) {
    if(value>32767.0f)return 32767;
    if(value<-32768.0f)return -32768;
    return (int16_t)value;
}
static inline void dm_audio_51_stereo(int16_t *destination,const int16_t *source,size_t frames) {
    for(size_t frame=0;frame<frames;frame++,source+=6,destination+=2) {
        float common=0.70710678f*source[2]+0.5f*source[3];
        destination[0]=dm_audio_clip16(source[0]+common+0.70710678f*source[4]);
        destination[1]=dm_audio_clip16(source[1]+common+0.70710678f*source[5]);
    }
}
#endif
