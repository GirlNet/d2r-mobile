// 用真实分配器包装函数与合成导出测试符号查找、三参数/返回值 ABI、并发首次调用及缺失/递归入口拒绝；不读取游戏。
// Exercise the real allocator wrapper with a synthetic export: symbol lookup, three-argument/return ABI, concurrent first calls and missing/recursive entry rejection; no game files.
#include "../hle_svc.c"
#include <assert.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/wait.h>

static _Atomic unsigned lookups, calls;
static int lookup_mode;
typedef struct { size_t size, align; int fail; uint8_t data[32]; } context;
static void *allocate(void *self, size_t size, size_t align) {
    context *c=self;
    assert(c && c->size==size && c->align==align);
    atomic_fetch_add(&calls,1);
    return size && !c->fail ? c->data : NULL;
}
void *guest_sym(const char *name) {
    assert(!strcmp(name,"_ZN2nn3mem17StandardAllocator8AllocateEmm"));
    atomic_fetch_add(&lookups,1);
    return lookup_mode==1 ? NULL : lookup_mode==2 ? (void *)hle_stdalloc_allocate : (void *)allocate;
}
static void *worker(void *arg) {
    context *c=arg;
    for (unsigned i=0;i<32;i++) assert(hle_stdalloc_allocate(c,c->size,c->align)==c->data);
    return NULL;
}
int main(void) {
    struct rlimit no_core={0,0}; assert(!setrlimit(RLIMIT_CORE,&no_core));
    for (int mode=1;mode<=2;mode++) {
        pid_t child=fork(); assert(child>=0);
        if (!child) { lookup_mode=mode; context c={.size=0x408,.align=0x10}; hle_stdalloc_allocate(&c,c.size,c.align); _exit(99); }
        int status; assert(waitpid(child,&status,0)==child);
        assert(WIFSIGNALED(status) && WTERMSIG(status)==SIGABRT);
    }
    enum { N=8 }; pthread_t threads[N]; context c[N];
    for (unsigned i=0;i<N;i++) {
        c[i]=(context){.size=0x408+i,.align=16u<<i};
        assert(!pthread_create(&threads[i],NULL,worker,&c[i]));
    }
    for (unsigned i=0;i<N;i++) assert(!pthread_join(threads[i],NULL));
    unsigned resolved=atomic_load(&lookups);
    assert(resolved>=1 && resolved<=N && atomic_load(&calls)==N*32);
    context zero={.size=0,.align=16}; assert(!hle_stdalloc_allocate(&zero,0,16));
    context oom={.size=0x408,.align=16,.fail=1}; assert(!hle_stdalloc_allocate(&oom,oom.size,oom.align));
    assert(atomic_load(&lookups)==resolved && atomic_load(&calls)==N*32+2);
    puts("STANDARD ALLOCATOR FORWARD OK: symbolic original, argument/return ABI, concurrent cache and invalid exports");
    return 0;
}
