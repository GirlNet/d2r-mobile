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
// Virtual gamepad ported from seedds/nxnative (see dm_pad.m): 2D / 3D layouts, sticks, D-pad, L3 / R3.
extern UIView *dm_gamepad_view(CGRect frame);
extern void dm_gamepad_reset(void);
extern void dm_haptics_stop(void);
extern void dm_haptics_ios_init(void);
#include <fcntl.h>
#include <unistd.h>
#include <stdatomic.h>

static CAMetalLayer *metalLayer;
static UIViewController *controller;
static int started;
// 只读系统状态，按两秒缓存供宿主计时日志取用；不改变系统功耗或游戏画质。
// Cache read-only system state every two seconds for host timing logs; do not change power policy or game quality.
static _Atomic int powerThermal = -1;
static _Atomic double powerBrightness = -1;
static double powerNextSample;
int dm_thermal_now(void) { return atomic_load_explicit(&powerThermal,memory_order_relaxed); }
double dm_brightness_now(void) { return atomic_load_explicit(&powerBrightness,memory_order_relaxed); }
static void samplePower(BOOL force) {
    double now=CACurrentMediaTime();if(!force && now<powerNextSample)return;powerNextSample=now+2;
    NSProcessInfo *process=NSProcessInfo.processInfo;int thermal=(int)process.thermalState;
    static int previousLow=-1;int low=process.lowPowerModeEnabled;
    int previousThermal=atomic_exchange_explicit(&powerThermal,thermal,memory_order_relaxed);
    double brightness=UIScreen.mainScreen.brightness;
    atomic_store_explicit(&powerBrightness,brightness,memory_order_relaxed);
    if(started && (force || previousThermal!=thermal || previousLow!=low))
        LOG("P5R power: thermal=%d low_power=%d brightness=%.2f active=%d",thermal,low,brightness,
            UIApplication.sharedApplication.applicationState==UIApplicationStateActive);
    previousLow=low;
}
static void *runHost(void *unused);
int dm_main(int argc, char **argv);
static NSString *text(const char *key) { return @(dm_ui(key)); }
static BOOL guardedCandidate(NSDictionary *package) {
    return [package[@"package_kind"] isEqual:@"guarded_runtime_candidate"] &&
        [package[@"experimental_launch_allowed"] isEqual:@YES] && [package[@"runtime_contract_version"] isEqual:@1] &&
        [package[@"game_content_included"] isEqual:@YES] && [package[@"runtime_ready"] isEqual:@NO];
}
static BOOL canLaunch(NSDictionary *package) { return [package[@"runtime_ready"] isEqual:@YES] || guardedCandidate(package); }
void *front_metal_layer(void) { return (__bridge void *)metalLayer; }
uint64_t front_game_res(int docked) { return (uint64_t)(docked ? 900 : 720) << 32 | (docked ? 1600 : 1280); }
void front_run(void (*guest)(void)) { guest(); }
void front_save_failed(int error) { LOG("P5R save transaction failed: %d", error); }
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int cap) {
    if (!controller || !out || cap < 1 || NSThread.isMainThread) return -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block int accepted = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *subtitle=sub?@(sub):@"",*hint=guide?@(guide):@"";
        NSString *message=subtitle.length&&hint.length&&![subtitle isEqual:hint]?[NSString stringWithFormat:@"%@\n%@",subtitle,hint]:subtitle.length?subtitle:hint;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ? @(title) : @"" message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.text = initial ? @(initial) : @"";field.autocorrectionType=UITextAutocorrectionTypeNo;field.spellCheckingType=UITextSpellCheckingTypeNo;
        }];
        __weak UITextField *inputField=alert.textFields.firstObject;
        [alert addAction:[UIAlertAction actionWithTitle:text("dmP5RCancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { (void)action; dispatch_semaphore_signal(done); }]];
        UIAlertAction *accept=[UIAlertAction actionWithTitle:text("dmP5RAccept") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action; const char *value = inputField.text.UTF8String ?: "";
            if (strlen(value) < (size_t)cap) { memcpy(out, value, strlen(value) + 1); accepted = 1; }
            dispatch_semaphore_signal(done);
        }];[alert addAction:accept];
        __weak UIAlertAction *weakAccept=accept;
        void (^validate)(void)=^{
            UITextField *field=inputField;NSString *value=field.text?:@"";
            weakAccept.enabled=field && !field.markedTextRange && (max_chars<=0 || value.length<=(NSUInteger)max_chars)
                && [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<(NSUInteger)cap;
        };
        [inputField addAction:[UIAction actionWithHandler:^(UIAction *action){(void)action;validate();}] forControlEvents:UIControlEventEditingChanged];
        validate();
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
@property UIView *touchControls;
@property UISegmentedControl *renderMode;
@property UILabel *renderHint;
@property UIScrollView *launcherScroll;
@end
@implementation P5RController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
    P5RMetalView *canvas = [P5RMetalView new]; canvas.frame = self.view.bounds;
    canvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    metalLayer = (CAMetalLayer *)canvas.layer; metalLayer.device = MTLCreateSystemDefaultDevice();
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm; metalLayer.framebufferOnly = YES;
    [self.view addSubview:canvas];
    self.touchControls=dm_gamepad_view(self.view.bounds);
    self.touchControls.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.touchControls.hidden=YES;[self.view addSubview:self.touchControls];
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
    [self.bootProbe setTitle:text("dmP5RPreSubmitProbe") forState:UIControlStateNormal];
    [self.bootProbe addTarget:self action:@selector(probeBoot) forControlEvents:UIControlEventTouchUpInside];
    self.renderMode = [[UISegmentedControl alloc] initWithItems:@[text("dmP5RQuality"),text("dmP5RPerformance")]];
    self.renderMode.backgroundColor=[UIColor colorWithWhite:1 alpha:.14];self.renderMode.selectedSegmentTintColor=UIColor.whiteColor;
    [self.renderMode setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateNormal];
    [self.renderMode setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.blackColor} forState:UIControlStateSelected];
    NSInteger saved=[NSUserDefaults.standardUserDefaults integerForKey:@"p5r.renderPreset"];
    self.renderMode.selectedSegmentIndex=saved==1?1:0;
    self.renderMode.accessibilityLabel=text("dmP5RRenderMode");
    [self.renderMode addTarget:self action:@selector(renderModeChanged) forControlEvents:UIControlEventValueChanged];
    self.renderHint=[UILabel new];self.renderHint.font=[UIFont systemFontOfSize:13];
    self.renderHint.textColor=UIColor.lightGrayColor;self.renderHint.numberOfLines=0;self.renderHint.textAlignment=NSTextAlignmentCenter;
    [self renderModeChanged];
    self.menu = [[UIStackView alloc] initWithArrangedSubviews:@[self.status,self.renderMode,self.renderHint,self.launch,self.gpuTest,self.bootProbe,self.gpuStatus]];
    self.menu.axis = UILayoutConstraintAxisVertical; self.menu.spacing = 8;
    UIScrollView *scroll=[UIScrollView new];self.launcherScroll=scroll;scroll.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:scroll];
    UIView *content=[UIView new];content.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:content];
    self.menu.translatesAutoresizingMaskIntoConstraints = NO; [content addSubview:self.menu];
    NSLayoutConstraint *preferredWidth=[self.menu.widthAnchor constraintEqualToConstant:600];preferredWidth.priority=UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *preferredHeight=[content.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor];preferredHeight.priority=UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [content.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],preferredHeight,
        [self.menu.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [self.menu.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [self.menu.widthAnchor constraintLessThanOrEqualToAnchor:content.widthAnchor],preferredWidth,
        [self.menu.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:8],
        [self.menu.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-8],
        [self.renderMode.heightAnchor constraintGreaterThanOrEqualToConstant:36],
        [self.launch.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.bootProbe.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.gpuTest.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
    NSString *path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm/p5r-package.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    self.package = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    BOOL ready = [self.package[@"runtime_ready"] isEqual:@YES];
    self.status.text = text(ready ? "dmP5RReady" : guardedCandidate(self.package) ? "dmP5RCandidate" : self.package ? "dmP5RGraphicsPending" : "dmP5RShell");
    self.launch.enabled = canLaunch(self.package);
    self.bootProbe.enabled = [self.package[@"game_content_included"] isEqual:@YES];
    self.poll = [CADisplayLink displayLinkWithTarget:self selector:@selector(pollController)];
    [self.poll addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; CGSize size = self.view.bounds.size;
    metalLayer.drawableSize = CGSizeMake(size.width * UIScreen.mainScreen.scale, size.height * UIScreen.mainScreen.scale);
}
- (void)renderModeChanged {
    if(started || self.testingGpu)return;
    BOOL performance=self.renderMode.selectedSegmentIndex==1;
    [NSUserDefaults.standardUserDefaults setInteger:performance?1:0 forKey:@"p5r.renderPreset"];
    self.renderHint.text=text(performance?"dmP5RPerformanceHint":"dmP5RQualityHint");
}
- (void)pollController {
    samplePower(NO);
    if (self.probingBoot && CACurrentMediaTime() - self.probePollTime > .5) {
        self.probePollTime = CACurrentMediaTime();
        NSData *data = [NSData dataWithContentsOfFile:[self.probeDirectory stringByAppendingPathComponent:@"boot-report.json"]];
        NSDictionary *report = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (report && ![report[@"status"] isEqual:@"running"])
            self.gpuStatus.text = [NSString stringWithFormat:text("dmP5RBootStopped"),self.probeDirectory.lastPathComponent];
    }
    GCExtendedGamepad *pad = GCController.controllers.firstObject.extendedGamepad;
    BOOL hideTouch=!started || self.probingBoot || pad!=nil;
    if(hideTouch && !self.touchControls.hidden) dm_gamepad_reset();
    self.touchControls.hidden=hideTouch;
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
    if (started || self.testingGpu || !canLaunch(self.package)) return;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *romfs = [documents stringByAppendingPathComponent:@"romfs"];
    if (![NSFileManager.defaultManager fileExistsAtPath:[romfs stringByAppendingPathComponent:@"CPK/ALL_ASIA.CPK"]]) {
        self.status.text = text("dmP5RRomfsMissing"); return;
    }
    started = 1; self.menu.hidden = YES;self.launcherScroll.hidden=YES;self.renderMode.enabled=NO;
    self.touchControls.hidden=NO;
    NSString *save = [documents stringByAppendingPathComponent:@"save-p5r"], *temporary = [documents stringByAppendingPathComponent:@"temp-p5r"];
    for (NSString *directory in @[save, temporary]) [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("DM_GUEST_PROFILE", "p5r", 1); setenv("DM_ROMFS", romfs.fileSystemRepresentation, 1);
    if(guardedCandidate(self.package))setenv("DM_P5R_RUNTIME_MODE","guarded",1);
    else unsetenv("DM_P5R_RUNTIME_MODE");
    setenv("DM_SAVE", save.fileSystemRepresentation, 1); setenv("DM_TEMP", temporary.fileSystemRepresentation, 1);
    setenv("DM_NVN_SHMAP", [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm/shader_map.tsv"].fileSystemRepresentation, 1);
    NSData *identityData=[NSData dataWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm/p5r-shell.json"]];
    NSDictionary *identity=identityData?[NSJSONSerialization JSONObjectWithData:identityData options:0 error:nil]:nil;
    // Keep the large shader cache out of the signed bundle when it has been
    // uploaded to Documents/p5r-shaders; the bundle copy remains the fallback.
    NSString *msl=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"msl"];
    NSString *external=[documents stringByAppendingPathComponent:@"p5r-shaders"];
    NSString *chain=identity[@"shader_chain"];
    if(chain.length&&[NSFileManager.defaultManager fileExistsAtPath:[external stringByAppendingPathComponent:[@"b-" stringByAppendingString:chain]]])msl=external;
    setenv("DM_MSL_DIR", msl.fileSystemRepresentation, 1);
    // Documents/p5r-config.txt：一行一个 KEY=VALUE，给宿主诊断开关用，改完重启游戏即可生效。
    // 只接受 DM_ 前缀，且不允许改写路径 / 归档 / 配置档这些由壳自己决定的键。
    // Documents/p5r-config.txt: one KEY=VALUE per line for host diagnostics; restart the game to apply.
    // Only DM_ keys are accepted, and the ones the shell owns (paths, profile) cannot be overridden.
    { NSString *text = [NSString stringWithContentsOfFile:[documents stringByAppendingPathComponent:@"p5r-config.txt"]
                                                 encoding:NSUTF8StringEncoding error:nil];
      if (text.length) {
        NSMutableArray *applied = [NSMutableArray array];
        for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!line.length || [line hasPrefix:@"#"]) continue;
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSString *value = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (![key hasPrefix:@"DM_"] || ![key length] || ![value length]) continue;
            if ([@[@"DM_ROMFS",@"DM_SAVE",@"DM_TEMP",@"DM_GUEST_PROFILE",@"DM_MSL_DIR"] containsObject:key]) continue;
            setenv(key.UTF8String, value.UTF8String, 1);
            if (applied.count < 16) [applied addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
        }
        if (applied.count) LOG("P5R config: %s", ([applied componentsJoinedByString:@" "]).UTF8String);
      } }
    // 启动菜单是本次画质选择的来源；覆盖旧诊断文件，并同步可能已查询过的运行模式缓存。
    // The launch menu owns this launch's quality choice; override stale diagnostics and update any previously queried operation-mode cache.
    int renderPreset=self.renderMode.selectedSegmentIndex==1?0:1;
    setenv("DM_OPMODE",renderPreset?"1":"0",1);dm_set_opmode(renderPreset);
    { extern void nvn_prof_apply(void); nvn_prof_apply(); }   // 配置读完后才能决定是否套计时包装 | Decide on the timing wrappers only after the config is read
    chdir(documents.fileSystemRepresentation);
    freopen([documents stringByAppendingPathComponent:@"p5r-runtime.log"].fileSystemRepresentation, "a", stderr);
    setvbuf(stderr, NULL, _IONBF, 0); // Preserve final diagnostics even when a guest abort uses _exit.
    LOG("P5R shader directory=%s",msl.fileSystemRepresentation);
    LOG("P5R normal launch build=%s shader_chain=%s mode=%s",[identity[@"source_fingerprint"] UTF8String]?:"unknown",
        [identity[@"shader_chain"] UTF8String]?:"unknown",guardedCandidate(self.package)?"guarded":"ready");
    LOG("P5R render preset: %s operation_mode=%d",renderPreset?"quality":"performance",renderPreset);
    samplePower(YES);
    pthread_attr_t attr; pthread_attr_init(&attr); pthread_attr_setstacksize(&attr, 8 << 20);
    pthread_t thread; if (pthread_create(&thread, &attr, runHost, NULL)) { started = 0; self.menu.hidden = NO;self.launcherScroll.hidden=NO;self.renderMode.enabled=YES; self.status.text = text("dmP5RStartFailed"); }
    else pthread_detach(thread);
    pthread_attr_destroy(&attr);
}
- (void)probeBoot {
    if (started || self.testingGpu || ![self.package[@"game_content_included"] isEqual:@YES]) return;
    NSString *guest = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/Guest.framework/Guest"];
    if (![NSFileManager.defaultManager fileExistsAtPath:guest]) { self.gpuStatus.text = text("dmP5RBootMissing"); return; }
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    BOOL resourceDirectory=NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:[documents stringByAppendingPathComponent:@"romfs"] isDirectory:&resourceDirectory] || !resourceDirectory) {
        self.gpuStatus.text = text("dmP5RStartupNeedsRomfs"); return;
    }
    NSString *directory = [documents stringByAppendingPathComponent:[@"p5r-boot-probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (!dm_boot_probe_begin_pre_submit(directory.fileSystemRepresentation)) { self.gpuStatus.text = text("dmP5RBootReportFailed"); return; }
    started = 1; self.probingBoot = YES; self.probeDirectory = directory;
    self.renderMode.enabled=NO;
    self.launch.enabled = self.gpuTest.enabled = self.bootProbe.enabled = NO;
    self.gpuStatus.text = [NSString stringWithFormat:text("dmP5RPreSubmitRunning"),directory.lastPathComponent];
    int log = open([directory stringByAppendingPathComponent:@"runtime.log"].fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
    if (log < 0) { dm_boot_probe_failure("cannot create runtime.log"); return; }
    int redirected = dup2(log,STDERR_FILENO); close(log);
    if (redirected < 0) { dm_boot_probe_failure("cannot redirect runtime.log"); return; }
    setenv("DM_GUEST_PROFILE","p5r",1); setenv("DM_BOOTPROF","1",1); setenv("DM_IMPORTS","1",1);
    setenv("DM_FS","1",1);
    if (chdir(directory.fileSystemRepresentation)) { dm_boot_probe_failure("cannot enter isolated diagnostic directory"); return; }
    setenv("DM_ROMFS",[documents stringByAppendingPathComponent:@"romfs"].fileSystemRepresentation,1);
    BOOL isDirectory=NO;
    BOOL romfs=[NSFileManager.defaultManager fileExistsAtPath:[documents stringByAppendingPathComponent:@"romfs"] isDirectory:&isDirectory] && isDirectory;
    dm_boot_probe_note("romfs_root",romfs ? "directory exists; contents unverified" : "directory is missing");
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
    self.renderMode.enabled=NO;
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
            self.renderMode.enabled=YES;
            self.bootProbe.enabled = [self.package[@"game_content_included"] isEqual:@YES];
            self.launch.enabled = canLaunch(self.package);
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
    (void)application; (void)options; dm_haptics_ios_init(); self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    controller = [P5RController new]; self.window.rootViewController = controller; [self.window makeKeyAndVisible]; return YES;
}
- (void)applicationWillResignActive:(UIApplication *)application {
    (void)application; (void)controller; dm_gamepad_reset(); dm_input_release_all(); dm_haptics_stop();
    if (started && !dm_boot_probe_active()) { guest_clock_freeze_for(1, 1); dm_audio_suspend(1); dm_gfx_suspend(1); }
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application; if (started && !dm_boot_probe_active()) { dm_gfx_suspend(0); dm_audio_suspend(0); guest_clock_freeze_for(1, 0); }
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(P5RApp.class)); } }
