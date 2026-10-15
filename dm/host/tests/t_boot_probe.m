// 合成诊断验证 JSON 持久化、只跑六个 SDK 入口、阻塞边界、超时及旧文件保护；不读取游戏数据。
// Synthetic diagnostics test JSON persistence, the six-entry SDK limit, blocking boundaries, deadlines and existing-file protection without game data.
#import <Foundation/Foundation.h>
#include "../boot_probe.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define CHECK(e) do { if (!(e)) { fprintf(stderr,"BOOT PROBE check failed at %d: %s\n",__LINE__,#e); return 1; } } while (0)
static _Atomic int escaped;
static void *blocked(void *unused) { (void)unused; dm_boot_probe_block("gpu_initialization","synthetic boundary"); atomic_store(&escaped,1); return NULL; }
static NSDictionary *readReport(NSString *directory) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"boot-report.json"]];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}
int main(int argc, char **argv) { @autoreleasepool {
    CHECK(argc == 3);
    NSString *directory = @(argv[2]);
    CHECK(!dm_boot_probe_active() && dm_boot_probe_checkpoint("inactive",0) && !dm_boot_probe_timeout());
    dm_boot_probe_block("inactive","must return");
    CHECK(dm_boot_probe_begin(argv[2]) && dm_boot_probe_active());
    NSDictionary *report = readReport(directory); CHECK([report[@"status"] isEqual:@"running"]);
    NSData *before = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"boot-report.json"]];
    CHECK(!dm_boot_probe_begin(argv[2]));
    CHECK([before isEqual:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"boot-report.json"]]]);
    if (!strcmp(argv[1],"checkpoint")) {
        const char *names[] = {"_init_libc0","nnosInitialize","_init_libc1","nninitInitializeSdkModule","nninitStartup","_init_libc2"};
        for (int i = 0; i < 6; i++) { CHECK(dm_boot_probe_checkpoint(names[i],0)); CHECK(dm_boot_probe_checkpoint(names[i],1)); }
        CHECK(!dm_boot_probe_checkpoint("module_initializers",0));
        CHECK(!dm_boot_probe_checkpoint("nnMain",0));
        CHECK(!dm_boot_probe_timeout());
        report = readReport(directory);
        CHECK([report[@"status"] isEqual:@"stopped_before_module_initializers"]);
        CHECK([report[@"completed_sdk_entries"] intValue] == 6);
    } else if (!strcmp(argv[1],"blocked")) {
        pthread_t thread; CHECK(!pthread_create(&thread,NULL,blocked,NULL)); pthread_detach(thread);
        for (int i = 0; i < 200; i++) {
            usleep(5000); report = readReport(directory);
            if ([report[@"status"] isEqual:@"blocked_before_unverified_operation"]) break;
        }
        CHECK([report[@"status"] isEqual:@"blocked_before_unverified_operation"] && !atomic_load(&escaped));
        CHECK(!dm_boot_probe_timeout());
    } else if (!strcmp(argv[1],"timeout")) {
        dm_boot_probe_note("sdk_entry","still in progress");
        CHECK(dm_boot_probe_timeout() && !dm_boot_probe_timeout());
        report = readReport(directory); CHECK([report[@"status"] isEqual:@"timeout"]);
        CHECK([report[@"current_stage"] isEqual:@"sdk_entry"]);
    } else if (!strcmp(argv[1],"failure")) {
        dm_boot_probe_failure("quote\" backslash\\ newline\n");
        dm_boot_probe_failure("must not overwrite first failure");
        report = readReport(directory); CHECK([report[@"status"] isEqual:@"failed"]);
        CHECK([report[@"failure_reason"] isEqual:@"quote\" backslash\\ newline\n"]);
    } else CHECK(0);
    report = readReport(directory);
    CHECK([report[@"schema_version"] intValue] == 1);
    CHECK([report[@"runtime_ready"] isEqual:@NO] && [report[@"graphics_verified"] isEqual:@NO]);
    CHECK([report[@"game_main_called"] isEqual:@NO] && [report[@"module_initializers_called"] isEqual:@NO]);
    CHECK([report[@"guest_gpu_work_submitted"] isEqual:@NO]);
    CHECK([report[@"restart_required"] isEqual:@YES]);
    printf("BOOT PROBE %s OK\n",argv[1]); return 0;
} }
