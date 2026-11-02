#import "FNProtocol.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#import <arpa/inet.h>
#import <math.h>
#import <limits.h>

NSError *FNError(NSString *message) {
    return [NSError errorWithDomain:@"WeChatFnAlbum" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}
static NSData *JSON(id obj) {
    return [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingFragmentsAllowed error:nil];
}
static void Main(dispatch_block_t block) {
    if (NSThread.isMainThread)
        block();
    else
        dispatch_async(dispatch_get_main_queue(), block);
}
static NSError *AuthExpired(void) {
    return [NSError errorWithDomain:@"WeChatFnAlbum.Auth" code:401 userInfo:
        @{NSLocalizedDescriptionKey:@"登录态已失效，请重新登录。"}];
}
@interface FNTransfer ()
@property(nonatomic) NSURLSessionTask *underlying;
@property(nonatomic) BOOL cancelled;
@property(nonatomic, copy) dispatch_block_t onCancel;
@end
@implementation FNTransfer
- (int64_t)countOfBytesReceived { return self.underlying ? self.underlying.countOfBytesReceived : 0; }
- (int64_t)countOfBytesExpectedToReceive {
    return self.underlying ? self.underlying.countOfBytesExpectedToReceive : NSURLSessionTransferSizeUnknown;
}
- (void)cancel {
    Main(^{
        if (self.cancelled) return;
        self.cancelled = YES;
        [self.underlying cancel];
        if (self.onCancel) self.onCancel();
    });
}
@end
NSString *FNMD5(NSData *data) {
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
        [s appendFormat:@"%02x", digest[i]];
    return s;
}
NSURL *FNEndpoint(NSString *address, NSError **error) {
    address = [address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL implicit = [address rangeOfString:@"://"].location == NSNotFound;
    if (!address.length) {
        if (error)
            *error = FNError(@"请输入 NAS 地址。");
        return nil;
    }
    if (implicit) {
        struct in6_addr v6;
        if (inet_pton(AF_INET6, address.UTF8String, &v6) == 1)
            address = [NSString stringWithFormat:@"[%@]", address];
        address = [@"http://" stringByAppendingString:address];
    }
    NSURLComponents *c = [NSURLComponents componentsWithString:address];
    if (!c.host.length || ![@[ @"http", @"https" ] containsObject:c.scheme.lowercaseString] || c.user ||
        c.password || c.query || c.fragment || (c.path.length && ![c.path isEqual:@"/"]) ||
        (c.port && (c.port.integerValue < 1 || c.port.integerValue > 65535))) {
        if (error)
            *error = FNError(@"请填写 NAS 根地址（IP 或域名），不要附加页面路径或账号。");
        return nil;
    }
    if (implicit && !c.port)
        c.port = @5666;
    c.path = @"";
    return c.URL;
}
NSString *FNBodyAuthx(NSURL *url, NSData *body, NSString *nonce, NSString *timestamp) {
    NSString *raw = [NSString
        stringWithFormat:@"NDzZTVxnRKP8Z0jXg1VAMonaG8akvh_%@_%@_%@_%@_EAECCF25-80A6-4666-A7C2-A76904A74AB6",
                         url.path.length ? url.path : @"/", nonce, timestamp, FNMD5(body)];
    return [NSString stringWithFormat:@"nonce=%@&timestamp=%@&sign=%@", nonce, timestamp,
                                      FNMD5([raw dataUsingEncoding:NSUTF8StringEncoding])];
}
static NSString *SearchError(NSInteger code) {
    if (code == 20701)
        return @"NAS 尚未安装 AI 搜索模型，请在飞牛相册中启用智能识别并下载模型。";
    if (code == 4031)
        return @"NAS 模型数据不统一，请在飞牛相册中重置智能识别。";
    if (code == 20703)
        return @"NAS 正在准备 AI 模型，请稍后重试。";
    return [NSString stringWithFormat:@"AI 搜索失败（代码 %ld），请检查 NAS 智能识别服务。", (long)code];
}
NSString *FNAuthx(NSURL *url, NSString *nonce, NSString *timestamp) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    // NSURLQueryItem decodes percent escapes once. GET form queries also decode '+'.
    c.percentEncodedQuery = [c.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+"
                                                                             withString:@"%20"];
    for (NSURLQueryItem *item in c.queryItems)
        if (!values[item.name])
            values[item.name] = item.value ?: @"";
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *k in [[values allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", k, values[k]]];
    return FNBodyAuthx(url, [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding],
                       nonce, timestamp);
}
NSData *FNAES(NSData *data, NSData *key, NSData *iv, BOOL encrypt, NSError **error) {
    if (key.length != 32 || iv.length != 16) {
        if (error)
            *error = FNError(@"登录密钥格式不兼容。");
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithLength:data.length + kCCBlockSizeAES128];
    size_t written = 0;
    CCCryptorStatus status =
        CCCrypt(encrypt ? kCCEncrypt : kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.bytes,
                key.length, iv.bytes, data.bytes, data.length, out.mutableBytes, out.length, &written);
    if (status != kCCSuccess) {
        if (error)
            *error = FNError(@"登录数据加解密失败。");
        return nil;
    }
    out.length = written;
    return out;
}
NSDictionary *FNEncrypted(NSDictionary *payload, NSString *pem, NSData *key, NSData *iv, NSError **error) {
    NSMutableString *clean = [NSMutableString string];
    for (NSString *line in [pem componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
        if (![line hasPrefix:@"---"])
            [clean appendString:line];
    NSData *der = [[NSData alloc] initWithBase64EncodedString:clean
                                                      options:NSDataBase64DecodingIgnoreUnknownCharacters];
    CFErrorRef cferror = NULL;
    SecKeyRef rsa = SecKeyCreateWithData((__bridge CFDataRef)der, (__bridge CFDictionaryRef) @{
        (__bridge id)kSecAttrKeyType : (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeyClass : (__bridge id)kSecAttrKeyClassPublic
    },
                                         &cferror);
    if (cferror)
        CFRelease(cferror);
    if (!rsa) {
        if (error)
            *error = FNError(@"NAS RSA 公钥无法解析。");
        return nil;
    }
    CFDataRef encrypted =
        SecKeyCreateEncryptedData(rsa, kSecKeyAlgorithmRSAEncryptionPKCS1, (__bridge CFDataRef)key, &cferror);
    CFRelease(rsa);
    if (cferror)
        CFRelease(cferror);
    if (!encrypted) {
        if (error)
            *error = FNError(@"登录密钥封装失败。");
        return nil;
    }
    NSData *rsaData = CFBridgingRelease(encrypted);
    NSData *aes = FNAES(JSON(payload), key, iv, YES, error);
    if (!aes)
        return nil;
    return @{
        @"req" : @"encrypted",
        @"iv" : [iv base64EncodedStringWithOptions:0],
        @"rsa" : [rsaData base64EncodedStringWithOptions:0],
        @"aes" : [aes base64EncodedStringWithOptions:0]
    };
}
NSString *FNMediaURL(NSDictionary *photo, BOOL original) {
    if (![photo isKindOfClass:NSDictionary.class])
        return @"";
    id additional = photo[@"additional"];
    id t = [additional isKindOfClass:NSDictionary.class] ? additional[@"thumbnail"] : nil;
    if (![t isKindOfClass:NSDictionary.class])
        return @"";
    // APK PhotoInfo.getVideoUrl / VideoQualityMonitor.b0 use videoUrl for movies.
    // originalUrl can refer to the image/poster representation of the same item.
    NSArray *keys = original ? (FNIsVideo(photo) ? @[ @"videoUrl", @"originalUrl" ] : @[ @"originalUrl" ])
                             : (FNIsVideo(photo) ? @[ @"sUrl", @"xsUrl", @"mUrl" ]
                                                 : @[ @"sUrl", @"xsUrl", @"mUrl", @"originalUrl" ]);
    for (NSString *key in keys)
        if ([t[key] isKindOfClass:NSString.class] && [t[key] length])
            return t[key];
    return @"";
}
// APK PhotoInfo.mediaDuration and LI.d use seconds, not milliseconds.
NSString *FNVideoDurationText(NSDictionary *photo) {
    if (!FNIsVideo(photo)) return @"";
    id value = photo[@"mediaDuration"];
    if (![value isKindOfClass:NSNumber.class] && ![value isKindOfClass:NSString.class]) return @"";
    double raw = [value doubleValue];
    if (!isfinite(raw) || raw <= 0 || raw > 315360000) return @"";
    long long seconds = MAX(1LL, (long long)raw);
    return seconds >= 3600
        ? [NSString stringWithFormat:@"%02lld:%02lld:%02lld", seconds/3600, seconds/60%60, seconds%60]
        : [NSString stringWithFormat:@"%02lld:%02lld", seconds/60, seconds%60];
}
NSString *FNMediaSizeText(NSArray<NSDictionary *> *photos) {
    if (!photos.count) return @"";
    long long total=0;
    for (id photo in photos) {
        if (![photo isKindOfClass:NSDictionary.class]) return @"大小未知";
        id value=photo[@"fileSize"];
        if (![value isKindOfClass:NSNumber.class] && ![value isKindOfClass:NSString.class]) return @"大小未知";
        if ([value isKindOfClass:NSString.class] && (![value length] ||
            [value rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location!=NSNotFound)) return @"大小未知";
        double raw=[value doubleValue];
        if (!isfinite(raw) || raw<=0 || raw>=(double)LLONG_MAX) return @"大小未知";
        long long size=[value longLongValue];
        if (size<=0 || total>LLONG_MAX-size) return @"大小未知";
        total+=size;
    }
    return [NSByteCountFormatter stringFromByteCount:total countStyle:NSByteCountFormatterCountStyleFile];
}
NSString *FNPersonPortraitURL(NSDictionary *entry) {
    id face = entry[@"faceId"];
    if (![face isKindOfClass:NSNumber.class] || [face longLongValue] <= 0)
        return @"";
    return [NSString stringWithFormat:@"/p/api/v1/stream/face/%@", face];
}
BOOL FNIsPhoto(NSDictionary *p) {
    if (![p isKindOfClass:NSDictionary.class])
        return NO;
    NSString *name = [p[@"fileName"] isKindOfClass:NSString.class] ? p[@"fileName"] : @"";
    NSString *ext = name.pathExtension.lowercaseString;
    return [p[@"fileType"] isEqual:@"image"] || [@[
               @"jpg", @"jpeg", @"heic", @"heif", @"png", @"gif", @"webp", @"bmp", @"tif", @"tiff", @"avif",
               @"dng", @"cr2",  @"cr3",  @"nef",  @"arw", @"raf", @"rw2",  @"orf", @"pef", @"srw"
           ] containsObject:ext];
}
BOOL FNIsVideo(NSDictionary *p) {
    if (![p isKindOfClass:NSDictionary.class])
        return NO;
    NSString *name = [p[@"fileName"] isKindOfClass:NSString.class] ? p[@"fileName"] : @"";
    return
        [p[@"fileType"] isEqual:@"video"] || [@[
            @"mp4", @"mov", @"m4v", @"mkv", @"avi", @"webm", @"mts", @"m2ts", @"3gp", @"mpg", @"mpeg", @"wmv"
        ] containsObject:name.pathExtension.lowercaseString];
}
BOOL FNIsSupportedMedia(NSDictionary *photo) {
    return FNIsPhoto(photo) || FNIsVideo(photo);
}
NSArray<NSDictionary *> *FNMediaTypeCategories(void) {
    return @[
        @{@"name" : @"视频", @"value" : @"video"}, @{@"name" : @"实况照片", @"value" : @"live_photo"},
        @{@"name" : @"GIF 动图", @"value" : @"gif"}, @{@"name" : @"截图", @"value" : @"screenshot"},
        @{@"name" : @"全景照片", @"value" : @"panorama"}, @{@"name" : @"RAW 照片", @"value" : @"raw"},
        @{@"name" : @"360° 照片", @"value" : @"360"}
    ];
}
static NSDictionary *FNFilter(NSString *name, NSString *value, NSArray *children) {
    return @{
        @"filterName" : name,
        @"filterValue" : value,
        @"filterBindingValue" : @"",
        @"subFilters" : children ?: @[]
    };
}
NSArray<NSDictionary *> *FNCategoryFilters(NSString *kind, NSDictionary *entry) {
    if ([kind isEqual:@"person"] && [entry[@"id"] isKindOfClass:NSNumber.class])
        return @[ FNFilter(@"person", [entry[@"id"] stringValue], nil) ];
    if ([kind isEqual:@"location"] && [entry[@"country"] isKindOfClass:NSString.class] &&
        [entry[@"city"] isKindOfClass:NSString.class])
        return @[ FNFilter(@"photo_location", entry[@"country"],
                           @[ FNFilter(entry[@"country"], entry[@"city"], nil) ]) ];
    if ([kind isEqual:@"media"] && [entry[@"value"] isKindOfClass:NSString.class])
        for (NSDictionary *type in FNMediaTypeCategories())
            if ([type[@"value"] isEqual:entry[@"value"]])
                return @[ FNFilter(@"file_type", entry[@"value"], nil) ];
    return @[];
}

#ifndef FN_SESSION_SERVICE
#define FN_SESSION_SERVICE @"org.ac.WeChatFnAlbum.session"
#endif
static NSString *const Service = FN_SESSION_SERVICE;
static NSDictionary *KeyQuery(void) {
    return @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : Service,
        (__bridge id)kSecAttrAccount : @"nas"
    };
}
static NSDictionary *LoadSession(NSError **error) {
    NSMutableDictionary *q = [KeyQuery() mutableCopy];
    q[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef value = NULL;
    OSStatus s = SecItemCopyMatching((__bridge CFDictionaryRef)q, &value);
    if (s == errSecItemNotFound)
        return nil;
    if (s != errSecSuccess) {
        if (error)
            *error = FNError(@"无法读取钥匙串，请解锁设备后重试。");
        return nil;
    }
    NSData *data = CFBridgingRelease(value);
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:NSDictionary.class]) {
        if (error)
            *error = FNError(@"保存的会话格式无效，请退出账号后重新登录。");
        return nil;
    }
    return obj;
}
static NSError *SaveSession(NSDictionary *value) {
    NSData *data = JSON(value);
    NSDictionary *attrs = @{
        (__bridge id)kSecValueData : data,
        (__bridge id)kSecAttrAccessible : (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    };
    OSStatus s = SecItemUpdate((__bridge CFDictionaryRef)KeyQuery(), (__bridge CFDictionaryRef)attrs);
    if (s == errSecItemNotFound) {
        NSMutableDictionary *q = [KeyQuery() mutableCopy];
        [q addEntriesFromDictionary:attrs];
        s = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
    }
    return s == errSecSuccess ? nil : FNError(@"登录成功，但钥匙串保存失败；重启后需要重新登录。");
}
BOOL FNRouteUsesLocal(NSInteger mode, NSString *homeSSID, NSString *currentSSID) {
    return mode == 2 || (mode == 1 && homeSSID.length && currentSSID.length && [homeSSID isEqual:currentSSID]);
}
static BOOL SameOrigin(NSURL *a, NSURL *b) {
    if (!a || !b) return NO;
    NSNumber *(^port)(NSURL *) = ^NSNumber *(NSURL *u) { return u.port ?: ([u.scheme.lowercaseString isEqual:@"https"] ? @443 : @80); };
    return [a.scheme.lowercaseString isEqual:b.scheme.lowercaseString] &&
        [a.host.lowercaseString isEqual:b.host.lowercaseString] && [port(a) isEqual:port(b)];
}
static BOOL TrustedOrigin(NSURL *url, NSArray<NSURL *> *origins) {
    for (NSURL *origin in origins) if (SameOrigin(url, origin)) return YES;
    return NO;
}
@interface FNClient ()
@property(nonatomic) NSURL *baseURL;
@property(nonatomic) NSString *username;
@property(nonatomic) NSString *token;
@property(nonatomic) NSString *longToken;
@property(nonatomic) NSArray<NSURL *> *routeOrigins;
@property(nonatomic) NSURL *routeEndpoint;
@property(nonatomic) NSDictionary *routeSnapshot;
@property(nonatomic) NSData *secret;
@property(nonatomic) NSURLSession *session;
@property(nonatomic) NSURLSessionWebSocketTask *socket;
@property(nonatomic) NSMutableDictionary<NSString *, FNResult> *pending;
@property(nonatomic) NSString *pub;
@property(nonatomic) NSString *si;
@property(nonatomic) NSString *challenge;
@property(nonatomic) NSData *aesKey;
@property(nonatomic) NSData *iv;
@property(nonatomic) BOOL remember;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL authenticating;
@property(nonatomic) NSUInteger authOperation;
@property(nonatomic) NSMutableArray<FNResult> *authWaiters;
- (void)recoverToken:(NSString *)usedToken completion:(FNResult)completion;
- (NSMutableURLRequest *)authorizedCopy:(NSURLRequest *)request error:(NSError **)error;
- (NSError *)responseError:(NSURLResponse *)response error:(NSError *)error;
@end

typedef void (^FNHTTPResult)(NSData *, NSURLResponse *, NSError *);
@interface FNHTTPOperation : NSObject
@property(nonatomic) FNClient *client;
@property(nonatomic) NSURLRequest *request;
@property(nonatomic) NSURL *target;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) FNTransfer *transfer;
@property(nonatomic, copy) FNHTTPResult completion;
@property(nonatomic) BOOL retried;
@property(nonatomic) BOOL finished;
- (void)start;
- (void)finishData:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error;
@end
@implementation FNHTTPOperation
- (void)finishData:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
    Main(^{
        if (self.finished) return;
        self.finished = YES;
        self.transfer.onCancel = nil;
        self.transfer.underlying = nil;
        FNHTTPResult completion = self.completion;
        self.completion = nil;
        if (completion) completion(data, response, error);
    });
}
- (void)consume:(NSData *)data location:(NSURL *)location response:(NSURLResponse *)response
          error:(NSError *)error usedToken:(NSString *)token {
    // A download location exists only until its completion handler returns.
    // Move a successful file before dispatching any asynchronous work.
    NSInteger status = [(NSHTTPURLResponse *)response statusCode];
    NSError *fileError = error;
    BOOL moved = NO;
    if (!fileError && location && status >= 200 && status < 300 &&
        self.generation == self.client.generation && !self.transfer.cancelled && !self.finished) {
        [NSFileManager.defaultManager createDirectoryAtURL:self.target.URLByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:
            @{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&fileError];
        if (!fileError) moved = [NSFileManager.defaultManager moveItemAtURL:location toURL:self.target error:&fileError];
        if (!fileError) [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0644}
                                                     ofItemAtPath:self.target.path error:&fileError];
    }
    Main(^{
        if (self.generation != self.client.generation || self.transfer.cancelled || self.finished) {
            if (moved) [NSFileManager.defaultManager removeItemAtURL:self.target error:nil];
            [self finishData:nil response:response error:FNError(@"NAS 会话已改变或下载已取消。")];
            return;
        }
        if (!fileError && status == 401 && !self.retried) {
            self.retried = YES;
            self.transfer.underlying = nil;
            [self.client recoverToken:token completion:^(NSDictionary *result, NSError *renewError) {
                if (self.finished) return;
                if (renewError) [self finishData:nil response:response error:renewError];
                else [self start];
            }];
            return;
        }
        NSError *resultError = [self.client responseError:response error:fileError];
        if (resultError && moved) [NSFileManager.defaultManager removeItemAtURL:self.target error:nil];
        [self finishData:resultError ? nil : data response:response error:resultError];
    });
}
- (void)start {
    if (self.finished) return;
    if (self.transfer.cancelled || self.generation != self.client.generation) {
        [self finishData:nil response:nil error:FNError(@"NAS 会话已改变或下载已取消。")];
        return;
    }
    NSError *error = nil;
    NSURLRequest *request = [self.client authorizedCopy:self.request error:&error];
    if (!request) { [self finishData:nil response:nil error:error]; return; }
    NSString *token = [request valueForHTTPHeaderField:@"accessToken"];
    NSURLSessionTask *task;
    if (self.target) {
        task = [self.client.session downloadTaskWithRequest:request completionHandler:
            ^(NSURL *location, NSURLResponse *response, NSError *error) {
                [self consume:nil location:location response:response error:error usedToken:token];
            }];
    } else {
        task = [self.client.session dataTaskWithRequest:request completionHandler:
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                [self consume:data location:nil response:response error:error usedToken:token];
            }];
    }
    self.transfer.underlying = task;
    [task resume];
}
@end
@implementation FNClient
+ (instancetype)shared {
    static FNClient *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [self new];
    });
    return s;
}
- (instancetype)init {
    if ((self = [super init])) {
        _username = @"";
        _pending = [NSMutableDictionary dictionary];
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        c.timeoutIntervalForRequest = 20;
        c.timeoutIntervalForResource = 300;
        c.HTTPMaximumConnectionsPerHost = 4;
        c.HTTPShouldSetCookies = NO;
        _session = [NSURLSession sessionWithConfiguration:c
                                                 delegate:self
                                            delegateQueue:NSOperationQueue.mainQueue];
    }
    return self;
}
- (BOOL)authenticated {
    return self.token.length > 0;
}
- (void)stopSocket {
    [self.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    self.socket = nil;
    NSArray *blocks = self.pending.allValues;
    [self.pending removeAllObjects];
    for (FNResult cb in blocks)
        cb(nil, FNError(@"连接已结束，请重试。"));
    self.pub = nil;
    self.si = nil;
    self.aesKey = nil;
    self.iv = nil;
    self.challenge = nil;
}
- (void)logout {
    [self invalidateSession:FNError(@"已退出 NAS 账号。")];
}
- (void)cancelAuthentication:(NSError *)error {
    self.authOperation++;
    self.authenticating = NO;
    NSArray *callbacks = [self.authWaiters copy];
    [self.authWaiters removeAllObjects];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (FNResult callback in callbacks) callback(nil, error);
    });
}
- (void)invalidateSession:(NSError *)error {
    self.generation++;
    self.token = nil;
    self.secret = nil;
    self.longToken = nil;
    self.remember = NO;
    self.routeSnapshot = nil;
    SecItemDelete((__bridge CFDictionaryRef)KeyQuery());
    [self cancelAuthentication:error];
    [self stopSocket];
}
- (void)receive:(NSURLSessionWebSocketTask *)socket {
    __weak typeof(self) weak = self;
    [socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        Main(^{
            FNClient *s = weak;
            if (!s || socket != s.socket)
                return;
            if (error) {
                NSArray *blocks = s.pending.allValues;
                [s.pending removeAllObjects];
                for (FNResult cb in blocks)
                    cb(nil, FNError(@"NAS 连接中断，请检查网络后重试。"));
                return;
            }
            NSData *data = message.data ?: [message.string dataUsingEncoding:NSUTF8StringEncoding];
            if (data.length > 44 && ((const char *)data.bytes)[0] != '{')
                data = [data subdataWithRange:NSMakeRange(44, data.length - 44)];
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:NSDictionary.class]) {
                NSString *rid = obj[@"reqid"];
                FNResult cb = s.pending[rid];
                if (cb) {
                    [s.pending removeObjectForKey:rid];
                    cb(obj, nil);
                }
            }
            [s receive:socket];
        });
    }];
}
- (void)rpc:(NSString *)req
       payload:(NSDictionary *)payload
       encrypt:(BOOL)encrypt
        signed:(BOOL)signedRequest
    completion:(FNResult)completion {
    NSString *rid = NSUUID.UUID.UUIDString;
    NSMutableDictionary *p = [payload mutableCopy];
    p[@"req"] = req;
    p[@"reqid"] = rid;
    NSDictionary *wire = p;
    NSError *error = nil;
    if (encrypt) {
        NSMutableData *key = [NSMutableData dataWithLength:32], *iv = [NSMutableData dataWithLength:16];
        if (SecRandomCopyBytes(kSecRandomDefault, 32, key.mutableBytes) ||
            SecRandomCopyBytes(kSecRandomDefault, 16, iv.mutableBytes)) {
            completion(nil, FNError(@"无法生成登录随机数。"));
            return;
        }
        self.aesKey = key;
        self.iv = iv;
        wire = FNEncrypted(p, self.pub, key, iv, &error);
    }
    if (error || !wire) {
        completion(nil, error ?: FNError(@"请求编码失败。"));
        return;
    }
    NSString *text = [[NSString alloc] initWithData:JSON(wire) encoding:NSUTF8StringEncoding];
    if (signedRequest) {
        if (!self.secret.length) {
            completion(nil, FNError(@"缺少会话签名密钥，请重新登录。"));
            return;
        }
        unsigned char mac[CC_SHA256_DIGEST_LENGTH];
        NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
        CCHmac(kCCHmacAlgSHA256, self.secret.bytes, self.secret.length, bytes.bytes, bytes.length, mac);
        text = [[[NSData dataWithBytes:mac length:sizeof(mac)] base64EncodedStringWithOptions:0]
            stringByAppendingString:text];
    }
    self.pending[rid] = [completion copy];
    [self.socket sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text]
           completionHandler:^(NSError *e) {
               if (e)
                   Main(^{
                       FNResult cb = self.pending[rid];
                       [self.pending removeObjectForKey:rid];
                       if (cb)
                           cb(nil, FNError(@"无法向 NAS 发送登录请求。"));
                   });
           }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        FNResult cb = self.pending[rid];
        [self.pending removeObjectForKey:rid];
        if (cb)
            cb(nil, FNError(@"NAS 登录请求超时，请检查地址和网络。"));
    });
}
- (void)connect:(FNResult)completion {
    [self stopSocket];
    NSURLComponents *c = [NSURLComponents componentsWithURL:self.baseURL resolvingAgainstBaseURL:NO];
    c.scheme = [c.scheme isEqual:@"https"] ? @"wss" : @"ws";
    c.path = @"/websocket";
    c.query = @"type=main";
    self.socket = [self.session webSocketTaskWithURL:c.URL];
    [self.socket resume];
    [self receive:self.socket];
    [self rpc:@"util.crypto.getRSAPub"
           payload:@{}
           encrypt:NO
            signed:NO
        completion:^(NSDictionary *r, NSError *e) {
            if (e) {
                completion(nil, e);
                return;
            }
            if (![r[@"pub"] isKindOfClass:NSString.class] || !r[@"si"]) {
                completion(nil, FNError(@"NAS 登录握手格式不兼容。"));
                return;
            }
            self.pub = r[@"pub"];
            self.si = r[@"si"];
            completion(r, nil);
        }];
}
- (void)finish:(NSDictionary *)r
         error:(NSError *)error
     restoring:(BOOL)restoring
    completion:(FNResult)completion {
    if (error) {
        completion(nil, error);
        return;
    }
    if (![r[@"result"] isEqual:@"succ"]) {
        if (restoring && [r[@"errno"] integerValue] == 135168) {
            [self invalidateSession:AuthExpired()];
            completion(nil, AuthExpired());
        } else if (restoring) {
            completion(nil, FNError([NSString stringWithFormat:@"NAS 暂时无法恢复会话（代码 %@），请稍后重试。",
                r[@"errno"] ?: @"未知"]));
        } else {
            self.token = nil;
            completion(nil, FNError([NSString stringWithFormat:@"登录失败（%@），请检查账号、密码或验证码。",
                                                               r[@"errno"] ?: @"未知"]));
        }
        return;
    }
    if (!r[@"token"] && [r[@"isBindTwofaSecret"] boolValue] && r[@"accessToken"]) {
        self.challenge = r[@"accessToken"];
        completion(@{@"twofa" : @YES}, nil);
        return;
    }
    if (!r[@"token"] && [r[@"isTwofaEnforced"] boolValue]) {
        completion(nil, FNError(@"请先在飞牛中完成两步验证绑定。"));
        return;
    }
    if (!restoring) {
        NSData *encrypted = [[NSData alloc] initWithBase64EncodedString:r[@"secret"] ?: @"" options:0];
        self.secret = FNAES(encrypted, self.aesKey, self.iv, NO, &error);
        if (error || !self.secret.length) {
            completion(nil, error ?: FNError(@"NAS 未返回完整登录凭据。"));
            return;
        }
    }
    if ([r[@"token"] isKindOfClass:NSString.class] && [r[@"token"] length]) self.token = r[@"token"];
    if ([r[@"longToken"] isKindOfClass:NSString.class] && [r[@"longToken"] length]) self.longToken = r[@"longToken"];
    self.aesKey = nil;
    self.iv = nil;
    self.challenge = nil;
    if (!self.token.length) {
        completion(nil, FNError(@"NAS 未返回登录令牌。"));
        return;
    }
    NSError *warning = nil;
    if (self.remember)
        warning = SaveSession(@{
            @"endpoint" : self.baseURL.absoluteString,
            @"username" : self.username,
            @"token" : self.token,
            @"longToken" : self.longToken ?: @"",
            @"secret" : [self.secret base64EncodedStringWithOptions:0]
        });
    else
        SecItemDelete((__bridge CFDictionaryRef)KeyQuery());
    completion(warning ? @{@"warning" : warning.localizedDescription} : @{}, nil);
}
- (void)loginAddress:(NSString *)address
                user:(NSString *)user
            password:(NSString *)password
            remember:(BOOL)remember
          completion:(FNResult)completion {
    NSError *e = nil;
    NSURL *url = FNEndpoint(address, &e);
    if (!url) {
        completion(nil, e);
        return;
    }
    self.routeSnapshot = nil;
    self.generation++;
    [self cancelAuthentication:FNError(@"NAS 账号已改变，请重试。")];
    self.token = nil;
    self.secret = nil;
    self.longToken = nil;
    self.baseURL = url;
    self.username = user;
    self.remember = remember;
    NSUInteger generation = self.generation;
    [self connect:^(NSDictionary *r, NSError *error) {
        if (generation != self.generation) { completion(nil,FNError(@"NAS 账号已改变，请重试。")); return; }
        if (error) {
            completion(nil, error);
            return;
        }
        NSDictionary *p = @{
            @"user" : user,
            @"password" : password,
            @"stay" : @(remember),
            @"deviceType" : @"Mobile",
            @"deviceName" : @"微信飞牛相册",
            @"did" : NSUUID.UUID.UUIDString,
            @"si" : self.si
        };
        [self rpc:@"user.login"
               payload:p
               encrypt:YES
                signed:NO
            completion:^(NSDictionary *v, NSError *err) {
                if (generation != self.generation) { completion(nil,FNError(@"NAS 账号已改变，请重试。")); return; }
                [self finish:v error:err restoring:NO completion:completion];
            }];
    }];
}
- (void)twoFactor:(NSString *)code completion:(FNResult)completion {
    if (!self.challenge) {
        completion(nil, FNError(@"验证会话已结束，请重新登录。"));
        return;
    }
    NSCharacterSet *bad = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    if (code.length != 6 || [code rangeOfCharacterFromSet:bad].location != NSNotFound) {
        completion(nil, FNError(@"请输入六位验证码。"));
        return;
    }
    NSUInteger generation = self.generation;
    [self rpc:@"user.2fa.loginVerify"
           payload:@{
               @"code" : code,
               @"isTrustedDevice" : @NO,
               @"accessToken" : self.challenge,
               @"stay" : @(self.remember),
               @"deviceType" : @"Mobile",
               @"deviceName" : @"微信飞牛相册",
               @"did" : NSUUID.UUID.UUIDString,
               @"si" : self.si
           }
           encrypt:YES
            signed:NO
        completion:^(NSDictionary *r, NSError *e) {
            if (generation != self.generation) { completion(nil,FNError(@"NAS 账号已改变，请重试。")); return; }
            [self finish:r error:e restoring:NO completion:completion];
        }];
}
- (void)clearRouting {
    self.routeOrigins = nil;
    self.routeEndpoint = nil;
}
- (void)routeToAddress:(NSString *)address trustedAddresses:(NSArray<NSString *> *)addresses completion:(FNResult)completion {
    NSError *error = nil;
    NSURL *target = FNEndpoint(address, &error);
    NSMutableArray *origins = [NSMutableArray array];
    for (NSString *value in addresses) {
        NSURL *origin = FNEndpoint(value, &error);
        if (!origin) { completion(nil,error); return; }
        [origins addObject:origin];
    }
    if (!target || !TrustedOrigin(target, origins)) { completion(nil,error ?: FNError(@"所选地址不在已配置的 NAS 地址中。")); return; }
    NSDictionary *saved = self.routeSnapshot;
    BOOL remember = self.remember;
    if (self.token.length && self.secret.length) {
        saved = @{@"endpoint":self.baseURL.absoluteString, @"username":self.username,
                  @"token":self.token, @"longToken":self.longToken ?: @"",
                  @"secret":[self.secret base64EncodedStringWithOptions:0]};
    } else if (!saved) { saved = LoadSession(&error); remember = YES; }
    if (error) { completion(nil,error); return; }
    NSURL *source = saved ? FNEndpoint(saved[@"endpoint"] ?: @"", &error) : nil;
    if (saved && (!source || !TrustedOrigin(source,origins))) {
        completion(nil,FNError(@"当前账号的 NAS 地址不在内外网地址配置中，请先核对地址或退出后登录对应 NAS。")); return;
    }
    self.routeOrigins = origins;
    self.routeEndpoint = target;
    if (!saved) { self.baseURL = target; completion(nil,nil); return; }
    if (self.authenticated && SameOrigin(self.baseURL,target)) { completion(@{},nil); return; }
    self.generation++;
    [self cancelAuthentication:FNError(@"NAS 访问地址已切换。")];
    [self stopSocket];
    self.routeSnapshot = saved;
    self.token = nil;
    self.baseURL = target;
    self.username = saved[@"username"] ?: @"";
    self.secret = [[NSData alloc] initWithBase64EncodedString:saved[@"secret"] ?: @"" options:0];
    self.longToken = saved[@"longToken"];
    self.remember = remember;
    [self authenticateToken:saved[@"token"] preferLong:NO completion:^(NSDictionary *result, NSError *error) {
        if (!error) self.routeSnapshot = nil;
        completion(result,error);
    }];
}
- (void)restore:(FNResult)completion {
    if (self.authenticated) {
        completion(@{}, nil);
        return;
    }
    if (self.authenticating) {
        [self.authWaiters addObject:[completion copy]];
        return;
    }
    NSError *error = nil;
    NSDictionary *saved = self.routeSnapshot ?: LoadSession(&error);
    if (!saved) {
        completion(nil, error);
        return;
    }
    NSURL *url = FNEndpoint(saved[@"endpoint"] ?: @"", &error);
    if (self.routeEndpoint && TrustedOrigin(url,self.routeOrigins)) url = self.routeEndpoint;
    NSData *secret = [[NSData alloc] initWithBase64EncodedString:saved[@"secret"] ?: @"" options:0];
    if (!url || !secret.length || ![saved[@"token"] length]) {
        completion(nil, FNError(@"保存的会话不完整，请退出账号后重新登录。"));
        return;
    }
    self.generation++;
    self.baseURL = url;
    self.username = saved[@"username"] ?: @"";
    self.secret = secret;
    self.longToken = saved[@"longToken"];
    self.remember = self.routeSnapshot ? self.remember : YES;
    NSString *token = saved[@"token"];
    [self authenticateToken:token preferLong:NO completion:completion];
}
- (void)authenticateToken:(NSString *)token preferLong:(BOOL)preferLong completion:(FNResult)completion {
    if (self.authenticating) {
        [self.authWaiters addObject:[completion copy]];
        return;
    }
    if (!self.secret.length || !token.length) {
        completion(nil, FNError(@"保存的登录信息不完整，请重新登录。"));
        return;
    }
    self.authenticating = YES;
    NSUInteger operation = ++self.authOperation;
    NSUInteger generation = self.generation;
    self.authWaiters = [NSMutableArray arrayWithObject:[completion copy]];
    void (^done)(NSDictionary *, NSError *) = ^(NSDictionary *result, NSError *error) {
        if (operation != self.authOperation || generation != self.generation) return;
        self.authenticating = NO;
        NSArray *waiters = [self.authWaiters copy];
        [self.authWaiters removeAllObjects];
        for (FNResult waiter in waiters) waiter(result, error);
    };
    void (^accept)(NSDictionary *, NSError *, BOOL) = ^(NSDictionary *result, NSError *error, BOOL allowOld) {
        if (operation != self.authOperation || generation != self.generation) return;
        if (!error && [result[@"result"] isEqual:@"succ"] &&
            (![result[@"token"] isKindOfClass:NSString.class] || ![result[@"token"] length])) {
            if (allowOld) self.token = token;
            else { done(nil, FNError(@"NAS 续期未返回新令牌，请稍后重试。")); return; }
        }
        [self finish:result error:error restoring:YES completion:done];
    };
    void (^longLogin)(void) = ^{
        [self rpc:@"user.tokenLogin" payload:@{
            @"token":self.longToken, @"si":self.si, @"deviceType":@"Mobile",
            @"deviceName":@"微信飞牛相册", @"did":NSUUID.UUID.UUIDString
        } encrypt:NO signed:YES completion:^(NSDictionary *result, NSError *error) {
            accept(result,error,NO);
        }];
    };
    [self connect:^(NSDictionary *r, NSError *e) {
        if (operation != self.authOperation || generation != self.generation) return;
        if (e) {
            done(nil, e);
            return;
        }
        if (preferLong && self.longToken.length) { longLogin(); return; }
        [self rpc:@"user.authToken"
            payload:@{
                @"main" : @YES,
                @"token" : token,
                @"si" : self.si
            }
            encrypt:NO
            signed:YES
            completion:^(NSDictionary *v, NSError *err) {
                if (operation != self.authOperation || generation != self.generation) return;
                if (!err && [v[@"errno"] integerValue] == 135168 && self.longToken.length) {
                    longLogin();
                } else accept(v, err, YES);
            }];
    }];
}
- (void)recoverToken:(NSString *)usedToken completion:(FNResult)completion {
    // Other concurrent requests may have already rotated this rejected token.
    if (self.authenticated && ![self.token isEqual:usedToken]) { completion(@{},nil); return; }
    [self authenticateToken:self.token preferLong:YES completion:completion];
}
- (NSMutableURLRequest *)request:(NSString *)path params:(NSDictionary *)params error:(NSError **)error {
    NSURL *url = [[NSURL URLWithString:path relativeToURL:self.baseURL] absoluteURL];
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    // Absolute URLs may use either explicitly configured alias of this same NAS.
    // Rebind only their origin; retain path/query and sign the final active URL.
    if (self.routeEndpoint && TrustedOrigin(self.baseURL,self.routeOrigins) && TrustedOrigin(url,self.routeOrigins) && !c.user && !c.password && !c.fragment) {
        NSURLComponents *active = [NSURLComponents componentsWithURL:self.baseURL resolvingAgainstBaseURL:YES];
        c.scheme = active.scheme; c.host = active.host; c.port = active.port;
        url = c.URL;
    }
    NSNumber * (^port)(NSURL *) = ^NSNumber *(NSURL *u) {
        return u.port ?: ([u.scheme isEqual:@"https"] ? @443 : @80);
    };
    if (!url || ![url.scheme.lowercaseString isEqual:self.baseURL.scheme.lowercaseString] ||
        ![url.host.lowercaseString isEqual:self.baseURL.host.lowercaseString] ||
        ![port(url) isEqual:port(self.baseURL)] || c.user || c.password || c.fragment) {
        if (error)
            *error = FNError(@"媒体地址不属于当前 NAS，已停止请求。");
        return nil;
    }
    if (!self.authenticated) {
        if (error)
            *error = FNError(@"请先登录飞牛 NAS。");
        return nil;
    }
    if (params.count) {
        NSMutableArray *items = [c.queryItems mutableCopy] ?: [NSMutableArray array];
        for (NSString *k in [[params allKeys] sortedArrayUsingSelector:@selector(compare:)])
            [items addObject:[NSURLQueryItem queryItemWithName:k value:[params[k] description]]];
        c.queryItems = items;
    }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:c.URL];
    [r setValue:self.token forHTTPHeaderField:@"accessToken"];
    [r setValue:self.token forHTTPHeaderField:@"Authorization"];
    [r setValue:[NSString stringWithFormat:@"mode=relay;fnos-token=%@", self.token]
        forHTTPHeaderField:@"Cookie"];
    [r setValue:@"WeChatFnAlbum/0.4.3" forHTTPHeaderField:@"User-Agent"];
    [r setValue:FNAuthx(c.URL, [NSString stringWithFormat:@"%u", 100000 + arc4random_uniform(900000)],
                        [NSString stringWithFormat:@"%.0f", NSDate.date.timeIntervalSince1970 * 1000])
        forHTTPHeaderField:@"authx"];
    return r;
}
- (NSMutableURLRequest *)authorizedCopy:(NSURLRequest *)request error:(NSError **)error {
    NSMutableURLRequest *fresh = [self request:request.URL.absoluteString params:@{} error:error];
    if (!fresh) return nil;
    NSMutableURLRequest *retry = [request mutableCopy];
    for (NSString *key in fresh.allHTTPHeaderFields)
        [retry setValue:[fresh valueForHTTPHeaderField:key] forHTTPHeaderField:key];
    if (![retry.HTTPMethod isEqual:@"GET"])
        [retry setValue:FNBodyAuthx(retry.URL,retry.HTTPBody ?: [NSData data],
            [NSString stringWithFormat:@"%u",100000+arc4random_uniform(900000)],
            [NSString stringWithFormat:@"%.0f",NSDate.date.timeIntervalSince1970*1000]) forHTTPHeaderField:@"authx"];
    return retry;
}
- (NSError *)responseError:(NSURLResponse *)response error:(NSError *)error {
    if (error)
        return FNError(error.code == NSURLErrorCancelled ? @"已取消。"
                                                         : @"NAS 请求失败，请检查网络、地址和证书。");
    NSInteger code = [(NSHTTPURLResponse *)response statusCode];
    if (code == 401) {
        return FNError(@"NAS 续期后仍拒绝访问（HTTP 401），请检查相册权限或重新登录。登录凭据已保留。");
    }
    if (code < 200 || code >= 300)
        return FNError([NSString stringWithFormat:@"NAS 请求失败（HTTP %ld）。", (long)code]);
    return nil;
}
- (void)get:(NSString *)path params:(NSDictionary *)params completion:(FNResult)completion {
    NSError *e = nil;
    NSURLRequest *r = [self request:path params:params error:&e];
    if (!r) {
        completion(nil, e);
        return;
    }
    [self perform:r completion:completion];
}
- (void)search:(NSString *)keyword completion:(FNResult)completion {
    keyword = [keyword stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!keyword.length || keyword.length > 500) {
        completion(nil, FNError(@"请输入 1～500 字的图片描述。"));
        return;
    }
    [self post:@"/p/api/v1/magic-search/do"
              body:@{@"keyword" : keyword, @"viewMode" : @"simple"}
        completion:^(NSDictionary *result, NSError *error) {
            if (!error && [result[@"errorCode"] isKindOfClass:NSNumber.class] &&
                [result[@"errorCode"] integerValue])
                error = FNError(SearchError([result[@"errorCode"] integerValue]));
            if (!error && ![result[@"list"] isKindOfClass:NSArray.class])
                error = FNError(@"AI 搜索结果格式不兼容，请检查 NAS 相册版本。");
            completion(error ? nil : result, error);
        }];
}
- (void)photoDetails:(NSArray<NSNumber *> *)ids completion:(FNResult)completion {
    [self post:@"/p/api/v1/gallery/batchGetByIds" body:@{@"ids" : ids} completion:completion];
}
- (void)filteredPhotos:(NSArray<NSDictionary *> *)filters completion:(FNResult)completion {
    [self post:@"/p/api/v1/search/results"
              body:@{
                  @"filters" : filters,
                  @"antiFilters" : @[],
                  @"showFilterBar" : @NO,
                  @"viewMode" : @"simple"
              }
        completion:completion];
}
- (void)post:(NSString *)path body:(NSDictionary *)body completion:(FNResult)completion {
    NSError *e = nil;
    NSMutableURLRequest *r = [self request:path params:@{} error:&e];
    if (!r) {
        completion(nil, e);
        return;
    }
    r.HTTPMethod = @"POST";
    r.timeoutInterval = 90;
    // APK SignerInterceptor hashes the exact RequestBody bytes for non-GET requests.
    r.HTTPBody = JSON(body);
    [r setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [r setValue:FNBodyAuthx(r.URL, r.HTTPBody,
                            [NSString stringWithFormat:@"%u", 100000 + arc4random_uniform(900000)],
                            [NSString stringWithFormat:@"%.0f", NSDate.date.timeIntervalSince1970 * 1000])
        forHTTPHeaderField:@"authx"];
    [self perform:r completion:completion];
}
- (FNTransfer *)transferRequest:(NSURLRequest *)request to:(NSURL *)target completion:(FNHTTPResult)completion {
    FNHTTPOperation *operation = [FNHTTPOperation new];
    operation.client = self;
    operation.request = request;
    operation.target = target;
    operation.generation = self.generation;
    operation.transfer = [FNTransfer new];
    operation.completion = completion;
    __weak FNHTTPOperation *weak = operation;
    operation.transfer.onCancel = ^{
        [weak finishData:nil response:nil error:FNError(@"已取消。")];
    };
    [operation start];
    return operation.transfer;
}
- (void)perform:(NSURLRequest *)r completion:(FNResult)completion {
    [self transferRequest:r to:nil completion:^(NSData *data, NSURLResponse *response, NSError *error) {
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (!error && (![obj isKindOfClass:NSDictionary.class] ||
            ![obj[@"code"] isKindOfClass:NSNumber.class] || [obj[@"code"] integerValue] != 0))
            error = FNError([NSString stringWithFormat:@"相册接口请求失败（代码 %@），请检查相册服务与版本。",
                [obj isKindOfClass:NSDictionary.class] ? obj[@"code"] ?: @"未知" : @"未知"]);
        if (error && [r.URL.path isEqual:@"/p/api/v1/magic-search/do"] &&
            [obj isKindOfClass:NSDictionary.class] && [obj[@"code"] isKindOfClass:NSNumber.class] &&
            [obj[@"code"] integerValue]) error = FNError(SearchError([obj[@"code"] integerValue]));
        id result = [obj isKindOfClass:NSDictionary.class] ? obj[@"data"] : nil;
        // These lifecycle endpoints acknowledge success with null/bool on some NAS versions.
        BOOL acknowledgement = [@[@"/p/api/v1/video/decode/record",@"/p/api/v1/video/decode/quit"] containsObject:r.URL.path];
        if (!error && acknowledgement && ![result isKindOfClass:NSDictionary.class]) result = @{};
        if (!error && ![result isKindOfClass:NSDictionary.class]) error = FNError(@"相册接口返回格式不兼容。");
        completion(error ? nil : result, error);
    }];
}
- (NSDictionary *)originalVideoPlaybackConfiguration:(NSString *)path error:(NSError **)error {
    NSURLRequest *request=[self request:path params:@{} error:error];
    if (!request) return nil;
    // Host-only cookies are limited to this exact media path, never the global cookie jar.
    NSString *cookiePath=request.URL.path;
    if (!cookiePath.length || [cookiePath containsString:@";"] || [cookiePath containsString:@"\n"] ||
        [cookiePath containsString:@"\r"]) {
        if (error) *error=FNError(@"原视频地址格式无效。");
        return nil;
    }
    NSMutableArray *cookies=[NSMutableArray array];
    for (NSString *name in @[@"mode",@"fnos-token"]) {
        NSString *value=[name isEqual:@"mode"] ? @"relay" : self.token;
        NSString *line=[NSString stringWithFormat:@"%@=%@; Path=%@; HttpOnly%@",name,value,cookiePath,
            [request.URL.scheme.lowercaseString isEqual:@"https"] ? @"; Secure" : @""];
        [cookies addObjectsFromArray:[NSHTTPCookie cookiesWithResponseHeaderFields:@{@"Set-Cookie":line} forURL:request.URL]];
    }
    return @{@"url":request.URL,@"cookies":cookies};
}
- (NSDictionary *)videoPlaybackConfiguration:(NSString *)path error:(NSError **)error {
    NSURLRequest *request = [self request:path params:@{} error:error];
    if (!request) return nil;
    NSString *prefix = @"/p/api/v1/video/decode/stream/";
    if (![request.URL.path hasPrefix:prefix]) {
        if (error) *error = FNError(@"预览地址不是当前 NAS 的转码视频流。");
        return nil;
    }
    NSMutableArray *cookies = [NSMutableArray array];
    for (NSString *name in @[@"mode",@"fnos-token"]) {
        NSString *value = [name isEqual:@"mode"] ? @"relay" : self.token;
        NSString *line = [NSString stringWithFormat:@"%@=%@; Path=/p/api/v1/video/decode/stream/; HttpOnly%@",
            name,value,[request.URL.scheme.lowercaseString isEqual:@"https"] ? @"; Secure" : @""];
        [cookies addObjectsFromArray:[NSHTTPCookie cookiesWithResponseHeaderFields:@{@"Set-Cookie":line} forURL:request.URL]];
    }
    return @{@"url":request.URL,@"cookies":cookies};
}
- (FNTransfer *)media:(NSString *)path completion:(void (^)(NSData *, NSError *))completion {
    NSError *error = nil;
    NSURLRequest *request = [self request:path params:@{} error:&error];
    if (!request) { completion(nil,error); return nil; }
    return [self transferRequest:request to:nil completion:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data.length > 40*1024*1024) error = FNError(@"预览图片过大，请使用原图发送。");
        completion(error ? nil : data,error);
    }];
}
- (FNTransfer *)download:(NSString *)path to:(NSURL *)target completion:(void (^)(NSError *))completion {
    NSError *error = nil;
    NSURLRequest *request = [self request:path params:@{} error:&error];
    if (!request) { completion(error); return nil; }
    return [self transferRequest:request to:target completion:^(NSData *data, NSURLResponse *response, NSError *error) {
        completion(error);
    }];
}
- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

