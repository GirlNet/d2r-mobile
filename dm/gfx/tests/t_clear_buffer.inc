static int test_clear_buffer_gpu(void) {
    enum { SIZE=1048576, DEST=262144, COMMANDS=786432 };
    uint8_t *memory=aligned_alloc(16384,SIZE);if(!memory)return 1;memset(memory,0x53,SIZE);
    NVNmemoryPoolBuilder pb;NVNmemoryPool pool;
    P(nvnMemoryPoolBuilderSetDevice)(&pb,&dev);P(nvnMemoryPoolBuilderSetDefaults)(&pb);
    P(nvnMemoryPoolBuilderSetStorage)(&pb,memory,SIZE);P(nvnMemoryPoolBuilderSetFlags)(&pb,0x22);
    EXPECT("clear pool initializes",1,P(nvnMemoryPoolInitialize)(&pool,&pb));
    NVNqueueBuilder qb={0};NVNqueue queue;
    P(nvnQueueBuilderSetDevice)(&qb,&dev);P(nvnQueueBuilderSetDefaults)(&qb);P(nvnQueueInitialize)(&queue,&qb);
    NVNcommandBuffer cb;P(nvnCommandBufferInitialize)(&cb,&dev);P(nvnCommandBufferAddCommandMemory)(&cb,&pool,COMMANDS,65536);
    const size_t sizes[]={4,65532,65536,65540,200004};
    for(unsigned c=0;c<sizeof sizes/sizeof *sizes;c++) {
        size_t n=sizes[c];memset(memory,0x53,n+8);memset(memory+DEST,0x53,n+8);
        P(nvnCommandBufferBeginRecording)(&cb);
        P(nvnCommandBufferClearBuffer)(&cb,0,0,0); // no resource access for an empty clear
        P(nvnCommandBufferClearBuffer)(&cb,(uintptr_t)(memory+4),n,0x11223344);
        P(nvnCommandBufferCopyBufferToBuffer)(&cb,(uintptr_t)(memory+4),(uintptr_t)(memory+DEST+4),n,0);
        P(nvnCommandBufferClearBuffer)(&cb,(uintptr_t)(memory+4),n,0xa1b2c3d4);
        NVNcommandHandle handle=P(nvnCommandBufferEndRecording)(&cb);
        EXPECT("clear recording leaves CPU data unchanged",0x53535353,*(uint32_t *)(memory+4));
        P(nvnQueueSubmitCommands)(&queue,1,&handle);P(nvnQueueFinish)(&queue);
        int source_bad=0,destination_bad=0;
        for(size_t i=0;i<n/4;i++) {
            source_bad+=((uint32_t *)(memory+4))[i]!=0xa1b2c3d4;
            destination_bad+=((uint32_t *)(memory+DEST+4))[i]!=0x11223344;
        }
        EXPECT("GPU clear writes every 32-bit pattern word",0,source_bad);
        EXPECT("GPU clear/copy/clear ordering",0,destination_bad);
        EXPECT("GPU clear source prefix guard",0x53535353,*(uint32_t *)memory);
        EXPECT("GPU clear source suffix guard",0x53535353,*(uint32_t *)(memory+4+n));
        EXPECT("GPU clear destination prefix guard",0x53535353,*(uint32_t *)(memory+DEST));
        EXPECT("GPU clear destination suffix guard",0x53535353,*(uint32_t *)(memory+DEST+4+n));
    }
    mtl_drain();P(nvnCommandBufferFinalize)(&cb);P(nvnQueueFinalize)(&queue);P(nvnMemoryPoolFinalize)(&pool);free(memory);
    printf("CLEAR BUFFER GPU: %d checks, %d failures\n",g_n,g_fail);return g_fail!=0;
}
