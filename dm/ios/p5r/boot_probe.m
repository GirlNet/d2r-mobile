// 分阶段初始化诊断的原子 JSON 报告：记录入口、文件检查点及来源；启动模式可进入游戏主函数；图形设置模式只放行一个初始化线程，完成后停住，始终阻止客体提交。
// Atomic JSON reports for staged initialization probes: record entries, file checkpoints and provenance; startup admits game main; GPU setup admits one initialization owner and parks after completion, always blocking guest submission.
#import <Foundation/Foundation.h>
#include "boot_probe.h"
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t parked = PTHREAD_COND_INITIALIZER;
static _Atomic int active, terminal;
static NSMutableDictionary *report;
static NSMutableArray *events;
static NSString *reportPath;
static int probeMode, gpuStarted;
static pthread_t gpuOwner;

static NSString *string(const char *value) {
    if (!value) return @"";
    return [[NSString alloc] initWithBytes:value length:strnlen(value,1024) encoding:NSUTF8StringEncoding] ?: @"invalid UTF-8";
}
static void save(void) {
    report[@"updated_at"] = @([NSDate.date timeIntervalSince1970]);
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
    if (![data writeToFile:reportPath options:NSDataWritingAtomic error:NULL])
        fprintf(stderr,"P5R boot probe: cannot persist report\n");
}
static void append(NSString *event, NSString *detail) {
    if (events.count < 256) [events addObject:@{@"event":event,@"detail":detail,@"time":@([NSDate.date timeIntervalSince1970])}];
    else report[@"events_truncated"] = @YES;
}
int dm_boot_probe_active(void) { return atomic_load(&active); }
static int begin(const char *directory, int mode) { @autoreleasepool {
    pthread_mutex_lock(&mutex);
    NSString *path = string(directory);
    if (atomic_load(&active) || !path.isAbsolutePath || mkdir(path.fileSystemRepresentation,0700)) {
        pthread_mutex_unlock(&mutex); return 0;
    }
    reportPath = [path stringByAppendingPathComponent:@"boot-report.json"];
    probeMode = mode; gpuStarted = 0;
    events = [NSMutableArray array];
    report = [@{@"schema_version":@1,@"kind":mode==3 ? @"p5r_gpu_setup_probe" : mode==2 ? @"p5r_startup_probe" : mode==1 ? @"p5r_module_initialization_probe" : @"p5r_sdk_initialization_probe",@"status":@"running",
        @"stop_before":mode==3 ? @"guest_gpu_submission" : mode==2 ? @"gpu_initialization" : mode==1 ? @"nnMain" : @"module_initializers",
        @"current_stage":@"launcher",@"events":events,@"completed_sdk_entries":@0,
        @"module_initializers_completed":@NO,@"completed_argument_entries":@0,
        @"module_initializers_called":@NO,@"game_main_called":@NO,@"game_main_returned":@NO,@"guest_gpu_work_submitted":@NO,
        @"gpu_initialization_started":@NO,@"gpu_initialization_completed":@NO,
        @"runtime_ready":@NO,@"graphics_verified":@NO,@"restart_required":@YES,
        @"os_version":NSProcessInfo.processInfo.operatingSystemVersionString} mutableCopy];
    for (NSString *name in @[@"p5r-shell.json",@"p5r-package.json"]) {
        NSData *data = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[@"dm" stringByAppendingPathComponent:name]]];
        id metadata = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([metadata isKindOfClass:NSDictionary.class]) report[name] = metadata;
    }
    append(@"probe_started",mode==3 ? @"Run nnMain, initialize the Metal backend, then park before returning to the guest; no guest GPU submission" : mode==2 ? @"Run nnMain under the probe deadline; stop before guest GPU initialization" : mode==1 ? @"Run module initializers, then stop before nnMain; guest GPU work is not permitted" : @"Stop before module_initializers; nnMain is not permitted");
    save();
    BOOL saved = [NSFileManager.defaultManager fileExistsAtPath:reportPath];
    if (saved) atomic_store(&active,1);
    pthread_mutex_unlock(&mutex);
    if (saved) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        if (dm_boot_probe_timeout()) { fflush(stderr); _exit(78); }
    });
    return saved;
} }
int dm_boot_probe_begin(const char *directory) { return begin(directory,0); }
int dm_boot_probe_begin_modules(const char *directory) { return begin(directory,1); }
int dm_boot_probe_begin_startup(const char *directory) { return begin(directory,2); }
int dm_boot_probe_begin_gpu_setup(const char *directory) { return begin(directory,3); }
void dm_boot_probe_note(const char *event, const char *detail) { @autoreleasepool {
    if (!dm_boot_probe_active()) return;
    pthread_mutex_lock(&mutex);
    if (!atomic_load(&terminal)) { report[@"current_stage"] = string(event); report[@"current_detail"] = string(detail); append(string(event),string(detail)); save(); }
    pthread_mutex_unlock(&mutex);
} }
void dm_boot_probe_failure(const char *reason) { @autoreleasepool {
    if (!dm_boot_probe_active()) return;
    pthread_mutex_lock(&mutex);
    if (!atomic_exchange(&terminal,1)) {
        report[@"status"] = @"failed"; report[@"failure_reason"] = string(reason);
        append(@"failed",string(reason)); save();
    }
    pthread_mutex_unlock(&mutex);
} }
int dm_boot_probe_timeout(void) { @autoreleasepool {
    if (!dm_boot_probe_active()) return 0;
    pthread_mutex_lock(&mutex);
    int shouldExit = !atomic_exchange(&terminal,1);
    if (shouldExit) {
        report[@"status"] = @"timeout"; report[@"process_exit_requested"] = @YES;
        append(@"timeout",@"30-second deadline: terminate the process to stop all guest threads"); save();
    }
    pthread_mutex_unlock(&mutex); return shouldExit;
} }
int dm_boot_probe_checkpoint(const char *entry, int completed) { @autoreleasepool {
    if (!dm_boot_probe_active()) return 1;
    if (!entry || !*entry) { dm_boot_probe_failure("invalid checkpoint name"); return 0; }
    pthread_mutex_lock(&mutex);
    if (atomic_load(&terminal)) { pthread_mutex_unlock(&mutex); return 0; }
    report[@"current_stage"] = string(entry);
    report[@"current_detail"] = string(entry);
    append(completed ? @"entry_completed" : @"entry_begin",string(entry));
    int module = !strcmp(entry,"module_initializers"), main = !strcmp(entry,"nnMain");
    int allowed = (!main || probeMode>=2) && (probeMode>=1 || !module);
    if (!allowed) {
        atomic_store(&terminal,1);
        report[@"status"] = main ? @"stopped_before_game_main" : @"stopped_before_module_initializers";
    } else if (main) {
        report[completed ? @"game_main_returned" : @"game_main_called"] = @YES;
        if (completed) { atomic_store(&terminal,1); report[@"status"] = @"game_main_returned"; }
    } else if (module) {
        report[completed ? @"module_initializers_completed" : @"module_initializers_called"] = @YES;
    } else if (completed) {
        const char *sdk[] = {"_init_libc0","nnosInitialize","_init_libc1","nninitInitializeSdkModule","nninitStartup","_init_libc2"};
        for (unsigned i=0;i<sizeof sdk/sizeof *sdk;i++) if (!strcmp(entry,sdk[i]))
            report[@"completed_sdk_entries"] = @([report[@"completed_sdk_entries"] intValue]+1);
        if (!strcmp(entry,"_ZN2nn2os11SetHostArgcEi") || !strcmp(entry,"_ZN2nn2os11SetHostArgvEPPc"))
            report[@"completed_argument_entries"] = @([report[@"completed_argument_entries"] intValue]+1);
    }
    save(); pthread_mutex_unlock(&mutex); return allowed;
} }
void dm_boot_probe_block(const char *boundary, const char *detail) { @autoreleasepool {
    if (!dm_boot_probe_active()) return;
    pthread_mutex_lock(&mutex);
    if (!atomic_exchange(&terminal,1)) {
        report[@"status"] = @"blocked_before_unverified_operation";
        report[@"current_stage"] = string(boundary); report[@"current_detail"] = string(detail); append(string(boundary),string(detail)); save();
    }
    // 不从未知客体调用栈强制退线程，也不放行被阻止的操作；用户重新打开进程开始下一轮。
    // Never unwind an unknown guest call stack or allow the blocked operation; restart the process for another run.
    while (atomic_load(&active)) pthread_cond_wait(&parked,&mutex);
    pthread_mutex_unlock(&mutex);
} }

