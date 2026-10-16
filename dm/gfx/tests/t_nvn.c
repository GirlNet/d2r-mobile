// NVN 空设备单测：照游戏的用法从 nvnBootstrapLoader 取址，一路走到出图；期望值全部手算，不调被测实现。
// 编译运行见 dm/gfx/tests/Makefile（make -C dm/gfx/tests）。
// NVN null device unit tests: look up addresses from nvnBootstrapLoader the way the game does and go all the way to present; all expected values are hand-calculated, without calling the implementation under test.
// For build and run see dm/gfx/tests/Makefile (make -C dm/gfx/tests).
#include "../nvn/hle_nvn.c"
uint64_t g_t0_ns;   // 宿主 main.c 的进程起点（hle_nvn 逐帧 @t_s 用），单测替身 | process start time from host main.c (used by hle_nvn's per-frame @t_s); unit test stub
#include "../tex/nvn_deswizzle.h"
#include <time.h>
void *front_metal_layer(void) { return NULL; }   // 单测无窗口：出图只计数 | no window in unit tests: present only counts
module_t *module_of(const void *p) { (void)p; return NULL; }   // 单测无客体模块 | no guest modules in unit tests
module_t g_mod[MAX_MOD]; int g_nmod;                            // crash.c 依赖的宿主符号 | host symbols that crash.c depends on
void svc_thread_dump(void) {}
void crash_install(void);
void nvn_present_config(int hz, int display_mode);
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }

static int g_fail, g_n;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); g_n++;                 \
    printf("%-44s 期望 %-12lld → 真结果 %-12lld %s\n", name, w_, g_, w_ == g_ ? "✓" : "✗"); if (w_ != g_) g_fail++; } while (0)

#define P(name) ((NVNT_##name)proc(#name))
static PFNNVNDEVICEGETPROCADDRESSPROC gpa; static NVNdevice dev;
static void *proc(const char *n) { void *p = (void *)gpa(&dev, n); if (!p) { printf("取址失败 %s\n", n); exit(1); } return p; }

// 命令内存回调：每次给一段 256 字节的新内存（强制多段 JUMP 链）
// Command memory callback: hands out a new 256-byte memory segment each time (forces a multi-segment JUMP chain)
static uint8_t g_cmdmem[64 * 1024]; static size_t g_cmdoff; static int g_cb_calls; static NVNmemoryPool g_cmdpool;
static void mem_cb(NVNcommandBuffer *c, NVNcommandBufferMemoryEvent ev, size_t minsz, void *data) {
    (void)data; g_cb_calls++;
    if (ev != NVN_COMMAND_BUFFER_MEMORY_EVENT_OUT_OF_COMMAND_MEMORY) return;
    size_t n = minsz > 256 ? minsz : 256;
    P(nvnCommandBufferAddCommandMemory)(c, &g_cmdpool, (ptrdiff_t)g_cmdoff, n); g_cmdoff += n;
}

// 挂起单测：另一线程里做提交
// Suspend unit test: do the submit on another thread
static _Atomic int g_sstarted, g_sdone; static pthread_mutex_t g_smu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_scv = PTHREAD_COND_INITIALIZER;
static NVNqueue *g_sq; static NVNcommandHandle g_sh; static NVNT_nvnQueueSubmitCommands g_sub;
static void *susp_thr(void *a) { (void)a; pthread_mutex_lock(&g_smu); atomic_store(&g_sstarted, 1); pthread_cond_broadcast(&g_scv); pthread_mutex_unlock(&g_smu); g_sub(g_sq, 1, &g_sh); atomic_store(&g_sdone, 1); return NULL; }
static int wait_started(void) { struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl); dl.tv_sec += 10; pthread_mutex_lock(&g_smu); while (!atomic_load(&g_sstarted) && pthread_cond_timedwait(&g_scv, &g_smu, &dl) == 0) {} int ok = atomic_load(&g_sstarted); pthread_mutex_unlock(&g_smu); return ok; }

static size_t tex_size(int fmt, int w, int h, int flags, size_t *align) {
    NVNtextureBuilder tb;
    P(nvnTextureBuilderSetDevice)(&tb, &dev); P(nvnTextureBuilderSetDefaults)(&tb);
    P(nvnTextureBuilderSetFlags)(&tb, flags); P(nvnTextureBuilderSetTarget)(&tb, NVN_TEXTURE_TARGET_2D);
    P(nvnTextureBuilderSetWidth)(&tb, w); P(nvnTextureBuilderSetHeight)(&tb, h); P(nvnTextureBuilderSetFormat)(&tb, fmt);
    if (align) *align = P(nvnTextureBuilderGetStorageAlignment)(&tb);
    return P(nvnTextureBuilderGetStorageSize)(&tb);
}

