#import <UIKit/UIKit.h>

@interface FNPreviewLoadingView : UIView
- (void)showTitle:(NSString *)title;
- (void)updateReceived:(int64_t)received expected:(int64_t)expected;
- (void)updateBufferedSeconds:(double)seconds target:(double)target;
- (void)showOpening:(NSString *)title;
@end
