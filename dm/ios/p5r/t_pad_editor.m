// 无游戏内容的 UIKit 验收 App：直接测试生产手柄的拖动、保存、取消及触摸命中。
// Game-free UIKit acceptance app: exercise dragging, save, cancel and hit testing on the production pad.
#import "dm_pad.h"
#import "pad_editor.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#undef NDEBUG
#include <assert.h>
#include <math.h>
static int nearPoint(CGPoint a,CGPoint b) { return hypot(a.x-b.x,a.y-b.y)<1e-6; }
static unsigned inputCalls;static uint64_t inputButtons;
void dm_input_set(uint64_t buttons,int32_t lx,int32_t ly,int32_t rx,int32_t ry) {
    (void)lx;(void)ly;(void)rx;(void)ry;inputCalls++;inputButtons=buttons;
}
@interface UIView (PadTest)
- (CGPoint)editCenter:(int)controlID;
- (uint64_t)faceAt:(CGPoint)point;
@end
@interface PadTestTouch : UITouch
@property CGPoint point;
@end
@implementation PadTestTouch
- (CGPoint)locationInView:(UIView *)view { (void)view;return self.point; }
@end
@interface PadTestApp : UIResponder <UIApplicationDelegate>
@property UIWindow *window;
@end
@implementation PadTestApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;(void)options;self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[P5RPadEditor new];[self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ [self verify]; });return YES;
}
- (void)verify {
    NSString *key=UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPad?@"P5RPadPositions-v1-iPad":@"P5RPadPositions-v1-iPhone";
    [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    UIView *root=self.window.rootViewController.view;
    UIView *game=dm_gamepad_view(root.bounds);game.hidden=YES;[root addSubview:game];[root layoutIfNeeded];[game layoutIfNeeded];
    CGPoint original=[game editCenter:0];
    UIView *preview=dm_gamepad_layout_preview(root.bounds);[root addSubview:preview];[root layoutIfNeeded];[preview layoutIfNeeded];
    unsigned before=inputCalls;
    PadTestTouch *touch=[PadTestTouch new];touch.point=[preview editCenter:0];NSSet *touches=[NSSet setWithObject:touch];
    [preview touchesBegan:touches withEvent:nil];touch.point=CGPointMake(touch.point.x-100,touch.point.y-90);
    [preview touchesMoved:touches withEvent:nil];[preview layoutIfNeeded];[preview touchesEnded:touches withEvent:nil];
    CGPoint moved=[preview editCenter:0];assert(hypot(moved.x-original.x,moved.y-original.y)>50);
    assert(inputCalls==before && ![NSUserDefaults.standardUserDefaults objectForKey:key]);
    assert(nearPoint([game editCenter:0],original));
    [preview removeFromSuperview];
    preview=dm_gamepad_layout_preview(root.bounds);[root addSubview:preview];[root layoutIfNeeded];[preview layoutIfNeeded];
    assert(nearPoint([preview editCenter:0],original));
    touch.point=[preview editCenter:0];[preview touchesBegan:touches withEvent:nil];touch.point=CGPointMake(touch.point.x-100,touch.point.y-90);
    [preview touchesMoved:touches withEvent:nil];[preview layoutIfNeeded];[preview touchesEnded:touches withEvent:nil];
    moved=[preview editCenter:0];dm_gamepad_layout_save(preview);[game layoutIfNeeded];
    assert(nearPoint([game editCenter:0],moved));
    UIView *restored=dm_gamepad_layout_preview(root.bounds);[root addSubview:restored];[root layoutIfNeeded];[restored layoutIfNeeded];
    assert(nearPoint([restored editCenter:0],moved));
    touch.point=moved;[game touchesBegan:touches withEvent:nil];assert(inputButtons&1);[game touchesEnded:touches withEvent:nil];assert(!inputButtons);
    dm_gamepad_layout_defaults(restored);[restored layoutIfNeeded];assert(nearPoint([restored editCenter:0],original));
    assert(nearPoint([game editCenter:0],moved));
    dm_gamepad_layout_save(restored);[game layoutIfNeeded];assert(nearPoint([game editCenter:0],original));
    [restored removeFromSuperview];[preview removeFromSuperview];[game removeFromSuperview];
    NSURL *folder=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSDictionary *result=@{@"passed":@YES,@"width":@(root.bounds.size.width),@"height":@(root.bounds.size.height),
        @"idiom":@(UIDevice.currentDevice.userInterfaceIdiom),@"checks":@[@"drag",@"cancel",@"save",@"reload",@"moved button input",@"default draft",@"default save",@"preview input isolation"]};
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:[folder URLByAppendingPathComponent:@"pad-editor-result.json"] atomically:YES];
    NSLog(@"PAD EDITOR UIKit OK");
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(PadTestApp.class)); } }