@interface FNPhotoPager ()
@property(nonatomic) NSArray *days;
@property(nonatomic) NSArray<NSNumber *> *searchIDs;
@property(nonatomic) BOOL datePaging;
@property(nonatomic) NSUInteger dayIndex;
@property(nonatomic) NSUInteger dayOffset;
@property(nonatomic) NSUInteger offset;
@property(nonatomic) BOOL hasNext;
@property(nonatomic) BOOL hasPrevious;
@property(nonatomic) NSUInteger headDayIndex;
@property(nonatomic) NSUInteger headOffset;
@property(nonatomic) BOOL loading;
@end
@implementation FNPhotoPager
- (instancetype)init {
    if ((self = [super init]))
        _hasNext = YES;
    return self;
}
- (void)next:(void (^)(NSArray *, NSError *))completion {
    if (self.loading) {
        completion(nil, FNError(@"正在读取上一页，请稍候。"));
        return;
    }
    if (!self.hasNext) {
        completion(@[], nil);
        return;
    }
    self.loading = YES;
    // Commit cursors only after a successful complete page, so retries don't skip rows.
    void (^done)(NSArray *, NSError *) = ^(NSArray *rows, NSError *e) {
        self.loading = NO;
        completion(rows, e);
    };
    if (self.searchKeyword.length || self.queryFilters.count) {
        if (self.searchIDs)
            [self loadSearchPage:done];
        else {
            FNResult result = ^(NSDictionary *r, NSError *e) {
                if (e) {
                    done(nil, e);
                    return;
                }
                id ids = r[@"idList"];
                if (![ids isKindOfClass:NSArray.class]) {
                    NSMutableArray *derived = [NSMutableArray array];
                    for (id row in r[@"list"])
                        if ([row isKindOfClass:NSDictionary.class] &&
                            [row[@"id"] isKindOfClass:NSNumber.class])
                            [derived addObject:row[@"id"]];
                    ids = derived;
                }
                for (id value in ids)
                    if (![value isKindOfClass:NSNumber.class] || [value longLongValue] <= 0) {
                        done(nil, FNError(@"AI 搜索返回的照片编号格式不兼容。"));
                        return;
                    }
                self.searchIDs = [[NSOrderedSet orderedSetWithArray:ids] array];
                [self loadSearchPage:done];
            };
            if (self.queryFilters.count)
                [[FNClient shared] filteredPhotos:self.queryFilters completion:result];
            else
                [[FNClient shared] search:self.searchKeyword completion:result];
        }
        return;
    }
    if (self.albumID && !self.datePaging) {
        [[FNClient shared] get:@"/p/api/v1/album/photos"
                        params:@{
                            @"album_id" : self.albumID,
                            @"sort_by" : @"date_time",
                            @"sort_direction" : @"desc",
                            @"offset" : @(self.offset),
                            @"limit" : @60
                        }
                    completion:^(NSDictionary *r, NSError *e) {
                        NSArray *rows = r[@"list"];
                        if (!e && ![rows isKindOfClass:NSArray.class])
                            e = FNError(@"照片列表格式不兼容。");
                        if (!e) {
                            self.offset += rows.count;
                            self.hasNext =
                                r[@"hasNext"]
                                    ? [r[@"hasNext"] boolValue]
                                    : (r[@"total"] ? self.offset < [r[@"total"] unsignedIntegerValue]
                                                   : rows.count == 60);
                        }
                        if (!e && !self.days)
                            [self ensureTimeline:^(NSError *timelineError) {
                                done(rows, nil);
                            }];
                        else
                            done(rows, e);
                    }];
        return;
    }
    [self ensureTimeline:^(NSError *e) {
        if (e) {
            done(nil, e);
            return;
        }
        [self fill:[NSMutableArray array] index:self.dayIndex offset:self.dayOffset done:done];
    }];
}
- (void)loadSearchPage:(void (^)(NSArray *, NSError *))done {
    if (self.offset >= self.searchIDs.count) {
        self.hasNext = NO;
        done(@[], nil);
        return;
    }
    NSArray *ids = [self.searchIDs
        subarrayWithRange:NSMakeRange(self.offset, MIN(60, self.searchIDs.count - self.offset))];
    [[FNClient shared]
        photoDetails:ids
          completion:^(NSDictionary *r, NSError *e) {
              NSArray *list = r[@"list"];
              if (!e && ![list isKindOfClass:NSArray.class])
                  e = FNError(@"AI 搜索照片详情格式不兼容。");
              if (e) {
                  done(nil, e);
                  return;
              }
              NSMutableDictionary *byID = [NSMutableDictionary dictionary];
              for (id row in list)
                  if ([row isKindOfClass:NSDictionary.class] && [row[@"id"] isKindOfClass:NSNumber.class])
                      byID[row[@"id"]] = row;
              NSMutableArray *ordered = [NSMutableArray array];
              for (NSNumber *photoID in ids)
                  if (byID[photoID])
                      [ordered addObject:byID[photoID]];
              // Deleted/inaccessible IDs may be absent; advance by requested IDs and preserve result order.
              self.offset += ids.count;
              self.hasNext = self.offset < self.searchIDs.count;
              done(ordered, nil);
          }];
}
- (void)ensureTimeline:(void (^)(NSError *))completion {
    if (self.days) {
        completion(nil);
        return;
    }
    [[FNClient shared]
           get:@"/p/api/v1/gallery/timeline"
        params:self.albumID ? @{@"album_id" : self.albumID}
                            : (self.favorites ? @{@"is_collect" : @1} : @{})completion
              :^(NSDictionary *r, NSError *e) {
                  NSArray *list = r[@"list"];
                  if (!e && ![list isKindOfClass:NSArray.class])
                      e = FNError(@"照片时间线格式不兼容。");
                  if (e) {
                      completion(e);
                      return;
                  }
                  NSMutableArray *days = [NSMutableArray array];
                  for (id row in list) {
                      if (![row isKindOfClass:NSDictionary.class] || !row[@"year"] || !row[@"month"] ||
                          !row[@"day"] || !row[@"itemCount"]) {
                          completion(FNError(@"照片时间线日期格式不兼容。"));
                          return;
                      }
                      if ([row[@"itemCount"] integerValue] > 0)
                          [days addObject:row];
                  }
                  self.days =
                      [days sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                          for (NSString *k in @[ @"year", @"month", @"day" ]) {
                              NSComparisonResult c = [b[k] compare:a[k]];
                              if (c != NSOrderedSame)
                                  return c;
                          }
                          return NSOrderedSame;
                      }];
                  completion(nil);
              }];
}
- (FNPhotoPager *)pagerStartingAtDay:(NSUInteger)index {
    FNPhotoPager *p = [FNPhotoPager new];
    p.albumID = self.albumID;
    p.favorites = self.favorites;
    p.days = self.days;
    p.datePaging = YES;
    p.dayIndex = MIN(index, self.days.count);
    p.headDayIndex = p.dayIndex;
    p.hasPrevious = p.headDayIndex > 0;
    p.hasNext = p.dayIndex < self.days.count;
    return p;
}

