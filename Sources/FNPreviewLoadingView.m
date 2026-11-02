#import "FNPreviewLoadingView.h"
#import <math.h>

@interface FNPreviewLoadingView ()
@property(nonatomic) UIView *panel;
@property(nonatomic) UIActivityIndicatorView *spinner;
@property(nonatomic) UILabel *titleLabel;
@property(nonatomic) UILabel *percentage;
@property(nonatomic) UIProgressView *bar;
@property(nonatomic) UILabel *detail;
@end
@implementation FNPreviewLoadingView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:.45];
        self.userInteractionEnabled = NO;
        self.accessibilityIdentifier = @"fn.preview.loading";
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitUpdatesFrequently;
        _panel = [UIView new];
        _panel.backgroundColor = [UIColor colorWithWhite:.08 alpha:.94];
        _panel.layer.cornerRadius = 18;
        [self addSubview:_panel];
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        _spinner.color = UIColor.whiteColor;
        [_panel addSubview:_spinner];
        _titleLabel = [UILabel new];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [_panel addSubview:_titleLabel];
        _percentage = [UILabel new];
        _percentage.textColor = UIColor.whiteColor;
        _percentage.font = [UIFont monospacedDigitSystemFontOfSize:28 weight:UIFontWeightSemibold];
        _percentage.textAlignment = NSTextAlignmentCenter;
        [_panel addSubview:_percentage];
        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _bar.progressTintColor = UIColor.systemGreenColor;
        _bar.trackTintColor = [UIColor colorWithWhite:1 alpha:.18];
        [_panel addSubview:_bar];
        _detail=[UILabel new];
        _detail.font=[UIFont systemFontOfSize:12];
        _detail.textColor=[UIColor colorWithWhite:1 alpha:.75];
        _detail.textAlignment=NSTextAlignmentCenter;
        [_panel addSubview:_detail];
        self.hidden = YES;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = MIN(260, MAX(120, self.bounds.size.width - 40));
    self.panel.frame = CGRectMake((self.bounds.size.width-width)/2,
                                 (self.bounds.size.height-196)/2, width, 196);
    self.spinner.center = CGPointMake(width/2, 40);
    self.titleLabel.frame = CGRectMake(12, 72, width-24, 24);
    self.percentage.frame = CGRectMake(12, 104, width-24, 38);
    self.detail.frame = CGRectMake(8, 143, width-16, 16);
    self.bar.frame = CGRectMake(24, 168, width-48, 4);
}
- (void)showTitle:(NSString *)title {
    self.hidden = NO;
    self.titleLabel.text = title;
    self.accessibilityLabel = title;
    [self.spinner startAnimating];
    [self updateReceived:0 expected:0];
}
- (void)updateReceived:(int64_t)received expected:(int64_t)expected {
    self.detail.text=nil;
    BOOL known = expected > 0;
    double fraction = known ? MIN(1., MAX(0., (double)received/expected)) : 0;
    self.percentage.text = known ? [NSString stringWithFormat:@"%.0f%%", floor(fraction*100)] : @"加载中…";
    self.accessibilityValue = self.percentage.text;
    self.bar.hidden = !known;
    [self.bar setProgress:fraction animated:NO];
}
- (void)updateBufferedSeconds:(double)seconds target:(double)target {
    seconds=isfinite(seconds) ? MAX(0,seconds) : 0;
    target=isfinite(target) && target>0 ? target : 5;
    [self updateReceived:(int64_t)(MIN(seconds,target)*1000) expected:MAX(1,(int64_t)(target*1000))];
    self.detail.text=[NSString stringWithFormat:@"已缓冲 %.1f 秒 / 目标 %.1f 秒",seconds,target];
    self.accessibilityValue=[NSString stringWithFormat:@"%@，%@",self.percentage.text,self.detail.text];
}
- (void)showOpening:(NSString *)title {
    self.titleLabel.text = title;
    self.accessibilityLabel = title;
    [self updateReceived:1 expected:1];
}
@end
