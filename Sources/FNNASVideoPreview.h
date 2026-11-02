#import "FNProtocol.h"
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSDictionary *_Nullable FNPreviewVideoQuality(NSArray *_Nullable qualities);
// Owns one server-side preview transcoding session. Sending does not use this object.
@interface FNNASVideoPreview : NSObject
+ (void)prewarmPhoto:(NSDictionary *)photo client:(FNClient *)client;
+ (instancetype)takePhoto:(NSDictionary *)photo client:(FNClient *)client;
+ (void)clearWarmPreview;
- (void)park;
- (instancetype)initWithClient:(FNClient *)client;
@property(nonatomic, readonly, nullable) NSString *path;
@property(nonatomic, readonly, nullable) NSString *qualityLabel;
@property(nonatomic, copy, nullable) dispatch_block_t onCredentialsChanged;
@property(nonatomic, readonly) NSDictionary<NSString *,NSNumber *> *preparationTimings;
- (void)preparePhoto:(NSDictionary *)photo completion:(void (^)(NSError *_Nullable error))completion;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
