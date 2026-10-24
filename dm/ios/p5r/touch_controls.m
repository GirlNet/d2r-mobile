#import "touch_controls.h"
#include "stick_math.h"
#include "dm_input.h"

@interface P5RStick : UIView
@property (copy) void (^changed)(int32_t,int32_t);
@property UITouch *finger;
@property CGPoint offset;
- (void)resetInput;
@end
@implementation P5RStick
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){self.opaque=NO;self.multipleTouchEnabled=NO;}
    return self;
}
- (void)drawRect:(CGRect)rect {
    (void)rect;CGRect circle=CGRectInset(self.bounds,3,3);
    [[UIColor colorWithWhite:1 alpha:.08] setFill];[[UIBezierPath bezierPathWithOvalInRect:circle] fill];
    [[UIColor colorWithWhite:1 alpha:.38] setStroke];UIBezierPath *outline=[UIBezierPath bezierPathWithOvalInRect:circle];outline.lineWidth=1.5;[outline stroke];
    CGPoint center=CGPointMake(CGRectGetMidX(self.bounds)+self.offset.x,CGRectGetMidY(self.bounds)+self.offset.y);
    [[UIColor colorWithWhite:1 alpha:self.finger?.45:.2] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(center.x-20,center.y-20,40,40)] fill];
}
- (void)updateFinger {
    CGPoint point=[self.finger locationInView:self];float dx=point.x-CGRectGetMidX(self.bounds),dy=point.y-CGRectGetMidY(self.bounds);
    float radius=self.bounds.size.width*.38f,distance=hypotf(dx,dy),scale=distance>radius?radius/distance:1;
    self.offset=CGPointMake(dx*scale,dy*scale);int32_t x,y;p5r_stick(dx,dy,radius,&x,&y);
    if(self.changed)self.changed(x,y);[self setNeedsDisplay];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;if(!self.finger){self.finger=touches.anyObject;[self updateFinger];}
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;if([touches containsObject:self.finger])[self updateFinger];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;if([touches containsObject:self.finger])[self resetInput];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self touchesEnded:touches withEvent:event]; }
- (void)resetInput { self.finger=nil;self.offset=CGPointZero;if(self.changed)self.changed(0,0);[self setNeedsDisplay]; }
@end

@interface P5RTouchControls ()
@property P5RStick *leftStick;
@property P5RStick *rightStick;
@property NSMutableArray<UIButton *> *buttons;
@property uint64_t held;
@property int32_t lx;
@property int32_t ly;
@property int32_t rx;
@property int32_t ry;
@end
@implementation P5RTouchControls
- (instancetype)initWithFrame:(CGRect)frame {
    if(!(self=[super initWithFrame:frame]))return nil;
    self.opaque=NO;self.multipleTouchEnabled=YES;self.buttons=[NSMutableArray new];
    self.leftStick=[P5RStick new];self.rightStick=[P5RStick new];
    [self addSubview:self.leftStick];[self addSubview:self.rightStick];
    __weak P5RTouchControls *weakSelf=self;
    self.leftStick.changed=^(int32_t x,int32_t y){P5RTouchControls *s=weakSelf;s.lx=x;s.ly=y;[s publish];};
    self.rightStick.changed=^(int32_t x,int32_t y){P5RTouchControls *s=weakSelf;s.rx=x;s.ry=y;[s publish];};
    NSArray<NSString *> *labels=@[@"A",@"B",@"X",@"Y",@"L3",@"R3",@"L",@"R",@"ZL",@"ZR",@"+",@"−",@"←",@"↑",@"→",@"↓"];
    for(unsigned i=0;i<labels.count;i++) {
        UIButton *button=[UIButton buttonWithType:UIButtonTypeCustom];button.tag=UINT64_C(1)<<i;
        [button setTitle:labels[i] forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];button.backgroundColor=[UIColor colorWithWhite:0 alpha:.28];
        button.layer.borderColor=[UIColor colorWithWhite:1 alpha:.4].CGColor;button.layer.borderWidth=1;button.exclusiveTouch=NO;
        [button addTarget:self action:@selector(pressed:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(released:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
        [self.buttons addObject:button];[self addSubview:button];
    }
    return self;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit=[super hitTest:point withEvent:event];return hit==self?nil:hit;
}
- (void)publish { dm_input_set(self.held,self.lx,self.ly,self.rx,self.ry); }
- (void)pressed:(UIButton *)button { self.held|=(uint64_t)button.tag;button.alpha=.65;[self publish]; }
- (void)released:(UIButton *)button { self.held&=~(uint64_t)button.tag;button.alpha=1;[self publish]; }
- (void)resetInput {
    self.held=0;[self.leftStick resetInput];[self.rightStick resetInput];
    for(UIButton *button in self.buttons){button.highlighted=NO;button.alpha=1;}[self publish];
}
- (void)layoutSubviews {
    [super layoutSubviews];[self resetInput];
    CGRect area=UIEdgeInsetsInsetRect(self.bounds,self.safeAreaInsets);
    CGFloat left=CGRectGetMinX(area),right=CGRectGetMaxX(area),bottom=CGRectGetMaxY(area),top=CGRectGetMinY(area);
    CGFloat scale=MIN(1,MIN(area.size.width/740,area.size.height/350));
    // Landscape safe-area layout: left movement, right camera, Nintendo face positions.
    self.leftStick.frame=CGRectMake(left+22*scale,bottom-160*scale,124*scale,124*scale);
    self.rightStick.frame=CGRectMake(right-310*scale,bottom-138*scale,112*scale,112*scale);
    const float positions[16][2]={{-38,-116},{-88,-66},{-88,-166},{-138,-116},{174,-48},{-326,-48},
        {44,38},{-58,38},{112,38},{-126,38},{-190,38},{190,38},{40,-218},{84,-262},{128,-218},{84,-174}};
    for(unsigned i=0;i<16;i++) {
        float x=positions[i][0],y=positions[i][1];
        CGFloat cx=x<0?right+x*scale:left+x*scale,cy=y<0?bottom+y*scale:top+y*scale;
        UIButton *button=self.buttons[i];CGFloat side=(i==4||i==5?44:46)*scale;
        button.frame=CGRectMake(cx-side/2,cy-side/2,side,side);button.layer.cornerRadius=side/2;
    }
}
@end