// 注册表的生命周期、边界与并发检查；全部通过生产取址接口和跳板，不创建 GPU。
// Check registry lifecycle, bounds and concurrency through production lookup and thunks, without creating a GPU.
static _Atomic unsigned g_clear_errors;
static void *clear_register_thread(void *arg) {
    NVNdevice *d=arg; const float color[4]={0,0,0,0};
    for (int i=0;i<1000;i++) {
        if (!P(nvnDeviceRegisterFastClearColor)(d,color,NVN_FORMAT_RGBA8)) atomic_fetch_add(&g_clear_errors,1);
        if (!P(nvnDeviceRegisterFastClearDepth)(d,1.0f)) atomic_fetch_add(&g_clear_errors,1);
    }
    return NULL;
}
static void test_fast_clear_registry(const NVNdeviceBuilder *db) {
    struct { uint64_t before; NVNdevice device; uint64_t after; } guarded={.before=0x11223344,.after=0x55667788};
    NVNdevice *d=&guarded.device, other={0}; const float zero[4]={0,0,0,0};
    EXPECT("未初始化设备拒绝 / reject uninitialized device",0,P(nvnDeviceRegisterFastClearColor)(d,zero,NVN_FORMAT_RGBA8));
    EXPECT("独立设备初始化 / initialize separate device",1,P(nvnDeviceInitialize)(d,db));
    fast_clear_t *f=&((dev_t_ *)d)->fast_clear;
    EXPECT("初始化清空注册 / initialized registry empty",0,f->color_count+f->depth_count);
    EXPECT("游戏使用的零色注册 / guest zero color registration",1,P(nvnDeviceRegisterFastClearColor)(d,zero,NVN_FORMAT_RGBA8));
    EXPECT("游戏使用的深度一注册 / guest depth one registration",1,P(nvnDeviceRegisterFastClearDepth)(d,1.0f));
    EXPECT("重复颜色成功 / duplicate color succeeds",1,P(nvnDeviceRegisterFastClearColor)(d,zero,NVN_FORMAT_RGBA8));
    EXPECT("重复深度成功 / duplicate depth succeeds",1,P(nvnDeviceRegisterFastClearDepth)(d,1.0f));
    EXPECT("重复项不增加记录 / duplicates reuse entries",1,f->color_count==1 && f->depth_count==1);
    EXPECT("不同格式另记 / distinct format entry",1,P(nvnDeviceRegisterFastClearColor)(d,zero,NVN_FORMAT_RGBA8_SRGB));
    const uint32_t izero[4]={0,0,0,0};
    EXPECT("相同位的不同类型另记 / distinct argument type entry",1,P(nvnDeviceRegisterFastClearColorui)(d,izero,NVN_FORMAT_RGBA8));
    EXPECT("格式和类型键隔离 / format and type keys isolated",3,f->color_count);
    NVNdevice snapshot=*d;
    EXPECT("空设备拒绝 / reject null device",0,P(nvnDeviceRegisterFastClearColor)(NULL,zero,NVN_FORMAT_RGBA8));
    EXPECT("空颜色拒绝 / reject null color",0,P(nvnDeviceRegisterFastClearColor)(d,NULL,NVN_FORMAT_RGBA8));
    EXPECT("无格式拒绝 / reject absent format",0,P(nvnDeviceRegisterFastClearColor)(d,zero,NVN_FORMAT_NONE));
    EXPECT("未知格式拒绝 / reject unknown format",0,P(nvnDeviceRegisterFastClearColor)(d,zero,(NVNformat)0x7fffffff));
    EXPECT("深度格式不作颜色 / reject depth color format",0,P(nvnDeviceRegisterFastClearColor)(d,zero,NVN_FORMAT_DEPTH32F));
    EXPECT("块压缩颜色拒绝 / reject block-compressed color",0,P(nvnDeviceRegisterFastClearColor)(d,zero,NVN_FORMAT_RGBA_DXT1));
    EXPECT("负深度拒绝 / reject negative depth",0,P(nvnDeviceRegisterFastClearDepth)(d,-0.1f));
    EXPECT("过大深度拒绝 / reject depth above one",0,P(nvnDeviceRegisterFastClearDepth)(d,1.1f));
    uint32_t nanbits=0x7fc00000;float nan;memcpy(&nan,&nanbits,4);
    EXPECT("NaN 深度拒绝 / reject NaN depth",0,P(nvnDeviceRegisterFastClearDepth)(d,nan));
    EXPECT("无效输入不改变记录 / invalid inputs preserve registry",0,memcmp(&snapshot,d,sizeof snapshot));
    P(nvnDeviceInitialize)(d,db);
    int all=1;
    for (int i=0;i<64;i++) { float c[4]={(float)i,0,0,1}; all &= P(nvnDeviceRegisterFastClearColor)(d,c,NVN_FORMAT_RGBA8)!=0; }
    EXPECT("64 个不同颜色成功 / 64 distinct colors",1,all && f->color_count==64);
    snapshot=*d; const float extra[4]={1000,0,0,1};
    EXPECT("颜色满表拒绝 / full color table rejects new entry",0,P(nvnDeviceRegisterFastClearColor)(d,extra,NVN_FORMAT_RGBA8));
    EXPECT("满表无副作用 / full table unchanged",0,memcmp(&snapshot,d,sizeof snapshot));
    const float first[4]={0,0,0,1};
    EXPECT("颜色满表仍复用 / reuse duplicate in full color table",1,P(nvnDeviceRegisterFastClearColor)(d,first,NVN_FORMAT_RGBA8));
    all=1;for (int i=0;i<16;i++) all &= P(nvnDeviceRegisterFastClearDepth)(d,(float)i/32)!=0;
    EXPECT("16 个不同深度成功 / 16 distinct depths",1,all && f->depth_count==16);
    snapshot=*d;
    EXPECT("深度满表拒绝 / full depth table rejects new entry",0,P(nvnDeviceRegisterFastClearDepth)(d,1.0f));
    EXPECT("深度满表仍复用 / reuse duplicate in full depth table",1,P(nvnDeviceRegisterFastClearDepth)(d,0.0f));
    EXPECT("深度满表无副作用 / full depth table unchanged",0,memcmp(&snapshot,d,sizeof snapshot));
    P(nvnDeviceInitialize)(&other,db);
    EXPECT("设备间隔离 / device isolation",0,((dev_t_ *)&other)->fast_clear.color_count+((dev_t_ *)&other)->fast_clear.depth_count);
    P(nvnDeviceFinalize)(d);
    EXPECT("销毁释放记录 / finalize clears registrations",0,((dev_t_ *)d)->magic+f->color_count+f->depth_count);
    EXPECT("销毁设备拒绝注册 / finalized device rejects registration",0,P(nvnDeviceRegisterFastClearDepth)(d,1.0f));
    P(nvnDeviceInitialize)(d,db);
    EXPECT("重建设备清空 / rebuilt device empty",0,f->color_count+f->depth_count);
    pthread_t th[8];int started=0;for (;started<8;started++) if (pthread_create(&th[started],NULL,clear_register_thread,d)) break;
    for (int i=0;i<started;i++) pthread_join(th[i],NULL);
    EXPECT("八线程注册无失败 / eight-thread registration succeeds",1,started==8 && atomic_load(&g_clear_errors)==0);
    EXPECT("并发重复项唯一 / concurrent duplicate entries unique",1,f->color_count==1 && f->depth_count==1);
    EXPECT("设备对象前后边界 / device object bounds",1,guarded.before==0x11223344 && guarded.after==0x55667788);
    // 注册不替换清除载荷；录制时复制颜色，调用方之后修改不会污染命令。
    // Registration does not replace clear payloads; recording copies colors so later caller mutations cannot corrupt commands.
    NVNcommandBuffer cb;uint8_t bytes[256] __attribute__((aligned(8)));float c[4]={0.25f,0.5f,0.75f,1};
    P(nvnCommandBufferInitialize)(&cb,d);CB(&cb)->cur=bytes;CB(&cb)->end=bytes+sizeof bytes;
    P(nvnCommandBufferBeginRecording)(&cb);P(nvnCommandBufferClearColor)(&cb,0,c,15);P(nvnCommandBufferClearDepthStencil)(&cb,1.0f,1,0,0);
    NVNcommandHandle h=P(nvnCommandBufferEndRecording)(&cb);c[0]=100;
    op_hdr header;memcpy(&header,bytes+8,8);const p_clear_color *pc=(const p_clear_color *)(bytes+16);
    EXPECT("普通清色载荷不变 / ordinary clear color payload intact",1,h==(NVNcommandHandle)bytes && header.op==OP_CLEAR_COLOR && pc->index==0 && pc->mask==15 && pc->rgba[0]==0.25f && pc->rgba[3]==1);
    const uint8_t *next=bytes+8+header.size;memcpy(&header,next,8);const p_clear_ds *pd=(const p_clear_ds *)(next+8);
    EXPECT("普通清深度载荷不变 / ordinary depth clear payload intact",1,header.op==OP_CLEAR_DS && pd->depth==1.0f && pd->depth_mask==1);
    P(nvnDeviceFinalize)(d);P(nvnDeviceFinalize)(&other);
}

