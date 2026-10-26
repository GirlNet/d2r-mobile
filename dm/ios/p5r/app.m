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
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "resources.h"
#import "dm_pad.h"
#import "pad_editor.h"
#include "boot_probe.h"
#include "player_config.h"
// 移植自 nxnative 的虚拟手柄：左摇杆、按钮和相对滑动视角；显示节拍负责清除停手后的镜头输入。
// Virtual pad adapted from nxnative: left stick, buttons and relative camera swipes; the display tick clears idle camera input.
extern void dm_haptics_stop(void);
extern void dm_haptics_ios_init(void);
#include <fcntl.h>
#include <unistd.h>
#include <stdatomic.h>

static CAMetalLayer *metalLayer;
static UIViewController *controller;
static int started;
static NSURL *activeExternalRoot;
// 只读系统状态，按两秒缓存供宿主计时日志取用；不改变系统功耗或游戏画质。
// Cache read-only system state every two seconds for host timing logs; do not change power policy or game quality.
#if DM_RUNTIME_DIAGNOSTICS
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
#else
int dm_thermal_now(void) { return -1; }
double dm_brightness_now(void) { return -1; }
static void samplePower(BOOL force) { (void)force; }
#endif
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

// 原生启动界面：只呈现资源、设置和开始游戏；装饰不拦截游戏输入。
// Native launcher: expose resources, settings and Start Game only; decoration never intercepts game input.
@interface P5RBackdrop : UIView @end
@implementation P5RBackdrop
- (void)drawRect:(CGRect)rect {
    (void)rect;CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    // 按设备选择本地背景，居中等比铺满；左侧与底部遮罩保证菜单可读。
    // Choose local artwork by device and fill proportionally; shade the left and bottom for readable controls.
    NSString *name=UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPad?@"MenuBackground-iPad":@"MenuBackground-iPhone";
    UIImage *image=[UIImage imageNamed:name];
    if(image && image.size.width>0 && image.size.height>0) {
        CGFloat scale=MAX(w/image.size.width,h/image.size.height);
        CGSize size=CGSizeMake(image.size.width*scale,image.size.height*scale);
        [image drawInRect:CGRectMake((w-size.width)/2,(h-size.height)/2,size.width,size.height)];
        CGContextRef context=UIGraphicsGetCurrentContext();CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGFloat locations[]={0,.48,1};CGFloat left[]={0,0,0,.72,0,0,0,.35,0,0,0,0};
        CGGradientRef gradient=CGGradientCreateWithColorComponents(space,left,locations,3);
        CGContextDrawLinearGradient(context,gradient,CGPointZero,CGPointMake(w*.78,0),kCGGradientDrawsAfterEndLocation);
        CGGradientRelease(gradient);
        CGFloat bottom[]={0,0,0,0,0,0,0,.6};
        gradient=CGGradientCreateWithColorComponents(space,bottom,NULL,2);
        CGContextDrawLinearGradient(context,gradient,CGPointMake(0,h*.68),CGPointMake(0,h),kCGGradientDrawsAfterEndLocation);
        CGGradientRelease(gradient);CGColorSpaceRelease(space);return;
    }
    // 公共宿主不带本地图片时仍可显示菜单。
    // Keep the menu usable when a public shell has no local artwork.
    [[UIColor colorWithWhite:.045 alpha:1] setFill];UIRectFill(self.bounds);
    UIBezierPath *panel=[UIBezierPath bezierPath];[panel moveToPoint:CGPointMake(w*.76,0)];
    [panel addLineToPoint:CGPointMake(w,0)];[panel addLineToPoint:CGPointMake(w,h)];
    [panel addLineToPoint:CGPointMake(w*.5,h)];[panel closePath];
    [[UIColor colorWithRed:.38 green:.025 blue:.055 alpha:1] setFill];[panel fill];
    UIBezierPath *stripe=[UIBezierPath bezierPath];[stripe moveToPoint:CGPointMake(w*.76-12,0)];
    [stripe addLineToPoint:CGPointMake(w*.76-4,0)];[stripe addLineToPoint:CGPointMake(w*.5-4,h)];
    [stripe addLineToPoint:CGPointMake(w*.5-12,h)];[stripe closePath];
    [[UIColor colorWithRed:.93 green:.06 blue:.13 alpha:1] setFill];[stripe fill];
}
@end

