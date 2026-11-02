#import "FNImageDelivery.h"
@implementation FNImageDelivery
- (instancetype)initWithProcess:(FNImageCallback)process result:(FNImageCallback)result {
    if ((self = [super init])) {
        _process = [process copy];
        _result = [result copy];
    }
    return self;
}
- (void)deliverImage:(UIImage *)image data:(NSData *)data {
    if (self.process)
        self.process(image, data);
    FNImageCallback completion = [self.result copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion)
            completion(image, data);
    });
}
@end
