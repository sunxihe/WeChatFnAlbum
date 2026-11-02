#import "FNZoomImageView.h"
@interface FNZoomImageView ()
@property(nonatomic) UIImageView *imageView;
@property(nonatomic) CGSize viewportSize;
@end
@implementation FNZoomImageView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.delegate = self;
        self.minimumZoomScale = 1;
        self.maximumZoomScale = 5;
        self.bouncesZoom = YES;
        self.showsHorizontalScrollIndicator = NO;
        self.showsVerticalScrollIndicator = NO;
        self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        self.backgroundColor = UIColor.blackColor;
        _imageView = [UIImageView new];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.userInteractionEnabled = YES;
        [self addSubview:_imageView];
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap:)];
        doubleTap.numberOfTapsRequired = 2;
        [self addGestureRecognizer:doubleTap];
    }
    return self;
}
- (void)setImage:(UIImage *)image {
    self.imageView.image = image;
    [self resetZoom];
}
- (void)centerImage {
    CGSize content = self.imageView.frame.size, viewport = self.bounds.size;
    CGFloat x = MAX(0,(viewport.width-content.width)/2);
    CGFloat y = MAX(0,(viewport.height-content.height)/2);
    self.contentInset = UIEdgeInsetsMake(y,x,y,x);
}
- (void)resetZoom {
    [self setZoomScale:1 animated:NO];
    CGSize viewport = self.bounds.size, image = self.imageView.image.size;
    CGSize fitted = viewport;
    if (image.width > 0 && image.height > 0 && viewport.width > 0 && viewport.height > 0) {
        CGFloat ratio = MIN(viewport.width/image.width,viewport.height/image.height);
        fitted = CGSizeMake(image.width*ratio,image.height*ratio);
    }
    self.imageView.frame = (CGRect){CGPointZero,fitted};
    self.contentSize = fitted;
    [self centerImage];
    self.contentOffset = CGPointMake(-self.contentInset.left,-self.contentInset.top);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGSizeEqualToSize(self.viewportSize,self.bounds.size)) {
        self.viewportSize = self.bounds.size;
        [self resetZoom];
    }
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.imageView.image ? self.imageView : nil;
}
- (void)scrollViewDidZoom:(UIScrollView *)scrollView { [self centerImage]; }
- (void)doubleTap:(UITapGestureRecognizer *)gesture {
    if (!self.imageView.image) return;
    if (self.zoomScale > 1.01) { [self setZoomScale:1 animated:YES]; return; }
    CGPoint point = [gesture locationInView:self.imageView];
    CGFloat scale = MIN(3,self.maximumZoomScale);
    CGSize size = CGSizeMake(self.bounds.size.width/scale,self.bounds.size.height/scale);
    [self zoomToRect:CGRectMake(point.x-size.width/2,point.y-size.height/2,size.width,size.height) animated:YES];
}
@end