@interface P5RController : UIViewController <UIDocumentPickerDelegate>
@property UILabel *status;
@property UIButton *launch;
@property UIButton *settingsButton;
@property UIButton *layoutButton;
@property UIButton *resourceButton;
@property UIView *launcherView;
@property CADisplayLink *poll;
@property NSDictionary *package;
@property NSDictionary *identity;
@property UIView *touchControls;
@property UISegmentedControl *renderMode;
@property UILabel *renderHint;
@property NSURL *resourceURL;
@property BOOL resourceLease;
@property NSDictionary<NSString *,NSURL *> *resourcePaths;
@property BOOL checkingResources;
- (void)launchResolvedGuest;
- (void)validateURL:(NSURL *)url save:(BOOL)save launch:(BOOL)launch;
@end
@implementation P5RController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UIButton *)button:(const char *)key action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;
    [button setTitle:text(key) forState:UIControlStateNormal];[button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font=[UIFont boldSystemFontOfSize:17];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.view.backgroundColor=UIColor.blackColor;
    P5RMetalView *canvas=[P5RMetalView new];canvas.frame=self.view.bounds;
    canvas.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    metalLayer=(CAMetalLayer *)canvas.layer;metalLayer.device=MTLCreateSystemDefaultDevice();
    metalLayer.pixelFormat=MTLPixelFormatBGRA8Unorm;metalLayer.framebufferOnly=YES;[self.view addSubview:canvas];
    self.touchControls=dm_gamepad_view(self.view.bounds);self.touchControls.autoresizingMask=canvas.autoresizingMask;
    self.touchControls.hidden=YES;[self.view addSubview:self.touchControls];
    P5RBackdrop *menu=[P5RBackdrop new];menu.frame=self.view.bounds;menu.autoresizingMask=canvas.autoresizingMask;
    menu.contentMode=UIViewContentModeRedraw;self.launcherView=menu;[self.view addSubview:menu];
    UILabel *title=[UILabel new];title.translatesAutoresizingMaskIntoConstraints=NO;title.text=text("dmP5RMenuTitle");
    title.font=[UIFont systemFontOfSize:46 weight:UIFontWeightBlack];title.textColor=UIColor.whiteColor;
    title.adjustsFontSizeToFitWidth=YES;title.minimumScaleFactor=.6;[menu addSubview:title];
    UILabel *subtitle=[UILabel new];subtitle.translatesAutoresizingMaskIntoConstraints=NO;subtitle.text=text("dmP5RMenuSubtitle");
    subtitle.font=[UIFont systemFontOfSize:15];subtitle.textColor=UIColor.lightGrayColor;[menu addSubview:subtitle];
    self.launch=[self button:"dmP5RLaunch" action:@selector(startGuest)];self.launch.backgroundColor=[UIColor colorWithRed:.91 green:.035 blue:.11 alpha:1];
    self.launch.layer.cornerRadius=10;[menu addSubview:self.launch];
    self.settingsButton=[self button:"dmP5RSettings" action:@selector(showSettings)];
    self.layoutButton=[self button:"dmP5RPadLayout" action:@selector(showPadLayout)];
    UIStackView *actions=[[UIStackView alloc] initWithArrangedSubviews:@[self.settingsButton,self.layoutButton]];
    actions.spacing=20;actions.translatesAutoresizingMaskIntoConstraints=NO;[menu addSubview:actions];
    self.resourceButton=[self button:"dmP5RChooseResources" action:@selector(pickResourceFolder)];
    [self.resourceButton setTitleColor:[UIColor colorWithRed:1 green:.35 blue:.4 alpha:1] forState:UIControlStateNormal];
    self.status=[UILabel new];self.status.textColor=UIColor.lightGrayColor;self.status.numberOfLines=0;self.status.font=[UIFont systemFontOfSize:15];
    UILabel *resourceTitle=[UILabel new];resourceTitle.text=text("dmP5RResourcesTitle");resourceTitle.textColor=UIColor.whiteColor;
    resourceTitle.font=[UIFont boldSystemFontOfSize:19];
    UIStackView *resources=[[UIStackView alloc] initWithArrangedSubviews:@[resourceTitle,self.status,self.resourceButton]];
    resources.axis=UILayoutConstraintAxisVertical;resources.spacing=12;resources.alignment=UIStackViewAlignmentLeading;
    resources.translatesAutoresizingMaskIntoConstraints=NO;
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;[menu addSubview:scroll];[scroll addSubview:resources];
    UILayoutGuide *safe=menu.safeAreaLayoutGuide;
    NSLayoutConstraint *panelWidth=[scroll.widthAnchor constraintEqualToConstant:520];panelWidth.priority=UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *startWidth=[self.launch.widthAnchor constraintEqualToConstant:220];startWidth.priority=UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],[title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],[subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],
        [self.launch.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [self.launch.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],[self.launch.heightAnchor constraintEqualToConstant:56],startWidth,
        [self.launch.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor multiplier:.48],
        [actions.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [actions.centerYAnchor constraintEqualToAnchor:self.launch.centerYAnchor],[actions.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [actions.trailingAnchor constraintLessThanOrEqualToAnchor:self.launch.leadingAnchor constant:-16],
        [scroll.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],[scroll.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],panelWidth,
        [scroll.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:22],[scroll.bottomAnchor constraintEqualToAnchor:self.launch.topAnchor constant:-16],
        [resources.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [resources.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [resources.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [resources.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [resources.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [self.resourceButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
    self.renderMode=[[UISegmentedControl alloc] initWithItems:@[text("dmP5RQuality"),text("dmP5RPerformance")]];
    self.renderMode.selectedSegmentTintColor=[UIColor colorWithRed:.85 green:.025 blue:.1 alpha:1];
    [self.renderMode setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateNormal];
    [self.renderMode setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateSelected];
    self.renderMode.selectedSegmentIndex=[NSUserDefaults.standardUserDefaults integerForKey:@"p5r.renderPreset"]==1?1:0;
    self.renderMode.accessibilityLabel=text("dmP5RRenderMode");
    [self.renderMode addTarget:self action:@selector(renderModeChanged) forControlEvents:UIControlEventValueChanged];
    self.renderHint=[UILabel new];self.renderHint.textColor=UIColor.lightGrayColor;self.renderHint.font=[UIFont systemFontOfSize:15];self.renderHint.numberOfLines=0;
    [self renderModeChanged];
    NSURL *dm=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"dm"];
    self.package=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:[dm URLByAppendingPathComponent:@"p5r-package.json"]]?:[NSData data] options:0 error:nil];
    self.identity=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:[dm URLByAppendingPathComponent:@"p5r-shell.json"]]?:[NSData data] options:0 error:nil];
    NSData *bookmark=[NSUserDefaults.standardUserDefaults dataForKey:@"p5r.resourceFolder"];
    BOOL stale=NO;NSURL *saved=bookmark?[NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:&stale error:nil]:nil;
    NSURL *documents=[NSURL fileURLWithPath:NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject isDirectory:YES];
    if(bookmark && !saved) {self.status.text=text("dmP5RResourcesAccess");self.launch.enabled=NO;}
    else [self validateURL:saved?:documents save:bookmark!=nil launch:NO];
    self.poll=[CADisplayLink displayLinkWithTarget:self selector:@selector(pollController)];[self.poll addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];CGSize size=self.view.bounds.size;
    metalLayer.drawableSize=CGSizeMake(size.width*UIScreen.mainScreen.scale,size.height*UIScreen.mainScreen.scale);
}
- (void)renderModeChanged {
    if(started)return;BOOL performance=self.renderMode.selectedSegmentIndex==1;
    [NSUserDefaults.standardUserDefaults setInteger:performance?1:0 forKey:@"p5r.renderPreset"];
    self.renderHint.text=text(performance?"dmP5RPerformanceHint":"dmP5RQualityHint");
}
- (void)showSettings {
    if(started || self.checkingResources)return;
    UIViewController *settings=[UIViewController new];settings.title=text("dmP5RSettings");settings.view.backgroundColor=[UIColor colorWithWhite:.08 alpha:1];
    settings.preferredContentSize=CGSizeMake(500,300);
    settings.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:text("dmP5RDone") style:UIBarButtonItemStyleDone target:self action:@selector(closeSettings)];
    UILabel *label=[UILabel new];label.text=text("dmP5RRenderMode");label.textColor=UIColor.whiteColor;label.font=[UIFont boldSystemFontOfSize:20];
    UILabel *note=[UILabel new];note.text=text("dmP5RSettingsHint");note.textColor=UIColor.lightGrayColor;note.numberOfLines=0;note.font=[UIFont systemFontOfSize:14];
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,self.renderMode,self.renderHint,note]];
    stack.axis=UILayoutConstraintAxisVertical;stack.spacing=20;stack.translatesAutoresizingMaskIntoConstraints=NO;[settings.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:settings.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:settings.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:settings.view.safeAreaLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:settings.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [self.renderMode.heightAnchor constraintGreaterThanOrEqualToConstant:40]]];
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:settings];
    navigation.modalPresentationStyle=UIModalPresentationFormSheet;[self presentViewController:navigation animated:YES completion:nil];
}
- (void)closeSettings {[self dismissViewControllerAnimated:YES completion:nil];}
- (void)showPadLayout {
    if(started || self.checkingResources)return;
    P5RPadEditor *editor=[P5RPadEditor new];editor.modalPresentationStyle=UIModalPresentationFullScreen;
    [self presentViewController:editor animated:YES completion:nil];
}
- (void)pickResourceFolder {
    if(started || self.checkingResources)return;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate=self;picker.allowsMultipleSelection=NO;picker.directoryURL=self.resourceURL;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)picker;if(urls.firstObject)[self validateURL:urls.firstObject save:YES launch:NO];
}
- (void)validateURL:(NSURL *)url save:(BOOL)save launch:(BOOL)launch {
    if(started || self.checkingResources || !url)return;
    self.checkingResources=YES;self.launch.enabled=self.settingsButton.enabled=self.layoutButton.enabled=self.resourceButton.enabled=NO;
    self.status.text=text("dmP5RResourcesChecking");
    BOOL lease=[url startAccessingSecurityScopedResource];
    NSURL *documents=[NSURL fileURLWithPath:NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject isDirectory:YES];
    BOOL legacy=[url.URLByResolvingSymlinksInPath.path isEqual:documents.URLByResolvingSymlinksInPath.path];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ @autoreleasepool {
        __block NSString *errorKey=@"dmP5RResourcesAccess";__block NSDictionary *paths=nil;
        NSError *coordinationError=nil;NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&coordinationError byAccessor:^(NSURL *coordinated) {
            paths=p5r_resources(coordinated,self.identity[@"shader_chain"],self.package[@"guest_sha256"],
                [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"dm"],legacy,&errorKey);
        }];
        if(coordinationError){paths=nil;errorKey=@"dmP5RResourcesAccess";}
        NSData *bookmark=paths&&save?[url bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark includingResourceValuesForKeys:nil relativeToURL:nil error:nil]:nil;
        if(paths && save && !bookmark){paths=nil;errorKey=@"dmP5RResourcesAccess";}
        dispatch_async(dispatch_get_main_queue(), ^{
            self.checkingResources=NO;self.settingsButton.enabled=self.layoutButton.enabled=self.resourceButton.enabled=YES;
            if(paths) {
                if(self.resourceLease)[self.resourceURL stopAccessingSecurityScopedResource];
                self.resourceURL=url;self.resourceLease=lease;self.resourcePaths=paths;
                if(bookmark)[NSUserDefaults.standardUserDefaults setObject:bookmark forKey:@"p5r.resourceFolder"];
                self.status.text=[NSString stringWithFormat:text("dmP5RResourcesReady"),legacy?text("dmP5RResourcesLocal"):url.lastPathComponent];
            } else {
                if(lease)[url stopAccessingSecurityScopedResource];
                self.status.text=text((errorKey?:@"dmP5RResourcesIncomplete").UTF8String);
                if(launch)self.resourcePaths=nil;
                else if(self.resourcePaths)self.status.text=[NSString stringWithFormat:text("dmP5RResourcesKept"),self.status.text,self.resourceURL.lastPathComponent];
            }
            BOOL component=[NSFileManager.defaultManager fileExistsAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/Guest.framework/Guest"]];
            self.launch.enabled=self.resourcePaths!=nil && component && canLaunch(self.package);
            if(!component)self.status.text=text("dmP5RResourcesNoProgram");
            if(launch && paths && self.launch.enabled)[self launchResolvedGuest];
        });
    }});
}
- (void)pollController {
    samplePower(NO);
    GCExtendedGamepad *pad = GCController.controllers.firstObject.extendedGamepad;
    BOOL active=UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
    BOOL hideTouch=!started || pad!=nil || !active;
    if(hideTouch && !self.touchControls.hidden) dm_gamepad_reset();
    self.touchControls.hidden=hideTouch;
    if(!hideTouch)dm_gamepad_frame(CACurrentMediaTime());
    if (!pad || !active) { dm_pad_set(0,0,0,0,0); return; }
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
- (void)startGuest {if(self.resourceURL)[self validateURL:self.resourceURL save:NO launch:YES];}
- (void)launchResolvedGuest {
    if (started || !self.resourcePaths || !canLaunch(self.package)) return;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *romfs = self.resourcePaths[@"romfs"].path;
    if (![NSFileManager.defaultManager fileExistsAtPath:[romfs stringByAppendingPathComponent:@"CPK/ALL_ASIA.CPK"]]) {
        self.resourcePaths=nil;self.launch.enabled=NO;self.status.text=text("dmP5RResourcesIncomplete");return;
    }
    started = 1;self.launcherView.hidden=YES;self.renderMode.enabled=NO;
    UIApplication.sharedApplication.idleTimerDisabled=YES;
    NSString *homePrefix=[[[NSURL fileURLWithPath:NSHomeDirectory()] URLByResolvingSymlinksInPath].path stringByAppendingString:@"/"];
    activeExternalRoot=[self.resourceURL.URLByResolvingSymlinksInPath.path hasPrefix:homePrefix]?nil:self.resourceURL;
    self.touchControls.hidden=NO;
    NSString *save = [documents stringByAppendingPathComponent:@"save-p5r"], *temporary = [documents stringByAppendingPathComponent:@"temp-p5r"];
    for (NSString *directory in @[save, temporary]) [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("DM_GUEST_PROFILE", "p5r", 1); setenv("DM_ROMFS", romfs.fileSystemRepresentation, 1);
    if(guardedCandidate(self.package))setenv("DM_P5R_RUNTIME_MODE","guarded",1);
    else unsetenv("DM_P5R_RUNTIME_MODE");
    setenv("DM_SAVE", save.fileSystemRepresentation, 1); setenv("DM_TEMP", temporary.fileSystemRepresentation, 1);
    setenv("DM_NVN_SHMAP",self.resourcePaths[@"map"].fileSystemRepresentation,1);
    NSDictionary *identity=self.identity;
    NSString *msl=self.resourcePaths[@"shaders"].path;
    setenv("DM_MSL_DIR",msl.fileSystemRepresentation,1);
    // 玩家构建只读取已验证的兼容性覆盖；开发构建仍接受 DM_ 诊断键，路径与配置档始终由壳管理。
    // Player builds accept verified compatibility overrides only; developer builds accept DM_ diagnostics, while paths and profile remain shell-owned.
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
            if ([@[@"DM_ROMFS",@"DM_SAVE",@"DM_TEMP",@"DM_GUEST_PROFILE",@"DM_MSL_DIR",@"DM_NVN_SHMAP"] containsObject:key]) continue;
            if(!DM_RUNTIME_DIAGNOSTICS && !p5r_player_config_allowed(key.UTF8String,value.UTF8String))continue;
            setenv(key.UTF8String, value.UTF8String, 1);
            if (applied.count < 16) [applied addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
        }
        if (applied.count) LOG("P5R config: %s", ([applied componentsJoinedByString:@" "]).UTF8String);
      } }
#if !DM_RUNTIME_DIAGNOSTICS
    // 未采纳的测试路径保持关闭，玩家配置无法重新开启。
    // Keep unadopted test paths off, regardless of older player configuration files.
    setenv("DM_P5R_COMPUTE_BATCH","0",1);setenv("DM_P5R_RT_CONTINUE","0",1);
    setenv("DM_P5R_NO_DEPTHBOUNDS","1",1);setenv("DM_P5R_SKIP_DEPTH_DRAW","0",1);setenv("DM_P5R_COND_IGNORE","1",1);
#endif
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
    pthread_t thread; if (pthread_create(&thread, &attr, runHost, NULL)) { started = 0; self.launcherView.hidden=NO;UIApplication.sharedApplication.idleTimerDisabled=NO;self.renderMode.enabled=YES; self.status.text = text("dmP5RStartFailed"); }
    else pthread_detach(thread);
    pthread_attr_destroy(&attr);
}
static void *runHost(void *unused) {
    (void)unused; @autoreleasepool {
        char *args[] = {"p5r-host", strdup([NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"].fileSystemRepresentation), "main", "sdk", "subsdk0", NULL};
        char **arguments=args;
        if(activeExternalRoot) {
            NSError *error=nil;NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
            [coordinator coordinateReadingItemAtURL:activeExternalRoot options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:^(NSURL *url) {
                (void)url;dm_main(5,arguments);
            }];
            if(error) {
                LOG("P5R resource coordination failed: %s",error.localizedDescription.UTF8String);
                dispatch_async(dispatch_get_main_queue(), ^{
                    started=0;UIApplication.sharedApplication.idleTimerDisabled=NO;
                    P5RController *owner=(P5RController *)controller;owner.launcherView.hidden=NO;
                    owner.touchControls.hidden=YES;owner.renderMode.enabled=YES;owner.status.text=text("dmP5RResourcesAccess");
                });
            }
        } else dm_main(5,arguments);
        free(args[1]);
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