- (void)previous:(void (^)(NSArray *, NSError *))completion {
    if (self.loading) {
        completion(nil, FNError(@"正在读取照片，请稍候。"));
        return;
    }
    if (!self.hasPrevious) {
        completion(@[], nil);
        return;
    }
    self.loading = YES;
    [self fillPrevious:[NSMutableArray array]
                 index:self.headDayIndex
                offset:self.headOffset
                  done:^(NSArray *rows, NSError *error) {
                      self.loading = NO;
                      completion(rows, error);
                  }];
}
- (void)fillPrevious:(NSMutableArray *)rows
               index:(NSUInteger)index
              offset:(NSUInteger)offset
                done:(void (^)(NSArray *, NSError *))done {
    if (rows.count >= 60 || (index == 0 && offset == 0)) {
        // Commit only once the whole page succeeds. Forward pagination is independent.
        self.headDayIndex = index;
        self.headOffset = offset;
        self.hasPrevious = index > 0 || offset > 0;
        done(rows, nil);
        return;
    }
    if (offset == 0) {
        index--;
        offset = [self.days[index][@"itemCount"] unsignedIntegerValue];
    }
    NSUInteger limit = MIN(60 - rows.count, offset);
    NSUInteger start = offset - limit;
    [self readDay:index
            offset:start
             limit:limit
        completion:^(NSArray *list, NSError *error) {
            if (error) {
                done(nil, error);
                return;
            }
            [rows insertObjects:list
                      atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, list.count)]];
            [self fillPrevious:rows index:index offset:start done:done];
        }];
}