#ifdef DM_P5R_ONLY
// 实际后端设置结束后线程必须留在生产停止边界；启用 UDC 开关也不能越过该边界。
// After real backend setup the thread must remain at the production stop boundary, even with the UDC self-test switch enabled.
static _Atomic int setupEscaped, setupContinued;
static void *realSetup(void *preSubmit) { mtl_init(); if (preSubmit) { atomic_store(&setupContinued,1); mtl_drain(); } atomic_store(&setupEscaped,1); return NULL; }
static int realSetupProbe(const char *directory, int preSubmit) {
    if (!(preSubmit ? dm_boot_probe_begin_pre_submit(directory) : dm_boot_probe_begin_gpu_setup(directory)) || !dm_boot_probe_checkpoint("nnMain",0)) return 1;
    setenv("DM_UDC_SELFTEST","1",1);
    pthread_t thread; if (pthread_create(&thread,NULL,realSetup,(void *)(uintptr_t)preSubmit)) return 1; pthread_detach(thread);
    char path[2048], data[32768]; snprintf(path,sizeof path,"%s/boot-report.json",directory);
    for (int i=0;i<4000;i++) {
        usleep(10000); FILE *f=fopen(path,"rb"); if (!f) continue;
        size_t n=fread(data,1,sizeof data-1,f); fclose(f); data[n]=0;
        if (strstr(data,preSubmit ? "blocked_before_unverified_operation" : "stopped_after_gpu_initialization")) {
            if (atomic_load(&setupEscaped) || (preSubmit && !atomic_load(&setupContinued))) return 1;
            puts(preSubmit ? "REAL METAL PRE-SUBMIT OK: setup returned; production mtl_drain commit blocked" : "REAL METAL SETUP OK: backend objects initialized; owner parked before returning to guest"); return 0;
        }
        if (strstr(data,"failure_reason") || strstr(data,"process_exit_requested")) return 1;
    }
    return 1;
}
#endif

