static int test_clear_texture_int_gpu(void) {
    enum { SIZE=65536, OUTPUT=16384, COMMANDS=32768 };
    uint8_t *memory=aligned_alloc(16384,SIZE);if(!memory)return 1;memset(memory,0,SIZE);
    NVNmemoryPoolBuilder pb;NVNmemoryPool pool;
    P(nvnMemoryPoolBuilderSetDevice)(&pb,&dev);P(nvnMemoryPoolBuilderSetDefaults)(&pb);
    P(nvnMemoryPoolBuilderSetStorage)(&pb,memory,SIZE);P(nvnMemoryPoolBuilderSetFlags)(&pb,0x22);
    EXPECT("signed-clear pool initializes",1,P(nvnMemoryPoolInitialize)(&pool,&pb));
    NVNqueueBuilder qb={0};NVNqueue queue;
    P(nvnQueueBuilderSetDevice)(&qb,&dev);P(nvnQueueBuilderSetDefaults)(&qb);P(nvnQueueInitialize)(&queue,&qb);
    NVNcommandBuffer cb;P(nvnCommandBufferInitialize)(&cb,&dev);P(nvnCommandBufferAddCommandMemory)(&cb,&pool,COMMANDS,16384);
    const NVNformat formats[]={NVN_FORMAT_R32I,NVN_FORMAT_RGBA8I,NVN_FORMAT_RGBA32I};
    for(unsigned f=0;f<3;f++) {
        NVNtextureBuilder tb;NVNtexture texture;
        P(nvnTextureBuilderSetDevice)(&tb,&dev);P(nvnTextureBuilderSetDefaults)(&tb);
        P(nvnTextureBuilderSetTarget)(&tb,NVN_TEXTURE_TARGET_2D);P(nvnTextureBuilderSetSize2D)(&tb,7,3);
        P(nvnTextureBuilderSetFormat)(&tb,formats[f]);P(nvnTextureBuilderSetFlags)(&tb,NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET);
        P(nvnTextureBuilderSetStride)(&tb,128);P(nvnTextureBuilderSetStorage)(&tb,&pool,0);
        EXPECT("signed-clear texture initializes",1,P(nvnTextureInitialize)(&texture,&tb));
        int values[4]={INT32_MIN,123,INT32_MAX,-42};uint8_t pixel[16];int bpp=f==2?16:4;
        if(f==0)values[0]=-1234567;
        if(f==1){values[0]=-17;values[1]=32;values[2]=-47;values[3]=125;for(int i=0;i<4;i++)pixel[i]=(uint8_t)(int8_t)values[i];}
        else memcpy(pixel,values,bpp);
        memset(memory+OUTPUT-4,0xa7,1028);NVNcopyRegion region={0,0,0,7,3,1};
        P(nvnCommandBufferBeginRecording)(&cb);
        P(nvnCommandBufferClearTexturei)(&cb,&texture,NULL,&region,values,0xf);memset(values,0,sizeof values);
        P(nvnCommandBufferSetCopyRowStride)(&cb,256);P(nvnCommandBufferSetCopyImageStride)(&cb,0);
        P(nvnCommandBufferCopyTextureToBuffer)(&cb,&texture,NULL,&region,(uintptr_t)(memory+OUTPUT),0);
        NVNcommandHandle handle=P(nvnCommandBufferEndRecording)(&cb);
        P(nvnQueueSubmitCommands)(&queue,1,&handle);P(nvnQueueFinish)(&queue);
        int bad=0,padding=0;
        for(int i=0;i<1024;i++){
            int y=i/256,x=i%256,active=y<3&&x<7*bpp;
            if(memory[OUTPUT+i]!=(active?pixel[x%bpp]:0xa7)){if(active)bad++;else padding++;}
        }
        EXPECT("signed clear retains negative/extreme components",0,bad);
        EXPECT("signed clear readback padding guards",0,padding);
        EXPECT("signed clear readback prefix guard",0xa7a7a7a7,*(uint32_t *)(memory+OUTPUT-4));
        P(nvnTextureFinalize)(&texture);
    }
    mtl_drain();P(nvnCommandBufferFinalize)(&cb);P(nvnQueueFinalize)(&queue);P(nvnMemoryPoolFinalize)(&pool);free(memory);
    printf("SIGNED TEXTURE CLEAR GPU: %d checks, %d failures\n",g_n,g_fail);return g_fail!=0;
}