- (void)readDay:(NSUInteger)index
         offset:(NSUInteger)offset
          limit:(NSUInteger)limit
     completion:(void (^)(NSArray *, NSError *))completion {
    NSDictionary *day = self.days[index];
    NSString *date = [NSString stringWithFormat:@"%04ld:%02ld:%02ld", [day[@"year"] longValue],
                                                [day[@"month"] longValue], [day[@"day"] longValue]];
    NSMutableDictionary *params = [@{
        @"start_time" : [date stringByAppendingString:@" 00:00:00"],
        @"end_time" : [date stringByAppendingString:@" 23:59:59"],
        @"mode" : self.favorites ? @"collect" : @"index",
        @"offset" : @(offset),
        @"limit" : @(limit)
    } mutableCopy];
    if (self.favorites)
        params[@"is_collect"] = @1;
    if (self.albumID)
        params[@"album_id"] = self.albumID;
    [[FNClient shared] get:@"/p/api/v1/gallery/getList"
                    params:params
                completion:^(NSDictionary *result, NSError *error) {
                    id list = result[@"list"];
                    if (!error && (![list isKindOfClass:NSArray.class] || [list count] > limit))
                        error = FNError(@"照片分页格式不兼容。");
                    NSMutableArray *tagged = [NSMutableArray array];
                    if (!error)
                        for (id photo in list) {
                            if (![photo isKindOfClass:NSDictionary.class]) {
                                error = FNError(@"照片条目格式不兼容。");
                                break;
                            }
                            NSMutableDictionary *row = [photo mutableCopy];
                            row[@"fn_dayIndex"] = @(index);
                            [tagged addObject:row];
                        }
                    completion(error ? nil : tagged, error);
                }];
}

- (void)fill:(NSMutableArray *)rows
       index:(NSUInteger)index
      offset:(NSUInteger)offset
        done:(void (^)(NSArray *, NSError *))done {
    if (rows.count >= 60 || index >= self.days.count) {
        self.dayIndex = index;
        self.dayOffset = offset;
        self.hasNext = index < self.days.count;
        done(rows, nil);
        return;
    }
    NSDictionary *day = self.days[index];
    NSUInteger count = [day[@"itemCount"] unsignedIntegerValue];
    if (offset >= count) {
        [self fill:rows index:index + 1 offset:0 done:done];
        return;
    }
    NSUInteger limit = MIN(60 - rows.count, count - offset);
    [self readDay:index
            offset:offset
             limit:limit
        completion:^(NSArray *list, NSError *e) {
            if (e) {
                done(nil, e);
                return;
            }
            [rows addObjectsFromArray:list];
            BOOL next = list.count < limit || offset + list.count >= count;
            [self fill:rows index:next ? index + 1 : index offset:next ? 0 : offset + list.count done:done];
        }];
}
@end
