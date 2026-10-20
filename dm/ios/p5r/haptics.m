// P5R HD 震动：把 nn::hid 的 VibrationValue 混合结果（见 dm/host/dm_haptics.h 与 hle_hid.c 的混合器）
// 通过 Core Haptics 打到 iPhone 的 Taptic Engine。移植自 MZhao-ouo/Touchable（MIT，internal/platform/ios/Haptics.m）
// 的 NitenHaptics：单一引擎 + 单一 advanced player，intensity/sharpness 走动态参数，带 epoch 去重与失败重试。
// P5R HD haptics: drive the Taptic Engine from the mixer output (see dm/host/dm_haptics.h and hle_hid.c).
// Ported from MZhao-ouo/Touchable (MIT, internal/platform/ios/Haptics.m) NitenHaptics: one engine plus one advanced
// player, intensity/sharpness sent as dynamic parameters, with epoch dedupe and failure retry.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreHaptics/CoreHaptics.h>
#include "dm_haptics.h"
#include <stdio.h>

/* 所有引擎/播放器操作都在这条串行队列执行；客体的 HID 调用只入队参数，不等待触觉硬件。
 * All engine and player operations run on this serial queue. Guest HID calls
 * only enqueue parameters. They do not wait for the haptic hardware. */
@interface P5RHaptics : NSObject {
    dispatch_queue_t _queue;
    CHHapticEngine *_engine;
    id<CHHapticAdvancedPatternPlayer> _player;
    BOOL _engineRunning, _retryScheduled;
    NSUInteger _starts, _updates, _stops, _errors;
}
@property(nonatomic, readonly) BOOL supported;
- (void)enqueue:(dm_haptic_output)output;
@end