int main(int argc, char **argv) {
#ifdef DM_P5R_ONLY
    if (argc==3 && !strcmp(argv[1],"--gpu-setup-probe")) return realSetupProbe(argv[2],0);
    if (argc==3 && !strcmp(argv[1],"--pre-submit-probe")) return realSetupProbe(argv[2],1);
#endif
    crash_install();   // 生产同一套 SIGSEGV / SIGBUS 处理（缺页钩子在其中分发） | the same SIGSEGV / SIGBUS handling as production (the page-fault hook is dispatched from within it)
    // 1. 引导取址：bootstrap 取 GetProcAddress，再用它取全部名字
    // 1. Bootstrap address lookup: bootstrap gets GetProcAddress, then uses it to get all the names
    PFNNVNBOOTSTRAPLOADERPROC boot = (PFNNVNBOOTSTRAPLOADERPROC)h_nvnBootstrapLoader;
    gpa = (PFNNVNDEVICEGETPROCADDRESSPROC)boot("nvnDeviceGetProcAddress");
    EXPECT("bootstrap 取 GetProcAddress 非空", 1, gpa != NULL);
    int nonnull = 0; for (unsigned i = 0; i < NVN_NFUNC; i++) nonnull += gpa(NULL, nvn_names[i]) != NULL;
    EXPECT("全部登记名字取到地址 / registered names", NVN_NFUNC, nonnull);
    EXPECT("未知名字取址返回空", 0, gpa(NULL, "nvnNoSuchFunction") != NULL);

    // 2. 设备
    // 2. Device
    NVNdeviceBuilder db; P(nvnDeviceBuilderSetDefaults)(&db); P(nvnDeviceBuilderSetFlags)(&db, 0);
    EXPECT("DeviceInitialize 成功", 1, P(nvnDeviceInitialize)(&dev, &db));
    int v; P(nvnDeviceGetInteger)(&dev, NVN_DEVICE_INFO_UNIFORM_BUFFER_ALIGNMENT, &v);
    EXPECT("uniform 缓冲对齐（X1 实测 256）", 256, v);
    P(nvnDeviceGetInteger)(&dev, NVN_DEVICE_INFO_TEXTURE_DESCRIPTOR_SIZE, &v); EXPECT("贴图描述符大小（32）", 32, v);
    P(nvnDeviceGetInteger)(&dev, NVN_DEVICE_INFO_QUEUE_COMMAND_MEMORY_MIN_SIZE, &v); EXPECT("队列命令内存下限（65536）", 65536, v);

    // 只运行启动接口时也走真实静态跳板；未验证的新名字必须仍接具名阻塞桩。
    // Bootstrap-only checks also use real static thunks; unverified new names must retain named blocking stubs.
    NVNdevice snapshot = dev;
    const float fc[4] = {0.0f, 0.25f, 1.0f, -1.0f};
    const int ic[4] = {-1, 0, 1, INT32_MAX};
    const uint32_t uc[4] = {0, 1, UINT32_MAX, 0x80000000u};
    EXPECT("快速清除浮点注册 / float registration", 1, P(nvnDeviceRegisterFastClearColor)(&dev, fc, NVN_FORMAT_RGBA8));
    EXPECT("快速清除有符号注册 / int registration", 1, P(nvnDeviceRegisterFastClearColori)(&dev, ic, NVN_FORMAT_RGBA8I));
    EXPECT("快速清除无符号注册 / uint registration", 1, P(nvnDeviceRegisterFastClearColorui)(&dev, uc, NVN_FORMAT_RGBA8UI));
    EXPECT("快速清除深度注册 / depth registration", 1, P(nvnDeviceRegisterFastClearDepth)(&dev, 0.5f));
    EXPECT("设备原字段不变 / existing device fields unchanged", 0, memcmp(&dev, &snapshot, offsetof(dev_t_,fast_clear)));
    EXPECT("已有跳板计数保留 / original thunk counter", 1, atomic_load(&nvn_slot[17].cnt));
    EXPECT("已有名字序号保留 / original name index", 0, strcmp(nvn_names[17], "nvnDeviceRegisterFastClearColor"));
    const fast_clear_t *f = &((dev_t_ *)&dev)->fast_clear;
    EXPECT("颜色计数 / color count", 3, f->color_count);
    EXPECT("深度计数 / depth count", 1, f->depth_count);
    EXPECT("浮点原始位 / raw float bits", 0, memcmp(f->colors[0].bits,fc,16));
    EXPECT("有符号原始位 / raw signed bits", 0, memcmp(f->colors[1].bits,ic,16));
    EXPECT("无符号原始位 / raw unsigned bits", 0, memcmp(f->colors[2].bits,uc,16));
    EXPECT("参数类型与格式 / argument kind and format", 1, f->colors[0].kind==0 && f->colors[1].kind==1 && f->colors[2].kind==2 && f->colors[0].format==NVN_FORMAT_RGBA8 && f->colors[1].format==NVN_FORMAT_RGBA8I && f->colors[2].format==NVN_FORMAT_RGBA8UI);
    EXPECT("深度原始位 / depth bits", 0x3f000000, f->depths[0]);
    test_fast_clear_registry(&db);
    int named = 0;
    for (unsigned i = 523; i < NVN_NFUNC; i++) {
        named += nvn_slot[i].fn == (void *)nvn_unimpl_entry && (void *)gpa(&dev,nvn_names[i]) == nvn_thunk[i];
        for (unsigned j = 0; j < i; j++) if (!strcmp(nvn_names[i],nvn_names[j])) named = -100;
    }
    EXPECT("11 个新接口仍为具名桩 / 11 named unimplemented interfaces", 11, named);
    if (argc == 2 && !strcmp(argv[1], "--bootstrap-only")) {
        printf("NVN BOOTSTRAP: %d checks, %d failures; no GPU work\n", g_n, g_fail);
        return g_fail ? 1 : 0;
    }

    // 3. 内存池：GPU 地址 = 游戏给的存储地址
    // 3. Memory pool: GPU address = the storage address given by the game
    static uint8_t poolmem[1 << 20] __attribute__((aligned(4096)));
    NVNmemoryPoolBuilder pb; NVNmemoryPool pool;
    P(nvnMemoryPoolBuilderSetDevice)(&pb, &dev); P(nvnMemoryPoolBuilderSetDefaults)(&pb);
    P(nvnMemoryPoolBuilderSetStorage)(&pb, poolmem, sizeof poolmem); P(nvnMemoryPoolBuilderSetFlags)(&pb, 0x24);
    EXPECT("MemoryPoolInitialize 成功", 1, P(nvnMemoryPoolInitialize)(&pool, &pb));
    EXPECT("池 GPU 地址 = 存储地址", (long long)(uintptr_t)poolmem, P(nvnMemoryPoolGetBufferAddress)(&pool));

    // 4. 贴图存储尺寸（块线性：GOB = 64 B × 8 行；块高按「高×1.5」取 GOB 数 ≥16→16、≥8→8 …）
    //    256×256 RGBA8：每行 1024 B = 16 GOB；高 256 行 = 32 GOB 行，块高 16 GOB → 2 块；16×2×(512×16) = 262144
    // 4. Texture storage size (block-linear: GOB = 64 B × 8 rows; block height from the GOB count of "height × 1.5": ≥16→16, ≥8→8 ...)
    //    256×256 RGBA8: 1024 B per row = 16 GOBs; height 256 rows = 32 GOB rows, block height 16 GOBs → 2 blocks; 16×2×(512×16) = 262144
    size_t al; EXPECT("256x256 RGBA8 尺寸", 262144, tex_size(NVN_FORMAT_RGBA8, 256, 256, 0, &al));
    EXPECT("块线性对齐", 512, al);
    //    100×100 RGBA8：400 B → 7 GOB 宽；高 100 → 13 GOB 行，1.5 倍 = 150 行 = 19 GOB → 块高 16 → 1 块；7×1×8192 = 57344
    //    100×100 RGBA8: 400 B → 7 GOBs wide; height 100 → 13 GOB rows, ×1.5 = 150 rows = 19 GOBs → block height 16 → 1 block; 7×1×8192 = 57344
    EXPECT("100x100 RGBA8 尺寸", 57344, tex_size(NVN_FORMAT_RGBA8, 100, 100, 0, NULL));
    //    128×128 DXT1：32×32 块、8 B/块 → 256 B = 4 GOB 宽；32 行 → 1.5 倍 48 行 = 6 GOB → 块高 4 → 4 GOB 行 = 1 块；4×1×2048 = 8192
    //    128×128 DXT1: 32×32 blocks, 8 B/block → 256 B = 4 GOBs wide; 32 rows → ×1.5 = 48 rows = 6 GOBs → block height 4 → 4 GOB rows = 1 block; 4×1×2048 = 8192
    EXPECT("128x128 DXT1 尺寸", 8192, tex_size(NVN_FORMAT_RGBA_DXT1, 128, 128, 0, NULL));
    //    LINEAR 100×100 RGBA8：行距 400 按 32 对齐 = 416；416×100 = 41600，对齐 32
    //    LINEAR 100×100 RGBA8: row pitch 400 aligned to 32 = 416; 416×100 = 41600, aligned to 32
    EXPECT("线性 100x100 RGBA8 尺寸", 41600, tex_size(NVN_FORMAT_RGBA8, 100, 100, NVN_TEXTURE_FLAGS_LINEAR, &al));
    EXPECT("线性对齐", 32, al);

    // 5. 命令缓冲：录 uniform 更新 / 事件 / 计数器 / 缓冲拷贝 / 嵌套调用，内存 256 B 一段逼出多段链接
    // 5. Command buffer: record uniform updates / events / counters / buffer copies / nested calls, with memory in 256 B segments to force multi-segment linking
    NVNcommandBuffer cb; P(nvnCommandBufferInitialize)(&cb, &dev);
    NVNmemoryPoolBuilder cpb; P(nvnMemoryPoolBuilderSetDefaults)(&cpb); P(nvnMemoryPoolBuilderSetStorage)(&cpb, g_cmdmem, sizeof g_cmdmem);
    P(nvnMemoryPoolInitialize)(&g_cmdpool, &cpb);
    P(nvnCommandBufferSetMemoryCallback)(&cb, mem_cb); P(nvnCommandBufferSetMemoryCallbackData)(&cb, NULL);
    NVNeventBuilder eb; NVNevent ev; P(nvnEventBuilderSetDefaults)(&eb); P(nvnEventBuilderSetStorage)(&eb, &pool, 0x1000);
    P(nvnEventInitialize)(&ev, &eb);
    uint8_t *ub = poolmem + 0x2000, *cnt = poolmem + 0x3000, *src = poolmem + 0x4000, *dst = poolmem + 0x5000;
    for (int i = 0; i < 64; i++) src[i] = (uint8_t)(i * 3 + 1);
    uint32_t data[16];

    P(nvnCommandBufferBeginRecording)(&cb);
    EXPECT("录制中", 1, P(nvnCommandBufferIsRecording)(&cb));
    for (int k = 0; k < 20; k++) {                        // 20 次更新同一缓冲不同偏移，每次 64 B 数据 | 20 updates to different offsets of the same buffer, 64 B of data each
        for (int i = 0; i < 16; i++) data[i] = k * 100 + i;
        P(nvnCommandBufferUpdateUniformBuffer)(&cb, (NVNbufferAddress)ub, 4096, k * 64, 64, data);
        memset(data, 0xEE, sizeof data);                  // 录完改原数据：提交时必须用录制时拷进去的值 | modify the original data after recording: the submit must use the values copied in at record time
    }
    P(nvnCommandBufferSignalEvent)(&cb, &ev, NVN_EVENT_SIGNAL_MODE_WRITE, NVN_EVENT_SIGNAL_LOCATION_BOTTOM, 0, 7);
    P(nvnCommandBufferSignalEvent)(&cb, &ev, NVN_EVENT_SIGNAL_MODE_ADD, NVN_EVENT_SIGNAL_LOCATION_BOTTOM, 0, 5);
    P(nvnCommandBufferReportCounter)(&cb, NVN_COUNTER_TYPE_TIMESTAMP, (NVNbufferAddress)cnt);
    NVNcommandHandle h1 = P(nvnCommandBufferEndRecording)(&cb);
    EXPECT("录完不在录制", 0, P(nvnCommandBufferIsRecording)(&cb));
    P(nvnCommandBufferBeginRecording)(&cb);
    P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)src, (NVNbufferAddress)dst, 64, 0);
    P(nvnCommandBufferCopyCommands)(&cb, 1, &h1);         // 嵌套：再执行一遍 h1（事件 7 → +5 → 再写 7 → +5） | nested: execute h1 once more (event 7 → +5 → write 7 again → +5)
    NVNcommandHandle h2 = P(nvnCommandBufferEndRecording)(&cb);
    printf("（命令内存回调 %d 次，用掉 %zu B）\n", g_cb_calls, g_cmdoff);
    EXPECT("命令内存回调至少 2 次（多段）", 1, g_cb_calls >= 2);
    EXPECT("提交前事件值仍为 0", 0, P(nvnEventGetValue)(&ev));

    NVNqueueBuilder qb; NVNqueue q; static uint8_t qmem[1 << 19];
    P(nvnQueueBuilderSetDevice)(&qb, &dev); P(nvnQueueBuilderSetDefaults)(&qb);
    size_t qsz = P(nvnQueueBuilderGetQueueMemorySize)(&qb);
    EXPECT("队列内存 = 64K+256K+16K 取整 4K", 65536 + 262144 + 16384, qsz);
    P(nvnQueueBuilderSetQueueMemory)(&qb, qmem, qsz);
    EXPECT("QueueInitialize 成功", 1, P(nvnQueueInitialize)(&q, &qb));
    NVNcommandHandle hs[2] = {h1, h2};
    P(nvnQueueSubmitCommands)(&q, 2, hs);
    NVNsync sf; P(nvnSyncInitialize)(&sf, &dev); P(nvnQueueFenceSync)(&q, &sf, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    int wr = P(nvnSyncWait)(&sf, 5000000000ull);
    EXPECT("提交后围栏等待成功（0 或 1）", 1, wr == 0 || wr == 1);
    int ub_ok = 1;
    for (int k = 0; k < 20; k++) for (int i = 0; i < 16; i++) { uint32_t w; memcpy(&w, ub + k * 64 + i * 4, 4); ub_ok &= w == (uint32_t)(k * 100 + i); }
    EXPECT("uniform 缓冲 20×16 个字全等录制值", 1, ub_ok);
    EXPECT("事件值：h1(7,+5) h2 拷贝后再跑 h1(7,+5) = 12", 12, P(nvnEventGetValue)(&ev));
    EXPECT("缓冲拷贝 64 B 全等", 0, memcmp(src, dst, 64));
    uint64_t ts[2]; memcpy(ts, cnt, 16);
    EXPECT("计数器时间戳已写（非 0）", 1, ts[0] != 0 && ts[0] == ts[1]);

    // 5b. 同步必须挡住 CPU：先排 24 次 64 MiB 拷贝把 GPU 占住，最后一条把 src 拷到 dst；
    //     等围栏返回后 CPU 才改写 src。若等待提前放行，最后那条拷贝会读到改写后的 src。
    // 5b. Sync must hold the CPU back: first queue 24 copies of 64 MiB to keep the GPU busy, with the last one copying src to dst;
    //     the CPU rewrites src only after the fence wait returns. If the wait is released early, that last copy reads the rewritten src.
    {
        size_t big = 64u << 20, pgsz = 16384;
        uint8_t *heap; posix_memalign((void **)&heap, pgsz, 4 * big);
        uint8_t *busy_a = heap, *busy_b = heap + big, *bsrc = heap + 2 * big, *bdst = heap + 3 * big;
        memset(heap, 0, 4 * big); memset(bsrc, 0x5A, big);
        NVNmemoryPoolBuilder hb; NVNmemoryPool hp; P(nvnMemoryPoolBuilderSetDefaults)(&hb); P(nvnMemoryPoolBuilderSetStorage)(&hb, heap, 4 * big);
        P(nvnMemoryPoolInitialize)(&hp, &hb);
        P(nvnCommandBufferBeginRecording)(&cb);
        for (int i = 0; i < 24; i++) P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)busy_a, (NVNbufferAddress)busy_b, big, 0);
        P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)bsrc, (NVNbufferAddress)bdst, big, 0);
        NVNcommandHandle hb2 = P(nvnCommandBufferEndRecording)(&cb);
        NVNsync sb; P(nvnSyncInitialize)(&sb, &dev);
        uint64_t t0 = now_ns();
        P(nvnQueueSubmitCommands)(&q, 1, &hb2); P(nvnQueueFenceSync)(&q, &sb, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
        int w0 = P(nvnSyncWait)(&sb, 0);
        int w1 = P(nvnSyncWait)(&sb, 10000000000ull);
        double ms = (now_ns() - t0) / 1e6;
        memset(bsrc, 0xC3, big);                                       // 等待放行后才改写 | rewrite only after the wait is released
        size_t bad = 0; for (size_t i = 0; i < big; i += 4096) bad += bdst[i] != 0x5A;
        printf("（GPU 占用约 %.1f ms）\n", ms);
        EXPECT("刚提交时零超时等待 = 超时(2)", 2, w0);
        EXPECT("长等待 = 满足(1)", 1, w1);
        EXPECT("dst 全为改写前的值（抽 16384 处）", 0, bad);
        P(nvnMemoryPoolFinalize)(&hp); free(heap);
    }

    // 6. 同步 / 窗口 / 出图
    // 6. Sync / window / present
    NVNsync s1, s2; P(nvnSyncInitialize)(&s1, &dev); P(nvnSyncInitialize)(&s2, &dev);
    EXPECT("未围栏的同步等待 = 超时(2)", 2, P(nvnSyncWait)(&s1, 0));
    P(nvnQueueFenceSync)(&q, &s1, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    EXPECT("围栏后等待 = 已就绪(0)", 0, P(nvnSyncWait)(&s1, 0));
    NVNtexture sc[2]; NVNtextureBuilder tb; P(nvnTextureBuilderSetDevice)(&tb, &dev); P(nvnTextureBuilderSetDefaults)(&tb);
    P(nvnTextureBuilderSetWidth)(&tb, 1280); P(nvnTextureBuilderSetHeight)(&tb, 720); P(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8);
    P(nvnTextureBuilderSetStorage)(&tb, &pool, 0); P(nvnTextureInitialize)(&sc[0], &tb); P(nvnTextureInitialize)(&sc[1], &tb);
    EXPECT("贴图宽", 1280, P(nvnTextureGetWidth)(&sc[0]));
    NVNtexture *scp[2] = {&sc[0], &sc[1]};
    NVNwindowBuilder wb; NVNwindow win; P(nvnWindowBuilderSetDevice)(&wb, &dev); P(nvnWindowBuilderSetDefaults)(&wb);
    P(nvnWindowBuilderSetTextures)(&wb, 2, scp); EXPECT("WindowInitialize 成功", 1, P(nvnWindowInitialize)(&win, &wb));
    int idx[4];
    for (int f = 0; f < 4; f++) {
        P(nvnWindowAcquireTexture)(&win, &s2, &idx[f]);
        for (int b = 0; b < 5; b++) P(nvnCommandBufferBarrier)(&cb, 0);
        P(nvnQueuePresentTexture)(&q, &win, idx[f]);
    }
    EXPECT("交换链轮转 0,1,0,1", 0x0101, idx[0] << 12 | idx[1] << 8 | idx[2] << 4 | idx[3]);
    EXPECT("取图后同步已就绪(0)", 0, P(nvnSyncWait)(&s2, 0));
    unsigned bi = 0; while (strcmp(nvn_names[bi], "nvnCommandBufferBarrier")) bi++;
    EXPECT("Barrier 计数 = 4 帧 × 5", 20, nvn_slot[bi].cnt);

    // 6b. 读回：像素 (x,y) = {x*16+y, y*16+x, 0x55, 0xAA}（期望按公式直接算）
    // 6b. Readback: pixel (x,y) = {x*16+y, y*16+x, 0x55, 0xAA} (expected values computed directly from the formula)
    {
        #define PX(x, y, c) ((uint8_t)((c) == 0 ? (x) * 16 + (y) : (c) == 1 ? (y) * 16 + (x) : (c) == 2 ? 0x55 : 0xAA))
        static uint8_t rb[256 << 10] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder rpb; NVNmemoryPool rp; P(nvnMemoryPoolBuilderSetDefaults)(&rpb); P(nvnMemoryPoolBuilderSetStorage)(&rpb, rb, sizeof rb);
        P(nvnMemoryPoolInitialize)(&rp, &rpb);
        uint8_t *stage = rb + 0x8000, *outb = rb + 0xC000;
        for (int y = 0; y < 4; y++) for (int x = 0; x < 8; x++) for (int c = 0; c < 4; c++) stage[(y * 8 + x) * 4 + c] = PX(x, y, c);
        NVNtextureBuilder b; NVNtexture ta; P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b);
        P(nvnTextureBuilderSetWidth)(&b, 8); P(nvnTextureBuilderSetHeight)(&b, 4); P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
        P(nvnTextureBuilderSetStorage)(&b, &rp, 0); P(nvnTextureInitialize)(&ta, &b);
        NVNcopyRegion all = {0, 0, 0, 8, 4, 1}, sub = {2, 1, 0, 5, 3, 1}, cp = {1, 0, 0, 4, 2, 1};
        P(nvnCommandBufferBeginRecording)(&cb);
        P(nvnCommandBufferSetCopyRowStride)(&cb, 0);
        P(nvnCommandBufferCopyBufferToTexture)(&cb, (NVNbufferAddress)stage, &ta, NULL, &all, 0);
        P(nvnCommandBufferSetCopyRowStride)(&cb, 64);
        P(nvnCommandBufferCopyTextureToBuffer)(&cb, &ta, NULL, &cp, (NVNbufferAddress)outb, 0);
        NVNcommandHandle hr = P(nvnCommandBufferEndRecording)(&cb);
        memset(outb, 0xEE, 256);
        P(nvnQueueSubmitCommands)(&q, 1, &hr); P(nvnQueueFinish)(&q);
        uint8_t got[5 * 3 * 4]; P(nvnTextureReadTexels)(&ta, NULL, &sub, got);
        int bad = 0; for (int y = 0; y < 3; y++) for (int x = 0; x < 5; x++) for (int c = 0; c < 4; c++) bad += got[(y * 5 + x) * 4 + c] != PX(x + 2, y + 1, c);
        EXPECT("ReadTexels 子区域 5x3 逐字节（GPU 写入的贴图）", 0, bad);
        uint8_t gs[4 * 40]; memset(gs, 0xEE, sizeof gs); P(nvnTextureReadTexelsStrided)(&ta, NULL, &all, gs, 40, 0);
        bad = 0; for (int y = 0; y < 4; y++) { for (int x = 0; x < 8; x++) for (int c = 0; c < 4; c++) bad += gs[y * 40 + x * 4 + c] != PX(x, y, c); for (int k = 32; k < 40; k++) bad += gs[y * 40 + k] != 0xEE; }
        EXPECT("ReadTexelsStrided 行距 40（行尾填充不动）", 0, bad);
        bad = 0; for (int y = 0; y < 2; y++) { for (int x = 0; x < 4; x++) for (int c = 0; c < 4; c++) bad += outb[y * 64 + x * 4 + c] != PX(x + 1, y, c); for (int k = 16; k < 64; k++) bad += outb[y * 64 + k] != 0xEE; }
        EXPECT("CopyTextureToBuffer 行距 64（GPU 拷回）", 0, bad);
        // 预排布贴图：池内存就是真值（块线性），ReadTexels 解排布直读
        // Packaged texture: the pool memory is the ground truth (block-linear); ReadTexels deswizzles and reads it directly
        uint8_t lin[16 * 8 * 4]; for (int y = 0; y < 8; y++) for (int x = 0; x < 16; x++) for (int c = 0; c < 4; c++) lin[(y * 16 + x) * 4 + c] = PX(x, y, c);
        NVNtexture tb; NVNpackagedTextureLayout lay = {{1, 0, 0, 0, 7, 0, 1, 0}};
        P(nvnTextureBuilderSetDefaults)(&b); P(nvnTextureBuilderSetWidth)(&b, 16); P(nvnTextureBuilderSetHeight)(&b, 8); P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
        P(nvnTextureBuilderSetPackagedTextureLayout)(&b, &lay); P(nvnTextureBuilderSetStorage)(&b, &rp, 0x10000); P(nvnTextureInitialize)(&tb, &b);
        nvn_texdesc dd = ((tex_t *)&tb)->d;
        if (nvn_swizzle(&dd, 0, 0, lin, 64, rb + 0x10000)) { printf("nvn_swizzle 失败\n"); g_fail++; }
        NVNcopyRegion s2 = {3, 2, 0, 9, 5, 1}; uint8_t g2[9 * 5 * 4];
        P(nvnTextureReadTexels)(&tb, NULL, &s2, g2);
        bad = 0; for (int y = 0; y < 5; y++) for (int x = 0; x < 9; x++) for (int c = 0; c < 4; c++) bad += g2[(y * 9 + x) * 4 + c] != PX(x + 3, y + 2, c);
        EXPECT("ReadTexels 预排布贴图 9x5（池内存块线性直读）", 0, bad);
        P(nvnMemoryPoolFinalize)(&rp);
    }

    // 6c. 写保护脏页：预排布贴图上传后池页只读；游戏写 → 缺页 → 标脏 → 下次使用重传；宿主 read() 直写需先 prepare
    // 6c. Write-protected dirty pages: after a packaged texture is uploaded its pool pages are read-only; game write → page fault → mark dirty → re-upload on next use; a direct host read() write needs prepare first
    {
        static uint8_t wb_[256 << 10] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder wpb; NVNmemoryPool wp; P(nvnMemoryPoolBuilderSetDefaults)(&wpb); P(nvnMemoryPoolBuilderSetStorage)(&wpb, wb_, sizeof wb_);
        P(nvnMemoryPoolInitialize)(&wp, &wpb);
        NVNtextureBuilder b; NVNtexture tw; NVNpackagedTextureLayout lay = {{1, 0, 0, 0, 7, 0, 1, 0}};
        P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b); P(nvnTextureBuilderSetWidth)(&b, 16); P(nvnTextureBuilderSetHeight)(&b, 8);
        P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8); P(nvnTextureBuilderSetPackagedTextureLayout)(&b, &lay);
        P(nvnTextureBuilderSetStorage)(&b, &wp, 0x10000); P(nvnTextureInitialize)(&tw, &b);
        nvn_texdesc dd = ((tex_t *)&tw)->d;
        uint8_t lin[16 * 8 * 4], *store = wb_ + 0x10000, *outb = wb_ + 0x20000;
        #define FILLPAT(k) for (int y = 0; y < 8; y++) for (int x = 0; x < 16; x++) for (int c = 0; c < 4; c++) lin[(y * 16 + x) * 4 + c] = (uint8_t)(x * 16 + y + (k) * 3 + c * 41)
        FILLPAT(0); nvn_swizzle(&dd, 0, 0, lin, 64, store);
        NVNcopyRegion all = {0, 0, 0, 16, 8, 1};
        // 用 GPU 拷回（CopyTextureToBuffer 读 MTLTexture）检验 GPU 侧实际内容：期望 = 第 k 版图案
        // Check the actual GPU-side contents with a GPU copy-back (CopyTextureToBuffer reading the MTLTexture): expected = pattern version k
        #define GPU_READ_EQ(k, name) do { P(nvnCommandBufferBeginRecording)(&cb); P(nvnCommandBufferSetCopyRowStride)(&cb, 0); \
            P(nvnCommandBufferCopyTextureToBuffer)(&cb, &tw, NULL, &all, (NVNbufferAddress)outb, 0); NVNcommandHandle hh = P(nvnCommandBufferEndRecording)(&cb); \
            P(nvnQueueSubmitCommands)(&q, 1, &hh); P(nvnQueueFinish)(&q); FILLPAT(k); EXPECT(name, 0, memcmp(outb, lin, sizeof lin)); } while (0)
        uint64_t up0, re0, fa0, pr0, up, re, fa, pr; mtl_pkg_stats(&up0, &re0); nvn_dirty_stats(&fa0, &pr0);
        GPU_READ_EQ(0, "首传：GPU 侧内容 = 第 0 版");
        mtl_pkg_stats(&up, &re); EXPECT("首传次数 +1", 1, up - up0);
        FILLPAT(1); nvn_swizzle(&dd, 0, 0, lin, 64, store);          // 游戏式 CPU 写：受保护页 → 缺页 → 钩子标脏 | game-style CPU write: protected page → page fault → hook marks it dirty
        nvn_dirty_stats(&fa, &pr); EXPECT("游戏写触发缺页 ≥ 1 次（已被钩子接住、未崩）", 1, fa - fa0 >= 1);
        GPU_READ_EQ(1, "重传后 GPU 侧内容 = 第 1 版");
        mtl_pkg_stats(&up, &re); EXPECT("池内容变化重传 +1", 1, re - re0);
        uint64_t fa1 = fa; GPU_READ_EQ(1, "内容不变再用：仍为第 1 版");
        nvn_dirty_stats(&fa, &pr); mtl_pkg_stats(&up, &re); EXPECT("内容不变：缺页 +0", 0, fa - fa1); EXPECT("内容不变：重传仍为 1", 1, re - re0);
        // 坑一：宿主 read() 直写受保护页。不 prepare 时内核返回 EFAULT（不缺页）；prepare 后读成功、标脏、下次重传
        // Pitfall 1: host read() writing directly into protected pages. Without prepare the kernel returns EFAULT (no page fault); after prepare the read succeeds, the pages are marked dirty and re-uploaded next time
        char path[1024]; snprintf(path, sizeof path, "%s/t_nvn_rd_XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "."); int fd = mkstemp(path);   // 每用户临时目录，不写 /tmp | per-user temp directory, do not write to /tmp
        FILLPAT(2); uint8_t tmpst[sizeof lin * 4]; memset(tmpst, 0, sizeof tmpst);
        static uint8_t full[0x10000]; memcpy(full, store, sizeof full);   // 现有存储内容（块线性），把第 2 版写进副本再存文件 | existing storage contents (block-linear); write version 2 into a copy and then save it to a file
        nvn_swizzle(&dd, 0, 0, lin, 64, full); if (write(fd, full, ((tex_t *)&tw)->L.size) < 0) g_fail++;
        ssize_t r0 = pread(fd, store, ((tex_t *)&tw)->L.size, 0); int e0 = errno;
        EXPECT("不 prepare：read() 进受保护页返回 -1 且 EFAULT", 1, r0 == -1 && e0 == EFAULT);
        dm_guest_write_prepare(store, ((tex_t *)&tw)->L.size);
        ssize_t r1 = pread(fd, store, ((tex_t *)&tw)->L.size, 0);
        EXPECT("prepare 后 read() 成功", (long long)((tex_t *)&tw)->L.size, r1);
        close(fd); unlink(path);
        GPU_READ_EQ(2, "宿主写后重传：GPU 侧内容 = 第 2 版");
        mtl_pkg_stats(&up, &re); EXPECT("宿主写触发重传，累计 2", 2, re - re0);
        P(nvnMemoryPoolFinalize)(&wp);
    }

    // 6d. 生命周期：挂起返回时在途 GPU 工作为 0；挂起期间提交被挡住，恢复后放行
    // 6d. Lifecycle: in-flight GPU work is 0 when suspend returns; submits are blocked during suspend and let through after resume
    {
        size_t big = 64u << 20; uint8_t *heap; posix_memalign((void **)&heap, 16384, 2 * big); memset(heap, 0, 2 * big);
        NVNmemoryPoolBuilder hb; NVNmemoryPool hp; P(nvnMemoryPoolBuilderSetDefaults)(&hb); P(nvnMemoryPoolBuilderSetStorage)(&hb, heap, 2 * big);
        P(nvnMemoryPoolInitialize)(&hp, &hb);
        P(nvnCommandBufferBeginRecording)(&cb);
        for (int i = 0; i < 24; i++) P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)heap, (NVNbufferAddress)(heap + big), big, 0);
        NVNcommandHandle hbusy = P(nvnCommandBufferEndRecording)(&cb);
        P(nvnQueueSubmitCommands)(&q, 1, &hbusy);
        uint64_t f = mtl_last_fence();
        int busy_before = !mtl_wait(f, 0);
        dm_gfx_suspend(1);
        EXPECT("挂起前 GPU 确实在忙（零超时等待未完成）", 1, busy_before);
        EXPECT("挂起返回时在途工作已完成", 1, mtl_wait(f, 0));
        P(nvnCommandBufferBeginRecording)(&cb); P(nvnCommandBufferBarrier)(&cb, 0); NVNcommandHandle hsmall = P(nvnCommandBufferEndRecording)(&cb);
        g_sq = &q; g_sh = hsmall; g_sub = P(nvnQueueSubmitCommands); atomic_store(&g_sstarted, 0); atomic_store(&g_sdone, 0);
        pthread_t th; pthread_create(&th, NULL, susp_thr, NULL);
        int started = wait_started();
        EXPECT("挂起期间另一线程已进入提交且尚未返回", 1, started && !atomic_load(&g_sdone));
        dm_gfx_suspend(0);
        pthread_join(th, NULL);
        EXPECT("恢复后该提交放行返回", 1, atomic_load(&g_sdone));
        P(nvnQueueFinish)(&q); P(nvnMemoryPoolFinalize)(&hp); free(heap);
    }

    // 6e. 出图节拍（真机语义）：出图立即返回；阻塞在取图——交换链 3 张、间隔 1、60 Hz，第 4 次取图等到第 0 张显示满一周期
    // 6e. Present pacing (real-device semantics): present returns immediately; blocking happens at acquire - swapchain of 3, interval 1, 60 Hz, the 4th acquire waits until texture 0 has been displayed for a full period
    {
        nvn_present_config(60, 0);
        NVNwindowBuilder wb2; NVNwindow w2; P(nvnWindowBuilderSetDevice)(&wb2, &dev); P(nvnWindowBuilderSetDefaults)(&wb2);
        NVNtexture *sc3[3] = {&sc[0], &sc[1], &sc[0]};
        P(nvnWindowBuilderSetTextures)(&wb2, 3, sc3); P(nvnWindowInitialize)(&w2, &wb2); P(nvnWindowSetPresentInterval)(&w2, 1);
        int ix;
        for (int k = 0; k < 3; k++) {
            P(nvnWindowAcquireTexture)(&w2, NULL, &ix);
            P(nvnQueuePresentTexture)(&q, &w2, ix);
        }
        P(nvnWindowAcquireTexture)(&w2, NULL, &ix);
        EXPECT("第 4 次取到的是第 0 张", 0, ix);
        P(nvnQueuePresentTexture)(&q, &w2, ix);
        P(nvnWindowAcquireTexture)(&w2, NULL, &ix);
        EXPECT("第 5 次取到的是第 1 张", 1, ix);
        nvn_present_config(0, 0);
    }

    // 6f. 出图线程：drawable 迟迟不可用（出图线程每次停 200 ms）时，出图调用仍立即返回；
    //     交换链转满一圈后，取回第 0 张要等它那次出图被处理完（第一次入队 + 200 ms）
    // 6f. Present thread: when the drawable stays unavailable for a long time (the present thread stalls 200 ms each time), the present call still returns immediately;
    //     after the swapchain has gone a full round, re-acquiring texture 0 has to wait until its present has been processed (first enqueue + 200 ms)
    {
        nvn_present_config(0, 0);   // 不按节拍等，只看出图线程归还 | do not wait on the display link; only check that the present thread hands it back
        const double S = 200;
        mtl_present_test_stall((uint64_t)(S * 1e6));
        NVNwindowBuilder wb3; NVNwindow w3; P(nvnWindowBuilderSetDevice)(&wb3, &dev); P(nvnWindowBuilderSetDefaults)(&wb3);
        NVNtexture *sc3[3] = {&sc[0], &sc[1], &sc[0]};
        P(nvnWindowBuilderSetTextures)(&wb3, 3, sc3); P(nvnWindowInitialize)(&w3, &wb3);
        int ix;
        for (int k = 0; k < 3; k++) {
            P(nvnWindowAcquireTexture)(&w3, NULL, &ix);
            P(nvnQueuePresentTexture)(&q, &w3, ix);
        }
        P(nvnWindowAcquireTexture)(&w3, NULL, &ix);
        EXPECT("取到的是第 0 张", 0, ix);
        mtl_present_test_stall(0); mtl_present_flush();
    }

    // 7. 未实现函数：返回 0、报红、只报一次
    // 7. Unimplemented functions: return 0, report a failure, report only once
    unsigned ui = 0; while (strcmp(nvn_names[ui], "nvnBufferBuilderSetDefaults")) ui++;
    ((void (*)(void *))proc("nvnBufferBuilderSetDefaults"))(NULL); ((void (*)(void *))proc("nvnBufferBuilderSetDefaults"))(NULL);
    EXPECT("未实现函数被调用后记为已报红", 1, g_unimpl_seen[ui] > 0);
    EXPECT("未实现函数计数 2", 2, nvn_slot[ui].cnt);

    printf("== %d 项，失败 %d ==\n", g_n, g_fail);
    return g_fail != 0;
}
