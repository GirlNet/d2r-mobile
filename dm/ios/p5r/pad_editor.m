// 与游戏共享实际手柄视图；工具栏可拖动，避免挡住所编辑的按键。
// Share the actual in-game pad view; a movable toolbar avoids covering controls being edited.
#import "pad_editor.h"
#import "dm_pad.h"
#include "dm_i18n.h"

@interface P5RPadGrid : UIView @end
@implementation P5RPadGrid
- (void)drawRect:(CGRect)rect {
    (void)rect;CGContextRef context=UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(context,[UIColor colorWithWhite:1 alpha:.04].CGColor);
    CGContextSetLineWidth(context,1);
    for(CGFloat x=0;x<self.bounds.size.width;x+=32){CGContextMoveToPoint(context,x,0);CGContextAddLineToPoint(context,x,self.bounds.size.height);}
    for(CGFloat y=0;y<self.bounds.size.height;y+=32){CGContextMoveToPoint(context,0,y);CGContextAddLineToPoint(context,self.bounds.size.width,y);}
    CGContextStrokePath(context);
}
@end

@implementation P5RPadEditor {
    UIView *_preview,*_panel;UIStackView *_stack;CGSize _lastSize;CGPoint _panelStart;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UIButton *)button:(const char *)key action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@(dm_ui(key)) forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.view.backgroundColor=[UIColor colorWithRed:.035 green:.045 blue:.065 alpha:1];
    P5RPadGrid *grid=[[P5RPadGrid alloc] initWithFrame:self.view.bounds];grid.backgroundColor=UIColor.clearColor;
    grid.userInteractionEnabled=NO;grid.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    grid.contentMode=UIViewContentModeRedraw;[self.view addSubview:grid];
    _preview=dm_gamepad_layout_preview(self.view.bounds);_preview.autoresizingMask=grid.autoresizingMask;[self.view addSubview:_preview];
    _panel=[UIView new];_panel.backgroundColor=[UIColor colorWithWhite:.11 alpha:1];_panel.layer.cornerRadius=14;
    _panel.layer.borderColor=[UIColor colorWithWhite:1 alpha:.18].CGColor;_panel.layer.borderWidth=1;[self.view addSubview:_panel];
    UILabel *title=[UILabel new];title.text=@(dm_ui("dmP5RPadLayout"));title.textAlignment=NSTextAlignmentCenter;
    title.font=[UIFont systemFontOfSize:17 weight:UIFontWeightBold];title.textColor=UIColor.whiteColor;
    title.userInteractionEnabled=YES;[title.heightAnchor constraintGreaterThanOrEqualToConstant:28].active=YES;
    [title addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(movePanel:)]];
    UILabel *hint=[UILabel new];hint.text=@(dm_ui("dmP5RPadLayoutHint"));hint.textAlignment=NSTextAlignmentCenter;
    hint.font=[UIFont systemFontOfSize:12];hint.textColor=UIColor.lightGrayColor;hint.numberOfLines=0;
    UIButton *cancel=[self button:"dmP5RCancel" action:@selector(cancel)];
    UIButton *reset=[self button:"dmP5RPadReset" action:@selector(reset)];
    UIButton *save=[self button:"dmP5RPadSave" action:@selector(save)];save.backgroundColor=[UIColor colorWithRed:.88 green:.035 blue:.11 alpha:1];save.layer.cornerRadius=8;
    UIStackView *buttons=[[UIStackView alloc] initWithArrangedSubviews:@[cancel,reset,save]];buttons.distribution=UIStackViewDistributionFillEqually;buttons.spacing=8;
    _stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,hint,buttons]];_stack.axis=UILayoutConstraintAxisVertical;_stack.spacing=5;
    [_panel addSubview:_stack];
    self.view.accessibilityViewIsModal=YES;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];CGRect safe=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets);
    CGFloat width=MIN(360,MAX(220,safe.size.width-24));
    CGSize fitting=[_stack systemLayoutSizeFittingSize:CGSizeMake(width-24,UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGSize size=CGSizeMake(width,fitting.height+20);
    if(!CGSizeEqualToSize(_lastSize,self.view.bounds.size) || _panel.bounds.size.width==0)
        _panel.frame=CGRectMake(CGRectGetMidX(safe)-width/2,CGRectGetMinY(safe)+64,width,size.height);
    else _panel.bounds=(CGRect){CGPointZero,size};
    _lastSize=self.view.bounds.size;[self clampPanel];_stack.frame=CGRectInset(_panel.bounds,12,10);
}
- (void)clampPanel {
    CGRect safe=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets),f=_panel.frame;
    f.origin.x=MAX(CGRectGetMinX(safe),MIN(CGRectGetMaxX(safe)-f.size.width,f.origin.x));
    f.origin.y=MAX(CGRectGetMinY(safe),MIN(CGRectGetMaxY(safe)-f.size.height,f.origin.y));_panel.frame=f;
}
- (void)movePanel:(UIPanGestureRecognizer *)gesture {
    if(gesture.state==UIGestureRecognizerStateBegan)_panelStart=_panel.center;
    CGPoint offset=[gesture translationInView:self.view];_panel.center=CGPointMake(_panelStart.x+offset.x,_panelStart.y+offset.y);[self clampPanel];
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)reset { dm_gamepad_layout_defaults(_preview); }
- (void)save { dm_gamepad_layout_save(_preview);[self dismissViewControllerAnimated:YES completion:nil]; }
@end
