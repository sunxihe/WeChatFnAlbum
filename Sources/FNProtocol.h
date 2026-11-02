#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSError *FNError(NSString *message);
FOUNDATION_EXPORT NSURL *_Nullable FNEndpoint(NSString *address, NSError **error);
FOUNDATION_EXPORT NSString *FNAuthx(NSURL *url, NSString *nonce, NSString *timestamp);
FOUNDATION_EXPORT NSString *FNBodyAuthx(NSURL *url, NSData *body, NSString *nonce, NSString *timestamp);
FOUNDATION_EXPORT NSString *FNMD5(NSData *data);
FOUNDATION_EXPORT NSData *_Nullable FNAES(NSData *data, NSData *key, NSData *iv, BOOL encrypt,
                                          NSError **error);
FOUNDATION_EXPORT NSDictionary *_Nullable FNEncrypted(NSDictionary *payload, NSString *pem, NSData *key,
                                                      NSData *iv, NSError **error);
FOUNDATION_EXPORT NSString *FNMediaURL(NSDictionary *photo, BOOL original);
FOUNDATION_EXPORT BOOL FNIsPhoto(NSDictionary *photo);
FOUNDATION_EXPORT BOOL FNIsVideo(NSDictionary *photo);
FOUNDATION_EXPORT NSString *FNVideoDurationText(NSDictionary *photo);
FOUNDATION_EXPORT NSString *FNMediaSizeText(NSArray<NSDictionary *> *photos);
FOUNDATION_EXPORT BOOL FNRouteUsesLocal(NSInteger mode, NSString *_Nullable homeSSID, NSString *_Nullable currentSSID);
FOUNDATION_EXPORT BOOL FNIsSupportedMedia(NSDictionary *photo);
FOUNDATION_EXPORT NSArray<NSDictionary *> *FNMediaTypeCategories(void);
FOUNDATION_EXPORT NSArray<NSDictionary *> *FNCategoryFilters(NSString *kind, NSDictionary *entry);
FOUNDATION_EXPORT NSString *FNPersonPortraitURL(NSDictionary *entry);
typedef void (^FNResult)(NSDictionary *_Nullable result, NSError *_Nullable error);

// One logical transfer, including at most one retry after access-token renewal.
@interface FNTransfer : NSObject
@property(nonatomic, readonly) int64_t countOfBytesReceived;
@property(nonatomic, readonly) int64_t countOfBytesExpectedToReceive;
- (void)cancel;
@end

@interface FNClient : NSObject <NSURLSessionTaskDelegate>
@property(nonatomic, readonly, nullable) NSURL *baseURL;
@property(nonatomic, readonly) NSString *username;
@property(nonatomic, readonly) BOOL authenticated;
@property(nonatomic, readonly) NSUInteger generation;
+ (instancetype)shared;
- (void)restore:(FNResult)completion;
// Only explicitly configured aliases of the same NAS may share credentials.
- (void)routeToAddress:(NSString *)address trustedAddresses:(NSArray<NSString *> *)addresses completion:(FNResult)completion;
- (void)clearRouting;
- (void)loginAddress:(NSString *)address
                user:(NSString *)user
            password:(NSString *)password
            remember:(BOOL)remember
          completion:(FNResult)completion;
- (void)twoFactor:(NSString *)code completion:(FNResult)completion;
- (void)logout;
- (void)get:(NSString *)path params:(NSDictionary *)params completion:(FNResult)completion;
- (void)search:(NSString *)keyword completion:(FNResult)completion;
- (void)post:(NSString *)path body:(NSDictionary *)body completion:(FNResult)completion;
// AVPlayer uses scoped cookies for NAS transcoding streams, never global cookie storage.
- (nullable NSDictionary *)originalVideoPlaybackConfiguration:(NSString *)path error:(NSError **)error;
- (nullable NSDictionary *)videoPlaybackConfiguration:(NSString *)path error:(NSError **)error;
- (void)filteredPhotos:(NSArray<NSDictionary *> *)filters completion:(FNResult)completion;
- (void)photoDetails:(NSArray<NSNumber *> *)ids completion:(FNResult)completion;
- (nullable FNTransfer *)media:(NSString *)path
                              completion:(void (^)(NSData *_Nullable, NSError *_Nullable))completion;
- (nullable FNTransfer *)download:(NSString *)path
                                             to:(NSURL *)target
                                     completion:(void (^)(NSError *_Nullable))completion;
@end

// Each browser owns a cursor; switching albums never shares pagination state.
@interface FNPhotoPager : NSObject
@property(nonatomic, copy, nullable) NSString *albumID;
@property(nonatomic) BOOL favorites;
@property(nonatomic, copy, nullable) NSString *searchKeyword;
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *queryFilters;
@property(nonatomic, readonly) BOOL hasNext;
@property(nonatomic, readonly) BOOL hasPrevious;
@property(nonatomic, readonly) NSArray<NSDictionary *> *days;
- (FNPhotoPager *)pagerStartingAtDay:(NSUInteger)index;
- (void)next:(void (^)(NSArray<NSDictionary *> *_Nullable rows, NSError *_Nullable error))completion;
- (void)previous:(void (^)(NSArray<NSDictionary *> *_Nullable rows, NSError *_Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
