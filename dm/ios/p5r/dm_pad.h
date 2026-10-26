// P5R 虚拟手柄与启动前布局编辑接口；编辑视图不发布游戏输入。
// P5R virtual pad and prelaunch layout editor interfaces; editor views never publish game input.
#import <UIKit/UIKit.h>
UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_reset(void);
void dm_gamepad_frame(double time);
UIView *dm_gamepad_layout_preview(CGRect frame);
void dm_gamepad_layout_defaults(UIView *preview);
void dm_gamepad_layout_save(UIView *preview);
