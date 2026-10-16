// 合成诊断验证 SDK/模块/启动三种边界、主函数返回/超时/GPU 阻塞、JSON 持久化及旧文件保护；不读取游戏数据。
// Synthetic diagnostics test SDK/module/startup boundaries, main return/timeout/GPU blocking, JSON persistence and existing-file protection without game data.
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
static _Atomic int setupEntered, releaseSetup;
static void *setupWorker(void *unused) {
    (void)unused;
    if (dm_boot_probe_gpu_begin()) {
        atomic_fetch_add(&setupEntered,1);
        while (!atomic_load(&releaseSetup)) usleep(1000);
        dm_boot_probe_gpu_complete("synthetic backend","synthetic device");
    }
    atomic_store(&escaped,1); return NULL;
}
static _Atomic int setupReturned;
static void *continueSetup(void *unused) {
    (void)unused;
    if (dm_boot_probe_gpu_begin()) {
        atomic_fetch_add(&setupEntered,1);
        while (!atomic_load(&releaseSetup)) usleep(1000);
        dm_boot_probe_gpu_complete("synthetic backend","synthetic device");
    }
    atomic_fetch_add(&setupReturned,1); return NULL;
}
static void *guardedSubmission(void *unused) { (void)unused; DM_GPU_SUBMIT(atomic_store(&escaped,1)); return NULL; }
static void *wrongOwner(void *unused) { (void)unused; dm_boot_probe_gpu_complete("wrong","wrong"); atomic_store(&escaped,1); return NULL; }
static void *submission(void *unused) { (void)unused; dm_boot_probe_block("guest_gpu_submission","synthetic submit"); atomic_store(&escaped,1); return NULL; }
static void *gpuEntry(void *unused) { (void)unused; dm_boot_probe_gpu_begin(); atomic_store(&escaped,1); return NULL; }
static NSDictionary *readReport(NSString *directory) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"boot-report.json"]];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}
int main(int argc, char **argv) { @autoreleasepool {
    CHECK(argc == 3);
    NSString *directory = @(argv[2]);
    CHECK(!dm_boot_probe_active() && dm_boot_probe_checkpoint("inactive",0) && !dm_boot_probe_timeout());
    dm_boot_probe_block("inactive","must return"); CHECK(!dm_boot_probe_gpu_begin()); dm_boot_probe_gpu_complete("inactive","inactive");
    int gpuSetup = !strncmp(argv[1],"gpu-setup",9);
    int preSubmit = !strncmp(argv[1],"pre-submit",10);
    int startup = preSubmit || gpuSetup || !strncmp(argv[1],"startup-",8);
    int modules = startup || !strcmp(argv[1],"modules") || !strcmp(argv[1],"modules-failure");
    CHECK((preSubmit ? dm_boot_probe_begin_pre_submit(argv[2]) : gpuSetup ? dm_boot_probe_begin_gpu_setup(argv[2]) : startup ? dm_boot_probe_begin_startup(argv[2]) : modules ? dm_boot_probe_begin_modules(argv[2]) : dm_boot_probe_begin(argv[2])) && dm_boot_probe_active());
    NSDictionary *report = readReport(directory); CHECK([report[@"status"] isEqual:@"running"]);
    CHECK([report[@"stop_before"] isEqual:gpuSetup || preSubmit ? @"guest_gpu_submission" : startup ? @"gpu_initialization" : modules ? @"nnMain" : @"module_initializers"]);
    NSData *before = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"boot-report.json"]];
    CHECK(!dm_boot_probe_begin(argv[2]));
    CHECK([before isEqual:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"boot-report.json"]]]);
    if (!strcmp(argv[1],"checkpoint") || modules) {
        const char *names[] = {"_init_libc0","nnosInitialize","_init_libc1","nninitInitializeSdkModule","nninitStartup","_init_libc2"};
        for (int i = 0; i < 6; i++) { CHECK(dm_boot_probe_checkpoint(names[i],0)); CHECK(dm_boot_probe_checkpoint(names[i],1)); }
        if (modules) {
            CHECK(dm_boot_probe_checkpoint("module_initializers",0));
            dm_boot_probe_note("module_init_begin","synthetic_module");
            if (!strcmp(argv[1],"modules-failure")) {
                dm_boot_probe_failure("synthetic constructor failure");
                CHECK(!dm_boot_probe_checkpoint("module_initializers",1));
            } else {
                dm_boot_probe_note("module_init_complete","synthetic_module");
                CHECK(dm_boot_probe_checkpoint("module_initializers",1));
                CHECK(dm_boot_probe_checkpoint("_ZN2nn2os11SetHostArgcEi",0));
                CHECK(dm_boot_probe_checkpoint("_ZN2nn2os11SetHostArgcEi",1));
                CHECK(dm_boot_probe_checkpoint("_ZN2nn2os11SetHostArgvEPPc",0));
                CHECK(dm_boot_probe_checkpoint("_ZN2nn2os11SetHostArgvEPPc",1));
                if (startup) {
                    CHECK(dm_boot_probe_checkpoint("nnMain",0));
                    dm_boot_probe_note("fs_open","rom:/synthetic/\"test\".cpk");
                    CHECK([readReport(directory)[@"current_detail"] isEqual:@"rom:/synthetic/\"test\".cpk"]);
                    if (preSubmit) {
                        pthread_t owner, contender; CHECK(!pthread_create(&owner,NULL,continueSetup,NULL)); pthread_detach(owner);
                        for (int i=0;i<200 && !atomic_load(&setupEntered);i++) usleep(5000);
                        CHECK(atomic_load(&setupEntered)==1);
                        CHECK(!pthread_create(&contender,NULL,continueSetup,NULL)); pthread_detach(contender);
                        usleep(10000); CHECK(!atomic_load(&setupReturned));
                        int failure=!strcmp(argv[1],"pre-submit-failure"), wrong=!strcmp(argv[1],"pre-submit-wrong-owner");
                        if (failure) dm_boot_probe_failure("synthetic resource failure");
                        else if (wrong) { pthread_t t; CHECK(!pthread_create(&t,NULL,wrongOwner,NULL)); pthread_detach(t); for (int i=0;i<200;i++) { usleep(5000); if (![readReport(directory)[@"status"] isEqual:@"running"]) break; } }
                        atomic_store(&releaseSetup,1);
                        if (!failure && !wrong) {
                            for (int i=0;i<200 && atomic_load(&setupReturned)!=2;i++) usleep(5000);
                            CHECK(atomic_load(&setupReturned)==2 && atomic_load(&setupEntered)==1);
                            report=readReport(directory); CHECK([report[@"status"] isEqual:@"running"] && [report[@"gpu_initialization_completed"] isEqual:@YES]);
                            CHECK(!dm_boot_probe_gpu_begin());
                            dm_boot_probe_note("resource_setup","synthetic resource checkpoint");
                            if (!strcmp(argv[1],"pre-submit-timeout")) CHECK(dm_boot_probe_timeout());
                            else { CHECK(!strcmp(argv[1],"pre-submit")); pthread_t t; CHECK(!pthread_create(&t,NULL,guardedSubmission,NULL)); pthread_detach(t); for (int i=0;i<200;i++) { usleep(5000); if (![readReport(directory)[@"status"] isEqual:@"running"]) break; } }
                        } else { usleep(10000); CHECK(!atomic_load(&setupReturned)); }
                        CHECK(!atomic_load(&escaped));
                    } else if (gpuSetup) {
                        pthread_t owner, contender; CHECK(!pthread_create(&owner,NULL,setupWorker,NULL)); pthread_detach(owner);
                        for (int i=0;i<200 && !atomic_load(&setupEntered);i++) usleep(5000);
                        CHECK(atomic_load(&setupEntered)==1);
                        CHECK(!pthread_create(&contender,NULL,setupWorker,NULL)); pthread_detach(contender);
                        usleep(10000); CHECK(atomic_load(&setupEntered)==1 && !atomic_load(&escaped));
                        if (!strcmp(argv[1],"gpu-setup-failure")) dm_boot_probe_failure("synthetic setup failure");
                        else if (!strcmp(argv[1],"gpu-setup-timeout")) CHECK(dm_boot_probe_timeout());
                        else if (!strcmp(argv[1],"gpu-setup-submit") || !strcmp(argv[1],"gpu-setup-wrong-owner")) {
                            pthread_t thread; CHECK(!pthread_create(&thread,NULL,!strcmp(argv[1],"gpu-setup-submit") ? submission : wrongOwner,NULL)); pthread_detach(thread);
                            for (int i=0;i<200;i++) { usleep(5000); if (![readReport(directory)[@"status"] isEqual:@"running"]) break; }
                        } else CHECK(!strcmp(argv[1],"gpu-setup"));
                        atomic_store(&releaseSetup,1);
                        for (int i=0;i<200;i++) { usleep(5000); report=readReport(directory); if (![report[@"status"] isEqual:@"running"]) break; }
                        CHECK(!atomic_load(&escaped) && atomic_load(&setupEntered)==1);
                        CHECK([report[@"gpu_initialization_started"] isEqual:@YES]);
                        CHECK([report[@"gpu_initialization_completed"] boolValue] == !strcmp(argv[1],"gpu-setup"));
                        if (!strcmp(argv[1],"gpu-setup")) CHECK([report[@"gpu_backend"] isEqual:@"synthetic backend"] && [report[@"gpu_device"] isEqual:@"synthetic device"]);
                    } else if (!strcmp(argv[1],"startup-return")) {
                        CHECK(dm_boot_probe_checkpoint("nnMain",1));
                        CHECK(!dm_boot_probe_checkpoint("nnMain",0));
                    } else if (!strcmp(argv[1],"startup-timeout")) CHECK(dm_boot_probe_timeout());
                    else if (!strcmp(argv[1],"startup-gpu") || !strcmp(argv[1],"startup-gpu-entry")) {
                        pthread_t thread; CHECK(!pthread_create(&thread,NULL,!strcmp(argv[1],"startup-gpu-entry") ? gpuEntry : blocked,NULL)); pthread_detach(thread);
                        for (int i=0;i<200;i++) {
                            usleep(5000); report=readReport(directory);
                            if ([report[@"status"] isEqual:@"blocked_before_unverified_operation"]) break;
                        }
                        CHECK([report[@"status"] isEqual:@"blocked_before_unverified_operation"] && !atomic_load(&escaped));
                        CHECK([report[@"current_stage"] isEqual:@"gpu_initialization"]);
                    } else CHECK(0);
                } else CHECK(!dm_boot_probe_checkpoint("nnMain",0));
            }
        } else {
            CHECK(!dm_boot_probe_checkpoint("module_initializers",0));
            CHECK(!dm_boot_probe_checkpoint("nnMain",0));
        }
        CHECK(!dm_boot_probe_timeout());
        report = readReport(directory);
        NSString *status = preSubmit ? !strcmp(argv[1],"pre-submit") ? @"blocked_before_unverified_operation" : !strcmp(argv[1],"pre-submit-timeout") ? @"timeout" : @"failed" : gpuSetup ? !strcmp(argv[1],"gpu-setup") ? @"stopped_after_gpu_initialization" : !strcmp(argv[1],"gpu-setup-timeout") ? @"timeout" : !strcmp(argv[1],"gpu-setup-submit") ? @"blocked_before_unverified_operation" : @"failed" : !strcmp(argv[1],"startup-return") ? @"game_main_returned" : !strcmp(argv[1],"startup-timeout") ? @"timeout" : (!strcmp(argv[1],"startup-gpu") || !strcmp(argv[1],"startup-gpu-entry")) ? @"blocked_before_unverified_operation" : modules ? !strcmp(argv[1],"modules-failure") ? @"failed" : @"stopped_before_game_main" : @"stopped_before_module_initializers";
        CHECK([report[@"status"] isEqual:status]);
        CHECK([report[@"completed_sdk_entries"] intValue] == 6);
        CHECK([report[@"completed_argument_entries"] intValue] == (startup || !strcmp(argv[1],"modules") ? 2 : 0));
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
    CHECK([report[@"game_main_called"] boolValue] == startup);
    CHECK([report[@"game_main_returned"] boolValue] == !strcmp(argv[1],"startup-return"));
    CHECK([report[@"module_initializers_called"] boolValue] == modules);
    CHECK([report[@"module_initializers_completed"] boolValue] == (startup || !strcmp(argv[1],"modules")));
    CHECK([report[@"guest_gpu_work_submitted"] isEqual:@NO]);
    if (!gpuSetup && !preSubmit) CHECK([report[@"gpu_initialization_started"] isEqual:@NO] && [report[@"gpu_initialization_completed"] isEqual:@NO]);
    CHECK([report[@"restart_required"] isEqual:@YES]);
    printf("BOOT PROBE %s OK\n",argv[1]); return 0;
} }
