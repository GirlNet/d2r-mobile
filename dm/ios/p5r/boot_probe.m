// 分阶段初始化诊断的原子 JSON 报告：记录接口和来源，可选运行模块构造器；始终在游戏主函数/图形初始化前停止。
// Atomic JSON reports for staged initialization probes: record interfaces/provenance and optionally run module constructors; always stop before game main/graphics initialization.
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
static int allowModules;

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
static int begin(const char *directory, int modules) { @autoreleasepool {
    pthread_mutex_lock(&mutex);
    NSString *path = string(directory);
    if (atomic_load(&active) || !path.isAbsolutePath || mkdir(path.fileSystemRepresentation,0700)) {
        pthread_mutex_unlock(&mutex); return 0;
    }
    reportPath = [path stringByAppendingPathComponent:@"boot-report.json"];
    allowModules = modules;
    events = [NSMutableArray array];
    report = [@{@"schema_version":@1,@"kind":modules ? @"p5r_module_initialization_probe" : @"p5r_sdk_initialization_probe",@"status":@"running",
        @"stop_before":modules ? @"nnMain" : @"module_initializers",
        @"current_stage":@"launcher",@"events":events,@"completed_sdk_entries":@0,
        @"module_initializers_completed":@NO,@"completed_argument_entries":@0,
        @"module_initializers_called":@NO,@"game_main_called":@NO,@"guest_gpu_work_submitted":@NO,
        @"runtime_ready":@NO,@"graphics_verified":@NO,@"restart_required":@YES,
        @"os_version":NSProcessInfo.processInfo.operatingSystemVersionString} mutableCopy];
    for (NSString *name in @[@"p5r-shell.json",@"p5r-package.json"]) {
        NSData *data = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[@"dm" stringByAppendingPathComponent:name]]];
        id metadata = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([metadata isKindOfClass:NSDictionary.class]) report[name] = metadata;
    }
    append(@"probe_started",modules ? @"Run module initializers, then stop before nnMain; guest GPU work is not permitted" : @"Stop before module_initializers; nnMain is not permitted");
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
    append(completed ? @"entry_completed" : @"entry_begin",string(entry));
    int module = !strcmp(entry,"module_initializers"), main = !strcmp(entry,"nnMain");
    int allowed = !main && (allowModules || !module);
    if (!allowed) {
        atomic_store(&terminal,1);
        report[@"status"] = main ? @"stopped_before_game_main" : @"stopped_before_module_initializers";
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
        report[@"current_stage"] = string(boundary); append(string(boundary),string(detail)); save();
    }
    // 不从未知客体调用栈强制退线程，也不放行被阻止的操作；用户重新打开进程开始下一轮。
    // Never unwind an unknown guest call stack or allow the blocked operation; restart the process for another run.
    while (atomic_load(&active)) pthread_cond_wait(&parked,&mutex);
    pthread_mutex_unlock(&mutex);
} }
