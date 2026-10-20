// hle_audio.c 单测（静音接收端）：3 块各 100 ms 缓冲 → 按序在约 100/200/300 ms 释放、每次释放触发事件。
// 期望值由采样率与块长直接算出：4800 帧 / 48 kHz = 100 ms。
// hle_audio.c unit test (silent sink): 3 buffers of 100 ms each -> released in order at about 100/200/300 ms, each release triggering the event.
// Expected values are computed directly from the sample rate and block length: 4800 frames / 48 kHz = 100 ms.
#include "../hle_audio.c"
#include <time.h>
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static struct { const void *k; void *v; } om[8];
void *objmap_get(const void *k) { for (int i = 0; i < 8; i++) if (om[i].k == k) return om[i].v; return NULL; }
void objmap_put(const void *k, void *v) { for (int i = 0; i < 8; i++) if (!om[i].k) { om[i].k = k; om[i].v = v; return; } }
void *objmap_del(const void *k) { for (int i = 0; i < 8; i++) if (om[i].k == k) { om[i].k = 0; return om[i].v; } return NULL; }
static _Atomic int g_sig;
static void *bound_event;
static int bound_autoclear;
void hle_signal_system_event(void *g) { (void)g; atomic_fetch_add_explicit(&g_sig, 1, memory_order_seq_cst); }
void hle_bind_system_event(void *g, int autoclear) { bound_event = g; bound_autoclear = autoclear; }   // The real implementation binds SDK kernel events; this test records the ABI.
// 直接调用真实回调，跨不完整帧的缓冲边界和 256 帧分块核验转换、释放顺序及六声道客体时钟。
// Call the production callback across partial-frame buffer boundaries and 256-frame chunks, checking conversion, release order and the six-channel guest clock.
static int test_render_mix(void) {
    enum { FRAMES=600 };
    int16_t source[FRAMES*6]={0},destination[FRAMES*2+4];
    for(int frame=0;frame<FRAMES;frame++)source[frame*6+2]=frame%2?-10000:10000;
    for(unsigned i=0;i<sizeof destination/sizeof destination[0];i++)destination[i]=12345;
    char object[64];uint8_t parameter[16];h_au_InitParam(parameter);*(uint16_t *)(parameter+4)=6;
    if(h_au_OpenDefault(object,parameter))return 1;
    gbuf buffers[3];size_t cuts[]={0,5,419,sizeof source};
    for(int i=0;i<3;i++) {
        h_au_SetBuf(&buffers[i],(uint8_t *)source+cuts[i],cuts[i+1]-cuts[i],cuts[i+1]-cuts[i]);
        if(!h_au_Append(object,&buffers[i]))return 1;
    }
    aout *output=ao(object);atomic_store(&output->state,STATE_STARTED);
    AudioBufferList list={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=2,.mDataByteSize=FRAMES*4,.mData=destination}}};
    if(au_render(output,NULL,NULL,0,FRAMES,&list))return 1;
    for(int frame=0;frame<FRAMES;frame++)if(destination[frame*2]!=(frame%2?-7071:7071) || destination[frame*2+1]!=destination[frame*2])return 1;
    for(int i=0;i<4;i++)if(destination[FRAMES*2+i]!=12345)return 1;
    if(h_au_Ch(object)!=6 || h_au_Played(object)!=FRAMES)return 1;
    for(int i=0;i<3;i++)if(h_au_Released(object)!=&buffers[i])return 1;
    if(au_render(output,NULL,NULL,0,FRAMES,&list) || h_au_Played(object)!=FRAMES)return 1;
    for(int i=0;i<FRAMES*2;i++)if(destination[i])return 1;
    atomic_store(&output->state,STATE_STOPPED);h_au_Close(object);
    for(int channels=1;channels<=2;channels++) {
        h_au_InitParam(parameter);*(uint16_t *)(parameter+4)=channels;
        if(h_au_OpenDefault(object,parameter))return 1;
        gbuf buffer;int16_t input[4]={1000,-2000,3000,-4000},result[6]={0,0,0,0,12345,-23456};
        h_au_SetBuf(&buffer,input,sizeof input,sizeof input);if(!h_au_Append(object,&buffer))return 1;
        output=ao(object);atomic_store(&output->state,STATE_STARTED);
        list.mBuffers[0]=(AudioBuffer){.mNumberChannels=(UInt32)channels,.mDataByteSize=sizeof input,.mData=result};
        if(au_render(output,NULL,NULL,0,4/channels,&list) || memcmp(input,result,sizeof input))return 1;
        if(result[4]!=12345 || result[5]!=-23456 || h_au_Played(object)!=4u/(unsigned)channels || h_au_Released(object)!=&buffer)return 1;
        atomic_store(&output->state,STATE_STOPPED);h_au_Close(object);
    }
    puts("AUDIO RENDER MIX OK: center-only stereo output, 600 frames across odd buffer boundaries/chunks, source frame clock, releases, underrun, mono/stereo passthrough and guards");
    return 0;
}
// 精确核对 PCM 帧计数，不依赖时钟或声卡；停止/空队列的补零不计，半帧字节跨块保留。
// Check exact PCM frame counts without a clock/audio device; stopped/empty-queue silence does not count, and partial frames carry across buffers.
static int test_played_count(void) {
    const int channels[] = {1, 2, 6};
    char out[64]; uint8_t prm[16], pcm[36] = {0}, dst[48]; gbuf b[2];
    for (unsigned c = 0; c < sizeof channels / sizeof channels[0]; c++) {
        h_au_InitParam(prm); *(uint16_t *)(prm + 4) = channels[c];
        if (h_au_OpenDefault(out, prm) || h_au_Played(out)) return 1;
        h_au_SetBuf(&b[0], pcm, sizeof pcm, 5);
        h_au_SetBuf(&b[1], pcm + 5, sizeof pcm - 5, 31);
        if (!h_au_Append(out, &b[0]) || !h_au_Append(out, &b[1])) return 1;
        aout *a = ao(out); pull(a, dst, 3);
        if (h_au_Played(out)) return 1;
        atomic_store(&a->state, STATE_STARTED);
        pull(a, dst, 3);
        if (h_au_Played(out) != 3u / (2u * channels[c])) return 1;
        pull(a, dst, 4);
        if (h_au_Played(out) != 7u / (2u * channels[c]) || h_au_Released(out) != &b[0]) return 1;
        atomic_store(&a->state, STATE_STOPPED); pull(a, dst, 8);
        if (h_au_Played(out) != 7u / (2u * channels[c])) return 1;
        atomic_store(&a->state, STATE_STARTED); pull(a, dst, sizeof dst);
        if (h_au_Played(out) != 36u / (2u * channels[c]) || h_au_Released(out) != &b[1]) return 1;
        pull(a, dst, sizeof dst);
        if (h_au_Played(out) != 36u / (2u * channels[c])) return 1;
        atomic_store(&a->state, STATE_STOPPED); h_au_Close(out);
    }
    if (h_au_OpenDefault(out, prm) || h_au_Played(out)) return 1;
    h_au_Close(out);
    puts("PLAYED COUNT OK: mono/stereo/6-channel, partial frames, stop/resume, underrun, reopen");
    return 0;
}
int main(void) {
    if(test_render_mix())return 1;
    if (test_played_count()) return 1;
    char out[64], ev[64]; uint8_t prm[16]; gbuf b[3]; static int16_t pcm[3][4800 * 2];
    memset(ev, 0xa5, sizeof ev);
    if (h_au_DeviceEvent(ev) || bound_event != ev || bound_autoclear || g_sig) return 1;
    for (unsigned i = 0; i < sizeof ev; i++) if ((uint8_t)ev[i] != 0xa5) return 1;
    h_au_InitParam(prm);
    // 默认设备的两种 ABI 重载均建立真正的宿主对象；事件只在带事件版本绑定。
    // Both default-device ABI overloads create real host objects; only the event overload binds an event.
    if (h_au_OpenDefault(out, prm)) return 1;
    if (strcmp(h_au_Name(out), "DeviceOut") || ao(out)->event) return 1;
    h_au_Close(out);
    if (h_au_OpenDefaultEvent(out, ev, prm)) return 1;
    if (strcmp(h_au_Name(out), "DeviceOut") || ao(out)->event != ev) return 1;
    h_au_Close(out);
    if (h_au_Open(out, ev, NULL, prm)) return 1;
    if (h_au_Ch(out) != 2 || h_au_Rate(out) != 48000 || h_au_State(out) != STATE_STOPPED) { puts("FAIL 参数"); return 1; }
    for (int i = 0; i < 3; i++) { h_au_SetBuf(&b[i], pcm[i], sizeof pcm[i], sizeof pcm[i]); if (!h_au_Append(out, &b[i])) return 1; }
    if (h_au_Released(out)) { puts("FAIL 未开始就有释放"); return 1; }
    uint64_t t0 = now_ns(); h_au_Start(out);
    int got = 0, fail = 0;
    while (got < 3 && now_ns() - t0 < 10000000000ull) {
        gbuf *r = h_au_Released(out);
        if (!r) { usleep(1000); continue; }
        int ok = r == &b[got];
        printf("释放 #%d：期望 块%d 按序 → 真结果 块%ld %s\n", got, got, (long)(r - b), ok ? "✓" : "✗");
        fail |= !ok; got++;
    }
    fail |= h_au_Played(out) != 14400;
    h_au_Close(out);
    int sig1 = atomic_load_explicit(&g_sig, memory_order_acquire);
    printf("释放 %d/3，事件触发 %d 次（期望 3）\n", got, sig1);
    if (fail || got != 3 || sig1 != 3) return 1;

    // 场景 2：真出声端（PCM 全 0，听不到）播 6 块各 100 ms，第 150 ms 暂停（切后台 / 来电）、第 350 ms 恢复。
    // 期望：暂停期间由静音接收端接手按实时消耗，6 块按序全部释放、事件 6 次；总时长 ≈ 600 ms（实时，不因暂停停住也不加速）。
    // Scenario 2: the real audio output sink (PCM all 0, inaudible) plays 6 blocks of 100 ms each, pausing at 150 ms (app to background / incoming call) and resuming at 350 ms.
    // Expected: during the pause the silent sink takes over and consumes in real time, all 6 blocks are released in order with 6 events; total duration ~ 600 ms (real time, neither stalled by the pause nor sped up).
    setenv("DM_AUDIO", "1", 1);
    // 真 AudioUnit 的输入流为两声道，而客体仍查询到六声道。
    // The real AudioUnit input stream is stereo while guest queries still report six channels.
    char format_object[64];uint8_t surround_parameter[16];h_au_InitParam(surround_parameter);*(uint16_t *)(surround_parameter+4)=6;
    if(h_au_OpenDefault(format_object,surround_parameter))return 1;
    AudioStreamBasicDescription stream={0};UInt32 stream_size=sizeof stream;
    if(AudioUnitGetProperty(ao(format_object)->au,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&stream,&stream_size) ||
       stream.mChannelsPerFrame!=2 || stream.mBytesPerFrame!=4 || stream.mSampleRate!=48000 || h_au_Ch(format_object)!=6)return 1;
    h_au_Close(format_object);
    char out2[64]; gbuf b2[6]; static int16_t pcm2[6][4800 * 2]; g_sig = 0;
    if (h_au_Open(out2, ev, NULL, prm)) return 1;
    for (int i = 0; i < 6; i++) { h_au_SetBuf(&b2[i], pcm2[i], sizeof pcm2[i], sizeof pcm2[i]); h_au_Append(out2, &b2[i]); }
    t0 = now_ns(); h_au_Start(out2);
    int got2 = 0, order_ok = 1, susp = 0, resumed = 0;
    while (got2 < 6 && now_ns() - t0 < 10000000000ull) {
        uint64_t ms = (now_ns() - t0) / 1000000;
        if (!susp && ms >= 150) { dm_audio_suspend(1); susp = 1; }
        if (susp && !resumed && ms >= 350) { dm_audio_suspend(0); resumed = 1; }
        gbuf *r = h_au_Released(out2);
        if (!r) { usleep(1000); continue; }
        order_ok &= r == &b2[got2]; got2++;
    }
    double total = (now_ns() - t0) / 1e6;
    int count_ok = h_au_Played(out2) == 28800;
    h_au_Close(out2);
    int sig2 = atomic_load_explicit(&g_sig, memory_order_acquire);
    int ok2 = got2 == 6 && order_ok && sig2 == 6 && total > 520 && count_ok;
    printf("暂停 / 恢复：释放 %d/6 按序=%d 事件 %d（期望 6）总时长下限 520 ms，真结果 %.0f ms %s\n", got2, order_ok, sig2, total, ok2 ? "✓" : "✗");
    return !ok2;
}
