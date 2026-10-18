// Exercise the public thunks, command replay and real GPU copies with different
// row/image pitches. Pixel expectations and untouched padding are independent.
static int test_copy_image_stride_gpu(void) {
    enum { SIZE = 131072, SOURCE = 16384, OUTPUT = 32768, COMMANDS = 65536 };
    uint8_t *memory = aligned_alloc(16384, SIZE); if (!memory) return 1;
    memset(memory, 0, SIZE);
    NVNmemoryPoolBuilder pb; NVNmemoryPool pool;
    P(nvnMemoryPoolBuilderSetDevice)(&pb, &dev); P(nvnMemoryPoolBuilderSetDefaults)(&pb);
    P(nvnMemoryPoolBuilderSetStorage)(&pb, memory, SIZE); P(nvnMemoryPoolBuilderSetFlags)(&pb, 0x22);
    EXPECT("copy pool initializes", 1, P(nvnMemoryPoolInitialize)(&pool, &pb));
    NVNqueueBuilder qb={0}; NVNqueue queue;
    P(nvnQueueBuilderSetDevice)(&qb, &dev); P(nvnQueueBuilderSetDefaults)(&qb);
    P(nvnQueueInitialize)(&queue, &qb);
    NVNcommandBuffer cb; P(nvnCommandBufferInitialize)(&cb, &dev);
    P(nvnCommandBufferAddCommandMemory)(&cb, &pool, COMMANDS, 32768);
    const NVNtextureTarget targets[]={NVN_TEXTURE_TARGET_2D_ARRAY,NVN_TEXTURE_TARGET_3D};
    for (unsigned target=0;target<2;target++) {
        NVNtextureBuilder tb; NVNtexture texture;
        P(nvnTextureBuilderSetDevice)(&tb,&dev); P(nvnTextureBuilderSetDefaults)(&tb);
        P(nvnTextureBuilderSetTarget)(&tb,targets[target]); P(nvnTextureBuilderSetSize3D)(&tb,7,3,2);
        P(nvnTextureBuilderSetFormat)(&tb,NVN_FORMAT_RGBA8); P(nvnTextureBuilderSetStorage)(&tb,&pool,0);
        EXPECT("copy texture storage fits",1,P(nvnTextureBuilderGetStorageSize)(&tb)<SOURCE);
        EXPECT("copy texture initializes",1,P(nvnTextureInitialize)(&texture,&tb));
        for (int reset=0;reset<2;reset++) {
            size_t input_image=reset?768:2048;
            memset(memory+SOURCE,0x7d,8192);memset(memory+OUTPUT,0xa7,8192);
            for(int z=0;z<2;z++)for(int y=0;y<3;y++)for(int x=0;x<28;x++)
                memory[SOURCE+z*input_image+y*256+x]=(uint8_t)(z*73+y*13+x+reset);
            // The game initializes a view in a 16-byte slot after constructing
            // the adjacent region. Exercise that order through real thunks.
            struct { uint64_t guard; NVNtextureView view; NVNcopyRegion region; } adjacent={
                .guard=UINT64_C(0x123456789abcdef0),.region={0,0,0,7,3,2}};
            P(nvnTextureViewSetDefaults)(&adjacent.view);
            P(nvnTextureViewSetLevels)(&adjacent.view,0,1);
            EXPECT("copy region survives adjacent view initialization",1,
                   adjacent.region.width==7 && adjacent.region.height==3 && adjacent.region.depth==2 &&
                   adjacent.guard==UINT64_C(0x123456789abcdef0));
            P(nvnCommandBufferBeginRecording)(&cb);
            P(nvnCommandBufferSetCopyRowStride)(&cb,256);
            P(nvnCommandBufferSetCopyImageStride)(&cb,reset?0:2048);
            P(nvnCommandBufferCopyBufferToTexture)(&cb,(uintptr_t)(memory+SOURCE),&texture,&adjacent.view,&adjacent.region,0);
            P(nvnCommandBufferSetCopyRowStride)(&cb,512);
            P(nvnCommandBufferSetCopyImageStride)(&cb,3072);
            P(nvnCommandBufferCopyTextureToBuffer)(&cb,&texture,&adjacent.view,&adjacent.region,(uintptr_t)(memory+OUTPUT),0);
            NVNcommandHandle handle=P(nvnCommandBufferEndRecording)(&cb);
            P(nvnQueueSubmitCommands)(&queue,1,&handle);P(nvnQueueFinish)(&queue);
            int pixels=0,padding=0;
            for(int i=0;i<8192;i++) {
                int z=i/3072,y=(i%3072)/512,x=i%512;
                int pixel=z<2 && y<3 && x<28;
                uint8_t expected=pixel?(uint8_t)(z*73+y*13+x+reset):0xa7;
                if(memory[OUTPUT+i]!=expected){if(pixel)pixels++;else padding++;}
            }
            EXPECT("array/3D copy pixels use image stride",0,pixels);
            EXPECT("array/3D copy leaves pitch padding untouched",0,padding);
        }
        P(nvnTextureFinalize)(&texture);
    }
    mtl_drain();P(nvnCommandBufferFinalize)(&cb);P(nvnQueueFinalize)(&queue);
    P(nvnMemoryPoolFinalize)(&pool);free(memory);
    printf("COPY IMAGE STRIDE GPU: %d checks, %d failures\n",g_n,g_fail);
    return g_fail!=0;
}
