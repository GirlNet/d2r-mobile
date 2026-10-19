// Actual public-API decoding of authored VP9 key/inter frames; no game data.
#include "../movie_vp9.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int checks,failures,frames,total_frames,superframe;
static const unsigned char colours[3][3]={{64,90,200},{180,150,40},{100,200,100}};
#define CHECK(test,message) do { checks++;if(!(test)) { failures++;printf("FAIL %s\n",message); } } while(0)
static int output(void *user,dm_vp9_frame *frame) {
    (void)user;int i=frames++;total_frames++;
    CHECK(i<3,"no unexpected decoded frame");
    if(i>=3) { free(frame->data);return 1; }
    CHECK(frame->width==34 && frame->height==26 && frame->size==1326,"decoded I420 shape and padded-row removal");
    CHECK(frame->pts_us==1000000+(superframe?0:(int64_t)i*33333),"presentation time survives decoding");
    size_t lengths[3]={884,221,221},offset=0;
    for(int plane=0;plane<3;plane++) {
        int bad=0;
        for(size_t j=0;j<lengths[plane];j++) {
            int delta=(int)frame->data[offset+j]-colours[i][plane];
            if(delta < -1 || delta > 1) bad++;
        }
        CHECK(!bad,"all decoded plane bytes match the authored colour");offset+=lengths[plane];
    }
    free(frame->data);return 1;
}
static unsigned read32(const unsigned char *p) { return p[0]|(unsigned)p[1]<<8|(unsigned)p[2]<<16|(unsigned)p[3]<<24; }
int main(int argc,char **argv) {
    if(argc!=2) return 2;
    FILE *file=fopen(argv[1],"rb");if(!file) return 2;
    unsigned char header[32];if(fread(header,1,32,file)!=32 || memcmp(header,"DKIF",4) || memcmp(header+8,"VP90",4)) return 2;
    dm_vp9 *decoder=dm_vp9_create(output,NULL);CHECK(decoder!=NULL,"host decoder created");
    unsigned char packet[4096],combined[12288];unsigned lengths[3];size_t combined_size=0;int error=0;
    for(int i=0;i<3;i++) {
        unsigned char frame_header[12];if(fread(frame_header,1,12,file)!=12) return 2;
        unsigned size=read32(frame_header);if(size>sizeof packet || fread(packet,1,size,file)!=size) return 2;
        memcpy(combined+combined_size,packet,size);combined_size+=size;lengths[i]=size;
        if(i==0) {
            int w=0,h=0,range=-1;
            CHECK(dm_vp9_keyframe(packet,size,&w,&h,&range)==0 && w==34 && h==26 && range==0,"VP9 keyframe config parsed");
            CHECK(dm_vp9_keyframe(packet,2,&w,&h,&range)!=0,"truncated keyframe rejected");
        }
        error=dm_vp9_decode(decoder,packet,size,1000000+(int64_t)i*33333);
        CHECK(error==0,"VideoToolbox accepted compressed packet");
        if(error) { printf("VideoToolbox decode error: %d\n",error);break; }
    }
    fclose(file);dm_vp9_destroy(decoder);
    CHECK(frames==3,"keyframe and interframe references yielded three actual frames");
    if(!error) {
        frames=0;superframe=1;combined[combined_size++]=0xc2;
        for(int i=0;i<3;i++) { if(lengths[i]>255) return 2;combined[combined_size++]=(unsigned char)lengths[i]; }
        combined[combined_size++]=0xc2;
        decoder=dm_vp9_create(output,NULL);
        CHECK(dm_vp9_decode(decoder,combined,combined_size,1000000)==0,"VP9 superframe index splits into native frames");
        CHECK(frames==3,"superframe produced all three real images");
        combined[combined_size-4]=0;
        CHECK(dm_vp9_decode(decoder,combined,combined_size,2000000)!=0 && frames==3,"malformed superframe rejected before partial decode");
        dm_vp9_destroy(decoder);
    }
    printf("VP9 ACTUAL DECODE: %d checks, %d failures, %d frames\n",checks,failures,total_frames);
    return failures!=0;
}
