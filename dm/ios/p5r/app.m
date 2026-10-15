// P5R 专用 UIKit/Metal 前端：真实宿主入口、原生文本输入和直接手柄状态；资源就绪由本地包清单控制。
// Dedicated P5R UIKit/Metal front end: real host entry, native text input and direct controller state; local package metadata controls resource readiness.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#include "dm.h"
#include "hle.h"
#include "front.h"
#include "dm_input.h"
#include "dm_i18n.h"
#include "../../gfx/nvn/nvn_texture_selftest.h"
#include "boot_probe.h"
#include <fcntl.h>
#include <unistd.h>

static CAMetalLayer *metalLayer;
static UIViewController *controller;
static int started;
static void *runHost(void *unused);
int dm_main(int argc, char **argv);
static NSString *text(const char *key) { return @(dm_ui(key)); }
void *front_metal_layer(void) { return (__bridge void *)metalLayer; }
uint64_t front_game_res(int docked) { return (uint64_t)(docked ? 900 : 720) << 32 | (docked ? 1600 : 1280); }
void front_run(void (*guest)(void)) { guest(); }
void front_save_failed(int error) { LOG("P5R save transaction failed: %d", error); }
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int cap) {
    if (!controller || !out || cap < 1 || NSThread.isMainThread) return -1;
    (void)guide; (void)max_chars;
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block int accepted = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ? @(title) : @"" message:sub ? @(sub) : @"" preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = initial ? @(initial) : @""; }];
        [alert addAction:[UIAlertAction actionWithTitle:text("dmP5RCancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { (void)action; dispatch_semaphore_signal(done); }]];
        [alert addAction:[UIAlertAction actionWithTitle:text("dmP5RAccept") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action; const char *value = alert.textFields.firstObject.text.UTF8String ?: "";
            if (strlen(value) < (size_t)cap) { memcpy(out, value, strlen(value) + 1); accepted = 1; }
            dispatch_semaphore_signal(done);
        }]];
        [controller presentViewController:alert animated:YES completion:nil];
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER); return accepted;
}

@interface P5RMetalView : UIView @end
@implementation P5RMetalView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

