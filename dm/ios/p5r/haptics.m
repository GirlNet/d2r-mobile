// P5R HD haptics: map the game's nn::hid VibrationValue (low/high amplitude and frequency)
// onto the iPhone's Taptic Engine through CoreHaptics. Adapted from the approach used by
// MZhao-ouo/Touchable (MIT, internal/platform/ios/Haptics.m): one continuous advanced player,
// intensity/sharpness sent as dynamic parameters.
// P5R 高清震动：把游戏的 VibrationValue（低/高频幅度与频率）映射到 Taptic Engine。
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreHaptics/CoreHaptics.h>
#include <math.h>

static CHHapticEngine *g_engine;
static id<CHHapticAdvancedPatternPlayer> g_player;
static BOOL g_started, g_supported;
static dispatch_queue_t g_queue;
static float g_intensity, g_sharpness;

static float clamp01(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

static void haptic_log(const char *what) {
    static int n;
    if (n++ < 8) fprintf(stderr, "[dm] P5R haptics: %s\n", what);
}

static BOOL haptic_start(void) {
    if (!g_supported) return NO;
    if (!g_engine) {
        NSError *error = nil;
        g_engine = [[CHHapticEngine alloc] initWithAudioSession:AVAudioSession.sharedInstance error:&error];
        if (!g_engine) { haptic_log("engine unavailable"); g_supported = NO; return NO; }
        g_engine.playsHapticsOnly = YES;
        g_engine.autoShutdownEnabled = YES;
        __weak CHHapticEngine *weakEngine = g_engine;
        g_engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
            (void)reason; (void)weakEngine;
            g_started = NO; g_player = nil;
        };
        g_engine.resetHandler = ^{ g_started = NO; g_player = nil; };
    }
    if (!g_started) {
        NSError *error = nil;
        if (![g_engine startAndReturnError:&error]) { haptic_log("engine start failed"); return NO; }
        g_started = YES;
    }
    return YES;
}

int dm_haptics_supported(void) {
    return CHHapticEngine.capabilitiesForHardware.supportsHaptics ? 1 : 0;
}

// intensity/sharpness already in [0,1]
static void haptic_apply(float intensity, float sharpness) {
    if (!g_supported) return;
    if (intensity <= 0.001f) {
        if (g_player) g_player.isMuted = YES;
        return;
    }
    if (!haptic_start()) return;
    NSError *error = nil;
    NSArray<CHHapticDynamicParameter *> *params = @[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:intensity relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharpness - 0.5f relativeTime:0],
    ];
    if (!g_player) {
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5],
        ] relativeTime:0 duration:30];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        if (!pattern) return;
        g_player = [g_engine createAdvancedPlayerWithPattern:pattern error:&error];
        if (!g_player) return;
        g_player.loopEnabled = YES;
        g_player.isMuted = YES;
        if (![g_player startAtTime:CHHapticTimeImmediate error:&error]) { g_player = nil; g_started = NO; return; }
        [g_player sendParameters:params atTime:CHHapticTimeImmediate error:&error];
        g_player.isMuted = NO;
    } else {
        [g_player sendParameters:params atTime:CHHapticTimeImmediate error:&error];
    }
    g_intensity = intensity; g_sharpness = sharpness;
}

// Called by the host HLE on every nn::hid::SendVibrationValue.
void dm_haptics_set(float low_amp, float low_freq, float high_amp, float high_freq) {
    float intensity = clamp01(fmaxf(low_amp, high_amp));
    float power_low = clamp01(low_amp) * clamp01(low_amp);
    float power_high = clamp01(high_amp) * clamp01(high_amp);
    float power = power_low + power_high;
    // Nintendo low/high bands are roughly 40-1280 Hz. Core Haptics exposes
    // sharpness rather than a carrier frequency, so use a power-weighted
    // logarithmic mapping to the 0..1 range.
    float sharpness = power > 0
        ? (power_low * log2f(fmaxf(low_freq, 40.0f) / 40.0f) +
           power_high * log2f(fmaxf(high_freq, 40.0f) / 40.0f)) / (5.0f * power)
        : 0.5f;
    sharpness = clamp01(sharpness);
    if (fabsf(intensity - g_intensity) < 0.02f && fabsf(sharpness - g_sharpness) < 0.05f) return;
    if (intensity > 0.001f) {
        static int nonzero;
        if (nonzero++ < 8)
            fprintf(stderr, "[dm] P5R haptics request %.3f intensity, %.3f sharpness (%.1f/%.1f Hz)\n",
                    intensity, sharpness, low_freq, high_freq);
    }
    if (!g_queue) {
        g_queue = dispatch_queue_create("p5r.haptics", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        g_supported = CHHapticEngine.capabilitiesForHardware.supportsHaptics;
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            (void)n; g_player.isMuted = YES;
        }];
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            (void)n; g_player.isMuted = YES;
        }];
    }
    dispatch_async(g_queue, ^{ haptic_apply(intensity, sharpness); });
}

void dm_haptics_stop(void) {
    if (!g_queue) return;
    dispatch_async(g_queue, ^{ haptic_apply(0, 0.5f); });
}