// 只有图形设置模式中 nnMain 之后的第一个线程能初始化；其它线程等待，不放过半初始化的 g_dev。
// 完成必须由同一线程报告；设置终态后永久等待，不能返回客体继续提交或绘制。
// Only the first thread after nnMain in GPU-setup mode may initialize; others wait instead of using a partial g_dev.
// Completion must come from the same thread; park permanently after saving the terminal state, without returning to guest submission or drawing.
int dm_boot_probe_gpu_begin(void) { @autoreleasepool {
    if (!dm_boot_probe_active()) return 0;
    pthread_mutex_lock(&mutex);
    if (probeMode==3 && !atomic_load(&terminal) && [report[@"game_main_called"] boolValue] && !gpuStarted) {
        gpuStarted=1; gpuOwner=pthread_self(); report[@"gpu_initialization_started"]=@YES;
        report[@"current_stage"]=@"gpu_initialization"; report[@"current_detail"]=@"initialize backend objects without guest submission";
        append(@"gpu_initialization_begin",@"exclusive setup owner"); save();
        pthread_mutex_unlock(&mutex); return 1;
    }
    if (probeMode==3 && gpuStarted) {
        while (atomic_load(&active)) pthread_cond_wait(&parked,&mutex);
        pthread_mutex_unlock(&mutex); return 0;
    }
    pthread_mutex_unlock(&mutex);
    dm_boot_probe_block("gpu_initialization","backend setup is not permitted in this probe stage"); return 0;
} }
void dm_boot_probe_gpu_complete(const char *backend, const char *device) { @autoreleasepool {
    if (!dm_boot_probe_active()) return;
    pthread_mutex_lock(&mutex);
    if (!atomic_exchange(&terminal,1)) {
        if (probeMode!=3 || !gpuStarted || !pthread_equal(gpuOwner,pthread_self())) {
            report[@"status"]=@"failed"; report[@"failure_reason"]=@"GPU completion without matching setup owner";
            append(@"failed",@"GPU completion without matching setup owner");
        } else {
            report[@"gpu_initialization_completed"]=@YES; report[@"gpu_backend"]=string(backend); report[@"gpu_device"]=string(device);
            report[@"status"]=@"stopped_after_gpu_initialization";
            report[@"current_stage"]=@"gpu_initialization_completed"; report[@"current_detail"]=@"no guest commands submitted; restart required";
            append(@"gpu_initialization_completed",string(backend));
        }
        save();
    }
    while (atomic_load(&active)) pthread_cond_wait(&parked,&mutex);
    pthread_mutex_unlock(&mutex);
} }
