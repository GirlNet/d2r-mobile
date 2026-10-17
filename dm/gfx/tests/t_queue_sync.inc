static void test_queue_sync_objects(void) {
    NVNqueueBuilder builder = {0}; NVNqueue queue, other;
    P(nvnQueueBuilderSetDevice)(&builder, &dev); P(nvnQueueBuilderSetDefaults)(&builder);
    P(nvnQueueInitialize)(&queue, &builder); P(nvnQueueInitialize)(&other, &builder);
    NVNsync sync; P(nvnSyncInitialize)(&sync, &dev);
    EXPECT("unfenced queue wait rejected", 0, P(nvnQueueWaitSync)(&queue, &sync));
    EXPECT("null queue wait rejected", 0, P(nvnQueueWaitSync)(NULL, &sync));
    EXPECT("null sync wait rejected", 0, P(nvnQueueWaitSync)(&queue, NULL));
    P(nvnQueueFenceSync)(&queue, &sync, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    EXPECT("empty-queue fence is satisfied", 1, P(nvnQueueWaitSync)(&other, &sync));
    ((queue_t *)&other)->dev = NULL;
    EXPECT("cross-device queue wait rejected", 0, P(nvnQueueWaitSync)(&other, &sync));
    ((sync_t *)&sync)->fence = UINT64_MAX;
    EXPECT("future fence rejected", 0, P(nvnQueueWaitSync)(&queue, &sync));
    P(nvnSyncFinalize)(&sync);
    EXPECT("finalized sync wait rejected", 0, P(nvnQueueWaitSync)(&queue, &sync));
    P(nvnQueueFinalize)(&queue);
    EXPECT("finalized queue wait rejected", 0, P(nvnQueueWaitSync)(&queue, &sync));
    P(nvnQueueFinalize)(&other);
}

static int test_queue_sync_gpu(void) {
    enum { SIZE = 32768, N = 1024 };
    uint8_t *memory = NULL;
    if (posix_memalign((void **)&memory, 16384, SIZE)) return 1;
    memset(memory, 0, SIZE);
    for (int i = 0; i < N; i++) memory[i] = (uint8_t)(i * 37 + 11);
    NVNmemoryPoolBuilder pb = {0}; NVNmemoryPool pool;
    P(nvnMemoryPoolBuilderSetDevice)(&pb, &dev); P(nvnMemoryPoolBuilderSetDefaults)(&pb);
    P(nvnMemoryPoolBuilderSetStorage)(&pb, memory, SIZE); P(nvnMemoryPoolBuilderSetFlags)(&pb, 0x22);
    if (!P(nvnMemoryPoolInitialize)(&pool, &pb)) return 1;
    NVNqueueBuilder qb = {0}; NVNqueue producer, consumer;
    P(nvnQueueBuilderSetDevice)(&qb, &dev); P(nvnQueueBuilderSetDefaults)(&qb);
    P(nvnQueueInitialize)(&producer, &qb); P(nvnQueueInitialize)(&consumer, &qb);
    NVNcommandBuffer cb; P(nvnCommandBufferInitialize)(&cb, &dev);
    P(nvnCommandBufferAddCommandMemory)(&cb, &pool, 16384, 16384);
    NVNsync ready, finished; P(nvnSyncInitialize)(&ready, &dev); P(nvnSyncInitialize)(&finished, &dev);
    P(nvnCommandBufferBeginRecording)(&cb);
    P(nvnCommandBufferCopyBufferToBuffer)(&cb, (uintptr_t)memory, (uintptr_t)(memory + 4096), N, 0);
    NVNcommandHandle first = P(nvnCommandBufferEndRecording)(&cb);
    P(nvnQueueSubmitCommands)(&producer, 1, &first);
    P(nvnQueueFenceSync)(&producer, &ready, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    EXPECT("GPU queue wait accepted", 1, P(nvnQueueWaitSync)(&consumer, &ready));
    P(nvnCommandBufferBeginRecording)(&cb);
    P(nvnCommandBufferCopyBufferToBuffer)(&cb, (uintptr_t)(memory + 4096), (uintptr_t)(memory + 8192), N, 0);
    NVNcommandHandle second = P(nvnCommandBufferEndRecording)(&cb);
    P(nvnQueueSubmitCommands)(&consumer, 1, &second);
    P(nvnQueueFenceSync)(&consumer, &finished, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    int wait = P(nvnSyncWait)(&finished, 5000000000ull);
    EXPECT("consumer GPU completion", 1, wait == NVN_SYNC_WAIT_RESULT_ALREADY_SIGNALED || wait == NVN_SYNC_WAIT_RESULT_CONDITION_SATISFIED);
    EXPECT("GPU dependency preserved copy bytes", 0, memcmp(memory, memory + 8192, N));
    EXPECT("GPU copy guard bytes", 0, memory[8191] | memory[8192 + N]);
    mtl_drain();
    P(nvnCommandBufferFinalize)(&cb); P(nvnSyncFinalize)(&ready); P(nvnSyncFinalize)(&finished);
    P(nvnQueueFinalize)(&producer); P(nvnQueueFinalize)(&consumer);
    P(nvnMemoryPoolFinalize)(&pool); free(memory);
    printf("QUEUE SYNC GPU: %d checks, %d failures; producer/wait/consumer ordering\n", g_n, g_fail);
    return g_fail != 0;
}
