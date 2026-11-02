#import <UIKit/UIKit.h>

// A fixed viewport overlay. The browser commits one NAS seek on touch release.
@interface FNTimelineScrubber : UIControl
@property(nonatomic) CGFloat fraction;
@property(nonatomic, copy) NSString *dateText;
- (void)showDate;
@end
