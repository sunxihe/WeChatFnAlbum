#import <UIKit/UIKit.h>
@interface FNZoomImageView : UIScrollView <UIScrollViewDelegate>
@property(nonatomic, readonly) UIImageView *imageView;
- (void)setImage:(UIImage *)image;
- (void)resetZoom;
@end
