// Real public adapters: by-value eight-byte codes, both comparison argument
// orders, all language pairs, bounded writes and invalid-input behavior.
#include "../hle_settings.c"
#include <assert.h>
#include <limits.h>
int main(int argc, char **argv) {
    (void)argv;
    if (argc > 1) { h_settings_MakeCode(18); return 1; }
    const char *expected[] = {"ja","en-US","fr","de","it","es","zh-CN","ko","nl","pt","ru","zh-TW","en-GB","fr-CA","es-419","zh-Hans","zh-Hant","pt-BR"};
    for (int i=0;i<18;i++) {
        char bytes[8]={0};memcpy(bytes,expected[i],strlen(expected[i]));
        uint64_t code=h_settings_MakeCode(i);assert(!memcmp(&code,bytes,8));
        for(int j=0;j<18;j++) {
            assert(h_settings_EqualCode(&code,&j)==(unsigned)(i==j));
            assert(h_settings_EqualLanguage(&j,&code)==(unsigned)(i==j));
        }
    }
    struct { uint64_t before;uint64_t codes[20];uint64_t after; } output;
    for(int capacity=-1;capacity<22;capacity++) {
        memset(&output,0xa5,sizeof output);
        int count=h_settings_Available(output.codes,capacity);
        assert(count==(capacity<0?0:capacity<18?capacity:18));
        for(int i=0;i<count;i++)assert(output.codes[i]==h_settings_MakeCode(i));
        for(int i=count;i<20;i++)assert(output.codes[i]==UINT64_C(0xa5a5a5a5a5a5a5a5));
        assert(output.before==UINT64_C(0xa5a5a5a5a5a5a5a5)&&output.after==output.before);
    }
    assert(h_settings_Available(output.codes,INT_MAX)==18);
    assert(h_settings_Available(NULL,18)==0&&h_settings_Available((void *)1,0)==0);
    int invalid=-1;uint64_t code=h_settings_MakeCode(15);
    assert(!h_settings_EqualCode(&code,&invalid)&&!h_settings_EqualLanguage(&invalid,&code));
    assert(!h_settings_EqualCode(NULL,&invalid)&&!h_settings_EqualLanguage(NULL,&code));
    puts("HOST LANGUAGE OK: 18 eight-byte codes, 648 ordered equality checks, bounded roster writes and input guards");
    return 0;
}
