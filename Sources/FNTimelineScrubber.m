#import "FNTimelineScrubber.h"

@interface FNTimelineScrubber ()
@property(nonatomic) UIView *track;
@property(nonatomic) UILabel *thumb;
@property(nonatomic) UILabel *bubble;
@property(nonatomic) NSUInteger dateGeneration;
@end
@implementation FNTimelineScrubber
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.accessibilityLabel = @"按日期快速浏览照片";
        self.accessibilityHint = @"上下拖动，松开跳转到显示的日期";
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitAdjustable;
        _track = [UIView new];
        _track.userInteractionEnabled = NO;
        _track.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:.15];
        _track.layer.cornerRadius = 1;
        [self addSubview:_track];
        _thumb = [UILabel new];
        _thumb.text = @"⌃\n⌄";
        _thumb.numberOfLines = 2;
        _thumb.textAlignment = NSTextAlignmentCenter;
        _thumb.font = [UIFont boldSystemFontOfSize:17];
        _thumb.textColor = UIColor.whiteColor;
        _thumb.backgroundColor = [UIColor.systemGrayColor colorWithAlphaComponent:.9];
        _thumb.layer.cornerRadius = 12;
        _thumb.clipsToBounds = YES;
        [self addSubview:_thumb];
        _bubble = [UILabel new];
        _bubble.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold];
        _bubble.textAlignment = NSTextAlignmentCenter;
        _bubble.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:.9];
        _bubble.textColor = UIColor.systemBackgroundColor;
        _bubble.layer.cornerRadius = 10;
        _bubble.clipsToBounds = YES;
        _bubble.alpha = 0;
        [self addSubview:_bubble];
    }
    return self;
}
- (void)setFraction:(CGFloat)fraction {
    _fraction = MIN(1, MAX(0, fraction));
    [self setNeedsLayout];
}
- (void)setDateText:(NSString *)dateText {
    _dateText = [dateText copy];
    self.bubble.text = dateText;
    self.accessibilityValue = dateText;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat y = self.fraction * MAX(0, self.bounds.size.height - 48);
    self.track.frame = CGRectMake(31, 8, 2, MAX(0, self.bounds.size.height - 16));
    self.thumb.frame = CGRectMake(18, y, 28, 48);
    self.bubble.frame = CGRectMake(-146, y + 2, 156, 44);
}
- (void)showDate {
    self.dateGeneration++;
    NSUInteger gen = self.dateGeneration;
    self.bubble.alpha = 1;
    __weak typeof(self) weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (weak.dateGeneration == gen && !weak.tracking)
            [UIView animateWithDuration:.2
                             animations:^{
                                 weak.bubble.alpha = 0;
                             }];
    });
}
- (void)updateTouch:(UITouch *)touch {
    self.fraction = ([touch locationInView:self].y - 24) / MAX(1, self.bounds.size.height - 48);
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    [self showDate];
}
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self updateTouch:touch];
    return YES;
}
- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self updateTouch:touch];
    return YES;
}
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    if (touch)
        [self updateTouch:touch];
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
    [self showDate];
}
- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [self sendActionsForControlEvents:UIControlEventTouchCancel];
    [self showDate];
}
- (void)accessibilityIncrement {
    [self adjust:.02];
}
- (void)accessibilityDecrement {
    [self adjust:-.02];
}
- (void)adjust:(CGFloat)step {
    self.fraction += step;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
    [self showDate];
}
@end