@interface P5RController : UIViewController
@property UILabel *status;
@property UIButton *launch;
@property UIButton *gpuTest;
@property UILabel *gpuStatus;
@property UIStackView *menu;
@property BOOL testingGpu;
@property UIButton *bootProbe;
@property BOOL probingBoot;
@property NSString *probeDirectory;
@property double probePollTime;
@property CADisplayLink *poll;
@property NSDictionary *package;
@end
@implementation P5RController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
    P5RMetalView *canvas = [P5RMetalView new]; canvas.frame = self.view.bounds;
    canvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    metalLayer = (CAMetalLayer *)canvas.layer; metalLayer.device = MTLCreateSystemDefaultDevice();
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm; metalLayer.framebufferOnly = YES;
    [self.view addSubview:canvas];
    self.status = [UILabel new]; self.status.textColor = UIColor.whiteColor; self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter; self.status.translatesAutoresizingMaskIntoConstraints = NO;
    self.launch = [UIButton buttonWithType:UIButtonTypeSystem]; self.launch.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launch setTitle:text("dmP5RLaunch") forState:UIControlStateNormal];
    [self.launch addTarget:self action:@selector(startGuest) forControlEvents:UIControlEventTouchUpInside];
    self.gpuTest = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.gpuTest setTitle:text("dmP5RGpuTest") forState:UIControlStateNormal];
    [self.gpuTest addTarget:self action:@selector(testGpu) forControlEvents:UIControlEventTouchUpInside];
    self.gpuStatus = [UILabel new]; self.gpuStatus.textColor = UIColor.lightGrayColor;
    self.gpuStatus.font = [UIFont systemFontOfSize:13]; self.gpuStatus.numberOfLines = 0;
    self.gpuStatus.textAlignment = NSTextAlignmentCenter;
    self.bootProbe = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.bootProbe setTitle:text("dmP5RModuleProbe") forState:UIControlStateNormal];
    [self.bootProbe addTarget:self action:@selector(probeBoot) forControlEvents:UIControlEventTouchUpInside];
    self.menu = [[UIStackView alloc] initWithArrangedSubviews:@[self.status,self.launch,self.gpuTest,self.bootProbe,self.gpuStatus]];
    self.menu.axis = UILayoutConstraintAxisVertical; self.menu.spacing = 12;
    self.menu.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.menu];
    [NSLayoutConstraint activateConstraints:@[
        [self.menu.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.menu.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.menu.widthAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor constant:-40],
        [self.launch.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.bootProbe.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.gpuTest.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
    NSString *path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm/p5r-package.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    self.package = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    BOOL ready = [self.package[@"runtime_ready"] isEqual:@YES];
    self.status.text = text(ready ? "dmP5RReady" : self.package ? "dmP5RGraphicsPending" : "dmP5RShell");
    self.launch.enabled = ready;
    self.bootProbe.enabled = [self.package[@"game_content_included"] isEqual:@YES];
    self.poll = [CADisplayLink displayLinkWithTarget:self selector:@selector(pollController)];
    [self.poll addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; CGSize size = self.view.bounds.size;
    metalLayer.drawableSize = CGSizeMake(size.width * UIScreen.mainScreen.scale, size.height * UIScreen.mainScreen.scale);
}
- (void)pollController {
    if (self.probingBoot && CACurrentMediaTime() - self.probePollTime > .5) {
        self.probePollTime = CACurrentMediaTime();
        NSData *data = [NSData dataWithContentsOfFile:[self.probeDirectory stringByAppendingPathComponent:@"boot-report.json"]];
        NSDictionary *report = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (report && ![report[@"status"] isEqual:@"running"])
            self.gpuStatus.text = [NSString stringWithFormat:text("dmP5RBootStopped"),self.probeDirectory.lastPathComponent];
    }
    GCExtendedGamepad *pad = GCController.controllers.firstObject.extendedGamepad;
    if (!pad || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { dm_pad_set(0,0,0,0,0); return; }
    uint64_t buttons = 0;
    // 系统字段按位置命名；这里按 Switch 位置输出，右 A、下 B、上 X、左 Y。
    // System fields name positions; publish Switch positions: right A, bottom B, top X, left Y.
    GCControllerButtonInput *inputs[] = {pad.buttonB,pad.buttonA,pad.buttonY,pad.buttonX,pad.leftThumbstickButton,pad.rightThumbstickButton,
        pad.leftShoulder,pad.rightShoulder,pad.leftTrigger,pad.rightTrigger,pad.buttonMenu,pad.buttonOptions,
        pad.dpad.left,pad.dpad.up,pad.dpad.right,pad.dpad.down};
    for (int i = 0; i < 16; i++) if (inputs[i].pressed) buttons |= UINT64_C(1) << i;
    dm_pad_set(buttons, pad.leftThumbstick.xAxis.value * 32767, pad.leftThumbstick.yAxis.value * 32767,
               pad.rightThumbstick.xAxis.value * 32767, pad.rightThumbstick.yAxis.value * 32767);
}
- (void)startGuest {
    if (started || self.testingGpu || ![self.package[@"runtime_ready"] isEqual:@YES]) return;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *romfs = [documents stringByAppendingPathComponent:@"romfs"];
    if (![NSFileManager.defaultManager fileExistsAtPath:[romfs stringByAppendingPathComponent:@"CPK/ALL_ASIA.CPK"]]) {
        self.status.text = text("dmP5RRomfsMissing"); return;
    }
    started = 1; self.menu.hidden = YES;
    NSString *save = [documents stringByAppendingPathComponent:@"save-p5r"], *temporary = [documents stringByAppendingPathComponent:@"temp-p5r"];
    for (NSString *directory in @[save, temporary]) [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("DM_GUEST_PROFILE", "p5r", 1); setenv("DM_ROMFS", romfs.fileSystemRepresentation, 1);
    setenv("DM_SAVE", save.fileSystemRepresentation, 1); setenv("DM_TEMP", temporary.fileSystemRepresentation, 1);
    setenv("DM_NVN_SHMAP", [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm/shader_map.tsv"].fileSystemRepresentation, 1);
    setenv("DM_MSL_DIR", [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"msl"].fileSystemRepresentation, 1);
    chdir(documents.fileSystemRepresentation);
    freopen([documents stringByAppendingPathComponent:@"p5r-runtime.log"].fileSystemRepresentation, "a", stderr);
    pthread_attr_t attr; pthread_attr_init(&attr); pthread_attr_setstacksize(&attr, 8 << 20);
    pthread_t thread; if (pthread_create(&thread, &attr, runHost, NULL)) { started = 0; self.menu.hidden = NO; self.status.text = text("dmP5RStartFailed"); }
    else pthread_detach(thread);
    pthread_attr_destroy(&attr);
}
- (void)probeBoot {
    if (started || self.testingGpu || ![self.package[@"game_content_included"] isEqual:@YES]) return;
    NSString *guest = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/Guest.framework/Guest"];
    if (![NSFileManager.defaultManager fileExistsAtPath:guest]) { self.gpuStatus.text = text("dmP5RBootMissing"); return; }
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *directory = [documents stringByAppendingPathComponent:[@"p5r-boot-probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (!dm_boot_probe_begin_modules(directory.fileSystemRepresentation)) { self.gpuStatus.text = text("dmP5RBootReportFailed"); return; }
    started = 1; self.probingBoot = YES; self.probeDirectory = directory;
    self.launch.enabled = self.gpuTest.enabled = self.bootProbe.enabled = NO;
    self.gpuStatus.text = [NSString stringWithFormat:text("dmP5RModuleRunning"),directory.lastPathComponent];
    int log = open([directory stringByAppendingPathComponent:@"runtime.log"].fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
    if (log < 0) { dm_boot_probe_failure("cannot create runtime.log"); return; }
    int redirected = dup2(log,STDERR_FILENO); close(log);
    if (redirected < 0) { dm_boot_probe_failure("cannot redirect runtime.log"); return; }
    setenv("DM_GUEST_PROFILE","p5r",1); setenv("DM_BOOTPROF","1",1); setenv("DM_IMPORTS","1",1);
    if (chdir(directory.fileSystemRepresentation)) { dm_boot_probe_failure("cannot enter isolated diagnostic directory"); return; }
    setenv("DM_ROMFS",[documents stringByAppendingPathComponent:@"romfs"].fileSystemRepresentation,1);
    for (NSString *name in @[@"save",@"temp"]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:nil]) {
            dm_boot_probe_failure("cannot create isolated save/temp directories"); return;
        }
        setenv([name isEqual:@"save"] ? "DM_SAVE":"DM_TEMP",path.fileSystemRepresentation,1);
    }
    pthread_attr_t attr; pthread_attr_init(&attr); pthread_attr_setstacksize(&attr,8<<20);
    pthread_t thread; int error = pthread_create(&thread,&attr,runHost,NULL); pthread_attr_destroy(&attr);
    if (error) dm_boot_probe_failure("cannot create diagnostic host thread");
    else pthread_detach(thread);
}
- (void)testGpu {
    if (started || self.testingGpu) return;
    self.testingGpu = YES; self.launch.enabled = self.gpuTest.enabled = NO;
    self.bootProbe.enabled = NO;
    self.gpuStatus.text = text("dmP5RGpuRunning");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        int result = nvn_texture_selftest();
        BOOL passed3 = result == 0 || result == NVN_TEXTURE_SELFTEST_METAL4_UNSUPPORTED;
        NSDictionary *report = @{@"schema_version":@1, @"synthetic_only":@YES, @"result_code":@(result),
            @"metal3_passed":@(passed3), @"metal4_passed":@(result == 0),
            @"metal4_skipped":@(result == NVN_TEXTURE_SELFTEST_METAL4_UNSUPPORTED),
            @"cases_passed":@(result == 0 ? 96 : passed3 ? 48 : 0), @"game_graphics_verified":@NO,
            @"time":@([NSDate.date timeIntervalSince1970]), @"os_version":NSProcessInfo.processInfo.operatingSystemVersionString};
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSString *path = [documents stringByAppendingPathComponent:@"p5r-gpu-selftest.json"];
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
        BOOL saved = data && [data writeToFile:path options:NSDataWritingAtomic error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.testingGpu = NO; self.gpuTest.enabled = YES;
            self.bootProbe.enabled = [self.package[@"game_content_included"] isEqual:@YES];
            self.launch.enabled = [self.package[@"runtime_ready"] isEqual:@YES];
            if (!saved) self.gpuStatus.text = [NSString stringWithFormat:text("dmP5RGpuSaveFailed"),result];
            else if (result == 0) self.gpuStatus.text = text("dmP5RGpuPassed");
            else if (result == NVN_TEXTURE_SELFTEST_METAL4_UNSUPPORTED) self.gpuStatus.text = text("dmP5RGpuPartial");
            else if (result == NVN_TEXTURE_SELFTEST_NO_DEVICE) self.gpuStatus.text = text("dmP5RGpuNoDevice");
            else self.gpuStatus.text = [NSString stringWithFormat:text("dmP5RGpuFailed"),result];
        });
    });
}
static void *runHost(void *unused) {
    (void)unused; @autoreleasepool {
        char *args[] = {"p5r-host", strdup([NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"].fileSystemRepresentation), "main", "sdk", "subsdk0", NULL};
        dm_main(5, args); free(args[1]);
    } return NULL;
}
@end

@interface P5RApp : UIResponder <UIApplicationDelegate>
@property UIWindow *window;
@end
@implementation P5RApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options; self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    controller = [P5RController new]; self.window.rootViewController = controller; [self.window makeKeyAndVisible]; return YES;
}
- (void)applicationWillResignActive:(UIApplication *)application {
    (void)application; dm_pad_set(0,0,0,0,0);
    if (started && !dm_boot_probe_active()) { guest_clock_freeze_for(1, 1); dm_audio_suspend(1); dm_gfx_suspend(1); }
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application; if (started && !dm_boot_probe_active()) { dm_gfx_suspend(0); dm_audio_suspend(0); guest_clock_freeze_for(1, 0); }
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(P5RApp.class)); } }