@implementation P5RHaptics
- (instancetype)init {
    if ((self = [super init])) {
        _supported = CHHapticEngine.capabilitiesForHardware.supportsHaptics;
        _queue = dispatch_queue_create("P5R haptics",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note; dm_haptics_suspend_for(DM_HAPTICS_INACTIVE, 1);
        }];
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note; dm_haptics_suspend_for(DM_HAPTICS_INACTIVE, 1);
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note; dm_haptics_suspend_for(DM_HAPTICS_INACTIVE, 0);
        }];
        [center addObserverForName:AVAudioSessionInterruptionNotification object:AVAudioSession.sharedInstance queue:nil usingBlock:^(NSNotification *note) {
            BOOL interrupted = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan;
            dm_haptics_suspend_for(DM_HAPTICS_INTERRUPTED, interrupted);
        }];
    }
    return self;
}
- (void)reportError:(NSError *)error operation:(const char *)operation {
    if (++_errors <= 8 || _errors % 64 == 0)
        fprintf(stderr, "[dm] P5R haptics %s failed: %s\n", operation, error.description.UTF8String);
}
- (void)retryCurrentOutput {
    if (_retryScheduled) return;
    _retryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), _queue, ^{
        self->_retryScheduled = NO;
        dm_haptic_status status = dm_haptics_status();
        if (self->_supported && status.supported && !status.suspended && status.output.intensity > 0)
            [self apply:status.output];
    });
}
- (void)discardPlayer {
    if (!_player) return;
    NSError *error = nil;
    if (![_player stopAtTime:CHHapticTimeImmediate error:&error]) [self reportError:error operation:"stop"];
    _player = nil;
    if (++_stops <= 16) fprintf(stderr, "[dm] P5R haptics stop %lu\n", (unsigned long)_stops);
}
- (BOOL)startEngine {
    if (!_engine) {
        NSError *error = nil;
        _engine = [[CHHapticEngine alloc] initWithAudioSession:AVAudioSession.sharedInstance error:&error];
        if (!_engine) { [self reportError:error operation:"create engine"]; return NO; }
        _engine.playsHapticsOnly = YES;
        _engine.autoShutdownEnabled = YES;
        __weak P5RHaptics *weakSelf = self;
        _engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
            P5RHaptics *owner = weakSelf;
            if (!owner) return;
            dispatch_async(owner->_queue, ^{
                owner->_player = nil;
                owner->_engineRunning = NO;
                fprintf(stderr, "[dm] P5R haptics engine stopped reason=%ld\n", (long)reason);
                [owner retryCurrentOutput];
            });
        };
        _engine.resetHandler = ^{
            P5RHaptics *owner = weakSelf;
            if (!owner) return;
            dispatch_async(owner->_queue, ^{
                owner->_player = nil;
                owner->_engineRunning = NO;
                fprintf(stderr, "[dm] P5R haptics engine reset\n");
                [owner retryCurrentOutput];
            });
        };
    }
    if (!_engineRunning) {
        NSError *error = nil;
        if (![_engine startAndReturnError:&error]) { [self reportError:error operation:"start engine"]; return NO; }
        _engineRunning = YES;
    }
    return YES;
}
- (NSArray<CHHapticDynamicParameter *> *)parameters:(dm_haptic_output)output {
    return @[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:output.intensity relativeTime:0],
        /* 锐度动态参数是叠加在事件中性 0.5 锐度上的增量。
         * Sharpness control adds to the event's neutral 0.5 sharpness. */
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:output.sharpness - 0.5f relativeTime:0]
    ];
}
- (void)apply:(dm_haptic_output)output {
    dm_haptic_status current = dm_haptics_status();
    if (!_supported || !current.supported || current.suspended || output.intensity == 0) { [self discardPlayer]; return; }
    /* 忽略焦点切换或重置前入队的信号。Do not play events queued before a focus change or reset. */
    if (output.epoch != current.epoch) return;
    if (_retryScheduled && !_player) return;
    if (![self startEngine]) { [self retryCurrentOutput]; return; }
    NSError *error = nil;
    NSArray<CHHapticDynamicParameter *> *parameters = [self parameters:output];
    if (!_player) {
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]
        ] relativeTime:0 duration:30];
        /* 控制量保持在循环模式之外，否则其初始强度会在每个 30 秒循环边界重新施加。
         * Keep controls outside the looped pattern so its initial strength is not reapplied at each 30-second boundary. */
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        if (!pattern) { [self reportError:error operation:"create pattern"]; [self retryCurrentOutput]; return; }
        _player = [_engine createAdvancedPlayerWithPattern:pattern error:&error];
        if (!_player) { [self reportError:error operation:"create player"]; [self retryCurrentOutput]; return; }
        _player.loopEnabled = YES;
        /* 先静音启动，设置本脉冲控制量，再开启输出，避免首个更新前出现满强度的起始叩击。
         * Start muted, set this pulse's controls, then enable output to avoid a full-strength leading tap. */
        _player.isMuted = YES;
        if (![_player startAtTime:CHHapticTimeImmediate error:&error]) {
            [self reportError:error operation:"start player"]; _player = nil; _engineRunning = NO;
            [self retryCurrentOutput]; return;
        }
        if (![_player sendParameters:parameters atTime:CHHapticTimeImmediate error:&error]) {
            [self reportError:error operation:"initial controls"]; [self discardPlayer];
            [self retryCurrentOutput]; return;
        }
        _player.isMuted = NO;
        if (++_starts <= 16) fprintf(stderr, "[dm] P5R haptics start %lu intensity=%.4f sharpness=%.4f\n",
            (unsigned long)_starts, output.intensity, output.sharpness);
    } else if (![_player sendParameters:parameters atTime:CHHapticTimeImmediate error:&error]) {
        [self reportError:error operation:"update player"]; [self discardPlayer]; _engineRunning = NO;
        [self retryCurrentOutput]; return;
    }
    if (++_updates <= 16 || _updates % 1000 == 0)
        fprintf(stderr, "[dm] P5R haptics accepted %lu intensity=%.4f sharpness=%.4f epoch=%llu\n",
            (unsigned long)_updates, output.intensity, output.sharpness, (unsigned long long)output.epoch);
}
- (void)enqueue:(dm_haptic_output)output {
    dispatch_async(_queue, ^{ @autoreleasepool { [self apply:output]; } });
}
@end

static P5RHaptics *sharedHaptics(void) {
    static P5RHaptics *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [P5RHaptics new]; });
    return instance;
}

void dm_haptics_platform_apply(dm_haptic_output output) {
    [sharedHaptics() enqueue:output];
}

void dm_haptics_ios_init(void) {
    P5RHaptics *haptics = sharedHaptics();
    dm_haptics_configure(haptics.supported);
    dm_haptics_suspend_for(DM_HAPTICS_INACTIVE, UIApplication.sharedApplication.applicationState != UIApplicationStateActive);
    fprintf(stderr, "[dm] P5R haptics Core Haptics hardware=%d\n", haptics.supported);
}
