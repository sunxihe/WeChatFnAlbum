#import <Foundation/Foundation.h>
@class UIImage;
typedef void (^FNImageCallback)(UIImage *image, NSData *data);

// WeChat may pass stack blocks. Copy them before returning to its caller,
// rather than capturing an untyped `id` across an asynchronous file read.
@interface FNImageDelivery : NSObject
@property(nonatomic, copy, readonly) FNImageCallback process;
@property(nonatomic, copy, readonly) FNImageCallback result;
- (instancetype)initWithProcess:(FNImageCallback)process result:(FNImageCallback)result;
- (void)deliverImage:(UIImage *)image data:(NSData *)data;
@end
