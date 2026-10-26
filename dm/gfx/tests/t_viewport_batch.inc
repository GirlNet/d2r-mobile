// Public thunks must snapshot input arrays and preserve state on empty updates.
static void test_viewport_batch_recording(void) {
    uint8_t storage[4096];pool_t pool={.mem=storage,.size=sizeof storage};NVNcommandBuffer cb;
    P(nvnCommandBufferInitialize)(&cb,&dev);
    P(nvnCommandBufferAddCommandMemory)(&cb,(const NVNmemoryPool *)&pool,0,sizeof storage);
    P(nvnCommandBufferBeginRecording)(&cb);
    uint8_t *before=CB(&cb)->cur;
    P(nvnCommandBufferSetScissors)(&cb,16,0,NULL);P(nvnCommandBufferSetDepthRanges)(&cb,16,0,NULL);
    EXPECT("empty viewport batches allocate no command",(uintptr_t)before,(uintptr_t)CB(&cb)->cur);
    const int counts[]={1,2,16};
    for(unsigned c=0;c<3;c++) {
        int rectangles[16][4];float ranges[16][2];
        for(int i=0;i<counts[c];i++) {memcpy(rectangles[i],(int[]){-2,1,7,3},16);memcpy(ranges[i],(float[]){.25f,.75f},8);}
        uint8_t *sc=CB(&cb)->cur;P(nvnCommandBufferSetScissors)(&cb,0,counts[c],rectangles[0]);
        uint8_t *dr=CB(&cb)->cur;P(nvnCommandBufferSetDepthRanges)(&cb,0,counts[c],ranges[0]);
        memset(rectangles,0,sizeof rectangles);memset(ranges,0,sizeof ranges);
        op_hdr header;memcpy(&header,sc,8);p_scissor r;memcpy(&r,sc+8,sizeof r);
        EXPECT("batch scissor records immutable scalar snapshot",1,header.op==OP_SCISSOR && r.x==-2 && r.y==1 && r.w==7 && r.h==3);
        memcpy(&header,dr,8);p_depth_range d;memcpy(&d,dr+8,sizeof d);
        EXPECT("batch depth range records immutable scalar snapshot",1,header.op==OP_DEPTH_RANGE && d.n==.25f && d.f==.75f);
    }
    P(nvnCommandBufferEndRecording)(&cb);P(nvnCommandBufferFinalize)(&cb);
}
