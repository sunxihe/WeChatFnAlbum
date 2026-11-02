#import "FNWeChatBridge.h"
#import "FNBrowser.h"
#import "FNImageDelivery.h"
#import "FNMediaHandoff.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Private calls are restricted to validated selectors. No WeChat private symbols
// are linked into the dylib, allowing clean failure on incompatible releases.
static BOOL FNMethod(Class c, NSString *name, const char *result, NSArray<NSString *> *args) {
    Method m = class_getInstanceMethod(c, NSSelectorFromString(name));
    if (!m || method_getNumberOfArguments(m) != args.count + 2)
        return NO;
    char *r = method_copyReturnType(m);
    BOOL ok = r && strcmp(r, result) == 0;
    free(r);
    for (NSUInteger i = 0; ok && i < args.count; i++) {
        char *t = method_copyArgumentType(m, (unsigned)i + 2);
        ok = t && strcmp(t, args[i].UTF8String) == 0;
        free(t);
    }
    return ok;
}
static id Get(id obj, NSString *name) {
    if (!obj || !FNMethod(object_getClass(obj), name, "@", @[]))
        return nil;
    return ((id(*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(name));
}
static void SetBool(id obj, NSString *name, BOOL value) {
    if (FNMethod(object_getClass(obj), name, "v", @[ @"B" ]))
        ((void (*)(id, SEL, BOOL))objc_msgSend)(obj, NSSelectorFromString(name), value);
}
static void SetObject(id obj, NSString *name, id value) {
    if (FNMethod(object_getClass(obj), name, "v", @[ @"@" ]))
        ((void (*)(id, SEL, id))objc_msgSend)(obj, NSSelectorFromString(name), value);
}
static NSString *Recipient(id imageController) {
    id delegate = Get(imageController, @"m_delegate");
    id contact=Get(delegate,@"GetContact")?:Get(delegate,@"getCurrentContact")?:Get(delegate,@"m_contact");
    id user = Get(contact, @"m_nsUsrName");
    return [user isKindOfClass:NSString.class] ? user : nil;
}
BOOL FNBridgeAvailable(void) {
    return FNMethod(NSClassFromString(@"ImageController"), @"OpenMediaBrowser", "v", @[]) &&
           FNMethod(NSClassFromString(@"ImageController"), @"didSelectMMAsset:finish:fromImagePicker:", "v",
                    @[ @"@", @"B", @"@" ]) &&
           FNMethod(NSClassFromString(@"MMAssetForLocalImage"),
                    @"initWithAssetId:localFilePath:isNeedOrigin:", "@", @[ @"@", @"@", @"B" ]);
}
NSString *FNCompatibilityReport(void) {
    NSString *version =
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"未知";
    return
        [NSString stringWithFormat:@"插件 0.4.3 · 微信 %@\n接口检查：%@\n目标版本：8.0.75 / "
                                   @"8.0.76\n日期快滑与 AI 搜索已加入；具体兼容结果见验证记录。",
                                   version, FNBridgeAvailable() ? @"基础接口存在" : @"不兼容，保持系统相册"];
}

#ifdef FN_DEVICE_TESTS
static NSString *FNBlockType(id block) {
    if (!block)
        return @"nil";
    struct BlockLiteral {
        void *isa;
        int flags;
        int reserved;
        void *invoke;
        void *descriptor;
    };
    const struct BlockLiteral *b = (__bridge const void *)block;
    if (!(b->flags & (1 << 30)))
        return @"unknown";
    const char *descriptor = b->descriptor;
    descriptor += 2 * sizeof(uintptr_t);
    if (b->flags & (1 << 25))
        descriptor += 2 * sizeof(void *);
    const char *signature = *(const char *const *)descriptor;
    return signature ? [NSString stringWithUTF8String:signature] : @"unknown";
}
static void FNTrace(NSString *name, NSDictionary *fields) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSMutableArray *events;
        if (!events)
            events = [NSMutableArray array];
        [events addObject:@{@"event" : name, @"fields" : fields}];
        if (events.count > 100)
            [events removeObjectAtIndex:0];
        [[NSJSONSerialization dataWithJSONObject:events options:NSJSONWritingPrettyPrinted error:nil]
            writeToURL:[FNCacheDirectory() URLByAppendingPathComponent:@"asset-trace.json"]
            atomically:YES];
    });
}
#define FN_TRACE(name, fields) FNTrace(name, fields)
#else
#define FN_TRACE(name, fields)
#endif

static id FNAssetCopy(id obj, SEL selector, NSZone *zone) __attribute__((ns_returns_retained));
static id FNAssetCopy(id obj, SEL selector, NSZone *zone) {
    FN_TRACE(@"assetCopy", (@{@"class":NSStringFromClass([obj class])}));
    return obj;
}
static id FNExif(NSData *data, UIImage *image, BOOL live) {
    Class util = NSClassFromString(@"MMImageUtil");
    SEL selector = NSSelectorFromString(@"exifLogInfoWithImageData:image:originImageSize:");
    id info = nil;
    if (FNMethod(object_getClass(util), NSStringFromSelector(selector), "@", @[ @"@", @"@", @"{CGSize=dd}" ]))
        info = ((id(*)(id, SEL, id, id, CGSize))objc_msgSend)(
            util, selector, data, image,
            CGSizeMake(image.size.width * image.scale, image.size.height * image.scale));
    if (!info)
        info = [NSClassFromString(@"MMImageExifLogInfo") new];
    SetBool(info, @"setIsLivePhoto:", live);
    return info;
}
static void FNReadSource(id asset, void (^success)(NSData *), void (^failure)(NSError *)) {
    FN_TRACE(@"readSource", (@{@"success" : FNBlockType(success), @"error" : FNBlockType(failure)}));
    NSString *path = Get(asset, @"localFilePath");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSData *data =
            path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (data.length) {
                FN_TRACE(@"sourceReady", (@{@"bytes" : @(data.length)}));
                if (success)
                    success(data);
            } else if (failure)
                failure(FNError(@"原始图片缓存无法读取，请重新选择。"));
        });
    });
}
static void FNReadImage(id asset, void (^success)(UIImage *, id), void (^failure)(NSError *)) {
    FNReadSource(
        asset,
        ^(NSData *data) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (image) {
                        FN_TRACE(@"imageReady", (@{
                                     @"imageClass" : NSStringFromClass(image.class),
                                     @"dataClass" : NSStringFromClass(data.class)
                                 }));
                        if (success)
                            success(image, data);
                    } else if (failure)
                        failure(FNError(@"原始图片无法解码。"));
                });
            });
        },
        failure);
}
static void FNProcessImage(id obj, FNImageCallback process, FNImageCallback result,
                           void (^error)(NSError *)) {
    FNImageDelivery *delivery = [[FNImageDelivery alloc] initWithProcess:process result:result];
    void (^failure)(NSError *) = [error copy];
    FNReadImage(
        obj,
        ^(UIImage *image, id data) {
            [delivery deliverImage:image data:data];
        },
        failure);
}
static Class LocalAssetClass(void) {
    static Class result;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"MMAssetForLocalImage");
        if (!base)
            return;
        result = objc_allocateClassPair(base, "ACFNLocalImageAsset", 0);
        if (!result) {
            result = NSClassFromString(@"ACFNLocalImageAsset");
            return;
        }
        class_addMethod(result, @selector(copyWithZone:), (IMP)FNAssetCopy,
                        method_getTypeEncoding(class_getInstanceMethod(base, @selector(copyWithZone:))));
        class_addMethod(result, NSSelectorFromString(@"isGif"), imp_implementationWithBlock(^BOOL(id obj) {
                            return
                                [[Get(obj, @"localFilePath") pathExtension].lowercaseString isEqual:@"gif"];
                        }),
                        "B@:");
        class_addMethod(result, NSSelectorFromString(@"isLivePhoto"),
                        imp_implementationWithBlock(^BOOL(id obj) {
                            return NO;
                        }),
                        "B@:");
        class_addMethod(result, NSSelectorFromString(@"asyncImageOriginSourceData:errorBlock:"),
                        imp_implementationWithBlock(^(id obj, void (^ok)(NSData *), void (^bad)(NSError *)) {
                            FNReadSource(obj, ok, bad);
                        }),
                        "v@:@?@?");
        class_addMethod(result, NSSelectorFromString(@"asyncImageOriginData:completion:errorBlock:"),
                        imp_implementationWithBlock(
                            ^(id obj, BOOL convert, void (^ok)(NSData *), void (^bad)(NSError *)) {
                                FNReadSource(obj, ok, bad);
                            }),
                        "v@:B@?@?");
        class_addMethod(
            result,
            NSSelectorFromString(@"getBigImageWithCompressConfig:ProcessBlock:ResultBlock:ErrorBlock:"),
            imp_implementationWithBlock(^(id obj, id config, FNImageCallback progress,
                                          void (^ok)(UIImage *, id), void (^bad)(NSError *)) {
                FN_TRACE(@"bigImage", (@{@"process" : FNBlockType(progress), @"result" : FNBlockType(ok)}));
                FNProcessImage(obj, progress, ok, bad);
            }),
            "v@:@@?@?@?");
        class_addMethod(result,
                        NSSelectorFromString(@"getDisplayImageWithCompressConfig:ResultBlock:ErrorBlock:"),
                        imp_implementationWithBlock(
                            ^(id obj, id config, void (^ok)(UIImage *, id), void (^bad)(NSError *)) {
                                FN_TRACE(@"display", (@{@"result" : FNBlockType(ok)}));
                                FNReadImage(obj, ok, bad);
                            }),
                        "v@:@@?@?");
        class_addMethod(
            result,
            NSSelectorFromString(@"getHighResolutionImageWithCompressConfig:ProcessBlock:ResultBlock:"
                                 @"ErrorBlock:FaceCountBlock:"),
            imp_implementationWithBlock(^(id obj, id config, FNImageCallback progress,
                                          void (^ok)(UIImage *, id), void (^bad)(NSError *), id face) {
                FN_TRACE(@"highResolution", (@{
                             @"process" : FNBlockType(progress),
                             @"result" : FNBlockType(ok),
                             @"face" : FNBlockType(face)
                         }));
                FNProcessImage(obj, progress, ok, bad);
            }),
            "v@:@@?@?@?@?");
        class_addMethod(result, NSSelectorFromString(@"asyncGetImageExifLogInfo:"),
                        imp_implementationWithBlock(^(id obj, void (^ok)(id)) {
                            FNReadImage(
                                obj,
                                ^(UIImage *im, id data) {
                                    if (ok)
                                        ok(FNExif(data, im,
                                                  ((BOOL(*)(id, SEL))objc_msgSend)(
                                                      obj, NSSelectorFromString(@"isLivePhoto"))));
                                },
                                ^(NSError *e) {
                                    if (ok)
                                        ok(nil);
                                });
                        }),
                        "v@:@?");
        class_addMethod(result, NSSelectorFromString(@"asyncGetIsSpatial:"),
                        imp_implementationWithBlock(^(id obj, void (^ok)(BOOL)) {
                            if (ok)
                                ok(NO);
                        }),
                        "v@:@?");
        class_addMethod(result, NSSelectorFromString(@"uniformTypeIdentifier"),
                        imp_implementationWithBlock(^id(id obj) {
                            CGImageSourceRef source = CGImageSourceCreateWithURL(
                                (__bridge CFURLRef)[NSURL fileURLWithPath:Get(obj, @"localFilePath")], NULL);
                            NSString *type = source ? [(__bridge NSString *)CGImageSourceGetType(source) copy]
                                                    : @"public.image";
                            if (source)
                                CFRelease(source);
                            return type;
                        }),
                        "@@:");
        objc_registerClassPair(result);
    });
    return result;
}

static const void *VideoKey = &VideoKey;
static Class LiveAssetClass(void) {
    static Class result;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = LocalAssetClass();
        if (!base)
            return;
        result = objc_allocateClassPair(base, "ACFNLocalLiveAsset", 0);
        if (!result) {
            result = NSClassFromString(@"ACFNLocalLiveAsset");
            return;
        }
        class_addMethod(result, NSSelectorFromString(@"isLivePhoto"),
                        imp_implementationWithBlock(^BOOL(id obj) {
                            return YES;
                        }),
                        "B@:");
        class_addMethod(result, NSSelectorFromString(@"canUseLivePhoto"),
                        imp_implementationWithBlock(^BOOL(id obj) {
                            return YES;
                        }),
                        "B@:");
        // Cache the original movie path instead of requesting a PHAsset/iCloud resource.
        class_addMethod(
            result, NSSelectorFromString(@"asyncGetLivePhotoVideoWithSuccess:errorBlock:"),
            imp_implementationWithBlock(^(id obj, void (^success)(id), void (^failure)(NSError *)) {
                NSURL *url = objc_getAssociatedObject(obj, VideoKey);
                if (url && [NSFileManager.defaultManager fileExistsAtPath:url.path]) {
                    if (success)
                        success(url);
                } else if (failure)
                    failure(FNError(@"实况视频缓存已丢失，请重新选择。"));
            }),
            "v@:@@");
        class_addMethod(
            result, NSSelectorFromString(@"getDisplayLivePhotoWithResultBlock:errorBlock:"),
            imp_implementationWithBlock(
                ^(id obj, void (^success)(PHLivePhoto *), void (^failure)(NSError *)) {
                    NSURL *video = objc_getAssociatedObject(obj, VideoKey);
                    NSString *path = Get(obj, @"localFilePath");
                    if (!video || !path) {
                        if (failure)
                            failure(FNError(@"实况资源不完整。"));
                        return;
                    }
                    [PHLivePhoto
                        requestLivePhotoWithResourceFileURLs:@[ [NSURL fileURLWithPath:path], video ]
                                            placeholderImage:nil
                                                  targetSize:CGSizeZero
                                                 contentMode:PHImageContentModeAspectFit
                                               resultHandler:^(PHLivePhoto *photo, NSDictionary *info) {
                                                   if ([info[PHLivePhotoInfoIsDegradedKey] boolValue])
                                                       return;
                                                   if (photo && success)
                                                       success(photo);
                                                   else if (!photo && failure)
                                                       failure(FNError(@"实况配对信息无效，无法构造实况。"));
                                               }];
                }),
            "v@:@@");
        // Local assets are immutable for this picker; copying must retain the live pair.

        objc_registerClassPair(result);
    });
    return result;
}
#ifdef FN_DEVICE_TESTS
static void FNTraceVideoMethods(Class cls, Class base) {
    for (NSString *name in @[@"getVideoUrl", @"getThumbnail", @"videoDuration", @"uniformTypeIdentifier",
                             @"getEditVideoAttr", @"assetUrl", @"assetFileName"]) {
        if (!FNMethod(base, name, "@", @[])) continue;
        SEL sel = NSSelectorFromString(name);
        IMP original = class_getMethodImplementation(base, sel);
        class_addMethod(cls, sel, imp_implementationWithBlock(^id(id obj) {
            id value = ((id(*)(id,SEL))original)(obj, sel);
            FN_TRACE(name, (@{@"class":value ? NSStringFromClass([value class]) : @"nil"}));
            return value;
        }), method_getTypeEncoding(class_getInstanceMethod(base, sel)));
    }
    for (NSString *name in @[@"asyncGetVideoFileSizeWithBlock:", @"asyncGetIsSpatial:", @"asyncGetMetadata:",
                             @"asyncGetThumbnail:", @"asyncGetImageExifLogInfo:",
                             @"getVideoDurationForDisplayWithCompletion:", @"asyncGetVideoAssetWithBlock:"]) {
        if (!FNMethod(base, name, "v", @[@"@?"])) continue;
        SEL sel = NSSelectorFromString(name);
        IMP original = class_getMethodImplementation(base, sel);
        class_addMethod(cls, sel, imp_implementationWithBlock(^(id obj, id callback) {
            FN_TRACE(name, (@{@"callback":FNBlockType(callback)}));
            ((void(*)(id,SEL,id))original)(obj, sel, callback);
        }), method_getTypeEncoding(class_getInstanceMethod(base, sel)));
    }
    for (NSString *name in @[@"asyncGetVideoAsset:successBlock:errorBlock:", @"_asyncGetVideoAsset:successBlock:errorBlock:"]) {
        if (!FNMethod(base, name, "v", @[@"B", @"@?", @"@?"])) continue;
        SEL sel = NSSelectorFromString(name);
        IMP original = class_getMethodImplementation(base, sel);
        class_addMethod(cls, sel, imp_implementationWithBlock(^(id obj, BOOL origin, id ok, id bad) {
            FN_TRACE(name, (@{@"origin":@(origin), @"success":FNBlockType(ok), @"error":FNBlockType(bad)}));
            ((void(*)(id,SEL,BOOL,id,id))original)(obj, sel, origin, ok, bad);
        }), method_getTypeEncoding(class_getInstanceMethod(base, sel)));
    }
    NSString *big = @"getBigImageWithCompressConfig:ProcessBlock:ResultBlock:ErrorBlock:";
    if (FNMethod(base, big, "v", @[@"@", @"@?", @"@?", @"@?"])) {
        SEL sel = NSSelectorFromString(big);
        IMP original = class_getMethodImplementation(base, sel);
        class_addMethod(cls, sel, imp_implementationWithBlock(^(id obj, id config, id process, id ok, id bad) {
            FN_TRACE(big, (@{@"process":FNBlockType(process), @"success":FNBlockType(ok), @"error":FNBlockType(bad)}));
            ((void(*)(id,SEL,id,id,id,id))original)(obj, sel, config, process, ok, bad);
        }), method_getTypeEncoding(class_getInstanceMethod(base, sel)));
    }
}
#endif
static Class LocalVideoAssetClass(void) {
    Class base = NSClassFromString(@"MMAssetForLocalVideo");
    if (!base)
        return Nil;
    static Class result;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        result = objc_allocateClassPair(base, "ACFNLocalVideoAsset", 0);
        if (!result) {
            result = NSClassFromString(@"ACFNLocalVideoAsset");
            return;
        }
        // MMAsset's inherited copy loses the subclass's local path on the device.
        // This picker owns immutable, per-send cached assets, just like its image adapter.
        class_addMethod(result, @selector(copyWithZone:), (IMP)FNAssetCopy,
                        method_getTypeEncoding(class_getInstanceMethod(base, @selector(copyWithZone:))));
        class_addMethod(result, NSSelectorFromString(@"asyncGetVideoFileSizeWithBlock:"),
                        imp_implementationWithBlock(^(id obj, void (^completion)(NSNumber *)) {
                            NSNumber *size = [NSFileManager.defaultManager
                                attributesOfItemAtPath:Get(obj, @"localFilePath") error:nil][NSFileSize];
                            if (completion) completion(size);
                        }), "v@:@?");
#ifdef FN_DEVICE_TESTS
        FNTraceVideoMethods(result, base);
#endif
        objc_registerClassPair(result);
    });
    return result;
}
static id MakeAsset(NSDictionary *photo, NSURL *image, NSURL *video, BOOL original, NSError **error) {
    if (FNIsVideo(photo)) {
        Class cls = LocalVideoAssetClass();
        if (!FNMethod(cls, @"initWithAssetId:localFilePath:isNeedOrigin:", "@", @[ @"@", @"@", @"B" ]) ||
            !FNMethod(cls, @"isVideo", "B", @[]) || !FNMethod(cls, @"getVideoUrl", "@", @[]) ||
            !FNMethod(cls, @"setAvAsset:", "v", @[ @"@" ]) ||
            !FNMethod(cls, @"asyncGetVideoAsset:successBlock:errorBlock:", "v", @[ @"B", @"@?", @"@?" ])) {
            *error = FNError(@"当前微信不支持本地视频素材接口，已停止视频发送。");
            return nil;
        }
        AVURLAsset *movie = [AVURLAsset URLAssetWithURL:image options:nil];
        NSTimeInterval duration = CMTimeGetSeconds(movie.duration);
        NSNumber *size = nil;
        [image getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (!movie.playable || !isfinite(duration) || duration <= 0 ||
            ![movie tracksWithMediaType:AVMediaTypeVideo].count || !size.unsignedLongLongValue) {
            NSError *readError = nil;
            [movie statusOfValueForKey:@"playable" error:&readError];
            *error = readError ? FNError([NSString stringWithFormat:@"视频读取失败：%@", readError.localizedDescription])
                               : FNError(@"视频内容或编码无法在当前 iOS 读取，需要兼容的编码或 NAS 转码。");
            return nil;
        }
        id asset = ((id(*)(id, SEL, id, id, BOOL))objc_msgSend)(
            [cls alloc], NSSelectorFromString(@"initWithAssetId:localFilePath:isNeedOrigin:"),
            [NSString stringWithFormat:@"fn-video:%@:%@", photo[@"id"], NSUUID.UUID.UUIDString], image.path,
            original);
        if (!asset) {
            *error = FNError(@"微信无法创建本地视频素材。");
            return nil;
        }
        SetObject(asset, @"setAvAsset:", movie);
        FN_TRACE(@"videoPrepared", (@{@"bytes":size, @"duration":@(duration)}));
        if (FNMethod(cls, @"setOriginVideoSize:", "v", @[ @"Q" ]) ||
            FNMethod(cls, @"setOriginVideoSize:", "v", @[ @"q" ]))
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(
                asset, NSSelectorFromString(@"setOriginVideoSize:"), size.unsignedLongLongValue);
        return asset;
    }
    BOOL live = [photo[@"isLive"] boolValue];
    Class cls = live ? LiveAssetClass() : LocalAssetClass();
    if (!cls) {
        *error = FNError(@"微信本地素材接口不可用。");
        return nil;
    }
    id allocated = [cls alloc];
    id asset = ((id(*)(id, SEL, id, id, BOOL))objc_msgSend)(
        allocated, NSSelectorFromString(@"initWithAssetId:localFilePath:isNeedOrigin:"),
        [NSString stringWithFormat:@"fn:%@:%@", photo[@"id"], NSUUID.UUID.UUIDString], image.path, original);
    if (!asset) {
        *error = FNError(@"无法创建微信图片素材。");
        return nil;
    }
    SetBool(asset, @"setM_isNeedOriginImage:", original);
    SetBool(asset, @"setM_isSupportHeif:", YES);
    if (live) {
        if (!video || !FNMethod(cls, @"setLivePhotoDuration:", "v", @[ @"d" ]) ||
            !(FNMethod(cls, @"setLivePhotoVideoSize:", "v", @[ @"q" ]) ||
              FNMethod(cls, @"setLivePhotoVideoSize:", "v", @[ @"Q" ])) ||
            !FNMethod(cls, @"setM_livePhotoVideoPath:", "v", @[ @"@" ]) ||
            !FNMethod(cls, @"setM_isUseLivePhoto:", "v", @[ @"B" ])) {
            *error = FNError(@"当前微信缺少实况素材接口，已停止发送。");
            return nil;
        }
        AVURLAsset *movie = [AVURLAsset URLAssetWithURL:video options:nil];
        NSTimeInterval duration = CMTimeGetSeconds(movie.duration);
        NSNumber *size = nil;
        [video getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (!isfinite(duration) || duration <= 0 || ![movie tracksWithMediaType:AVMediaTypeVideo].count ||
            !size.unsignedLongLongValue) {
            *error = FNError(@"NAS 返回的实况视频无法读取，已停止发送。");
            return nil;
        }
        objc_setAssociatedObject(asset, VideoKey, video, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SetObject(asset, @"setM_livePhotoVideoPath:", video.path);
        SetBool(asset, @"setM_isUseLivePhoto:", YES);
        ((void (*)(id, SEL, double))objc_msgSend)(asset, NSSelectorFromString(@"setLivePhotoDuration:"),
                                                  duration);
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(
            asset, NSSelectorFromString(@"setLivePhotoVideoSize:"), size.unsignedLongLongValue);
    }
    return asset;
}
static BOOL FNVideoInfoAvailable(id delegate, BOOL original) {
    Class cls = NSClassFromString(@"CaptureVideoInfo");
    if (!FNMethod(object_getClass(delegate), @"CameraControllerDidTakeVideo:", "v", @[@"@"])) return NO;
    for (NSString *name in @[@"setVideo_path:", @"setThumb_path:"])
        if (!FNMethod(cls, name, "v", @[@"@"])) return NO;
    for (NSString *name in @[@"setVideo_time:", @"setVideo_size:", @"setThumb_size:",
                             @"setVideo_width:", @"setVideo_height:", @"setThumb_width:", @"setThumb_height:"])
        if (!FNMethod(cls, name, "v", @[@"I"])) return NO;
    return !original || (FNMethod(cls, @"setBRawVideo:", "v", @[@"B"]) &&
                         FNMethod(cls, @"setNsRawVidePath:", "v", @[@"@"]) &&
                         FNMethod(cls, @"setRawFileLength:", "v", @[@"Q"]) &&
                         FNMethod(cls, @"setAsset:", "v", @[@"@"])) ;
}
static id FNMakeVideoInfo(NSURL *source, NSURL *movieURL, NSURL *thumbURL, UIImage *thumb,
                         id asset, BOOL original, NSError **error) {
    AVURLAsset *movie = [AVURLAsset URLAssetWithURL:movieURL options:nil];
    AVAssetTrack *track = [movie tracksWithMediaType:AVMediaTypeVideo].firstObject;
    double duration = CMTimeGetSeconds(movie.duration);
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:movieURL.path error:nil];
    unsigned long long bytes = [attrs[NSFileSize] unsignedLongLongValue];
    NSData *jpeg = thumb ? UIImageJPEGRepresentation(thumb, .85) : nil;
    if (!movie.playable || !track || !isfinite(duration) || duration <= 0 ||
        !bytes || bytes > UINT32_MAX || !jpeg.length ||
        ![jpeg writeToURL:thumbURL options:NSDataWritingAtomic error:error]) {
        if (!*error) *error = FNError(@"视频或封面准备失败，尚未提交发送。");
        return nil;
    }
    CGSize size = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
    id info = [NSClassFromString(@"CaptureVideoInfo") new];
    SetObject(info, @"setVideo_path:", movieURL.path);
    SetObject(info, @"setThumb_path:", thumbURL.path);
    NSDictionary *values = @{@"setVideo_time:":@(ceil(duration)), @"setVideo_size:":@(bytes),
        @"setThumb_size:":@(jpeg.length), @"setVideo_width:":@(fabs(size.width)),
        @"setVideo_height:":@(fabs(size.height)), @"setThumb_width:":@(thumb.size.width * thumb.scale),
        @"setThumb_height:":@(thumb.size.height * thumb.scale)};
    for (NSString *name in values)
        ((void(*)(id,SEL,unsigned int))objc_msgSend)(info, NSSelectorFromString(name), [values[name] unsignedIntValue]);
    if (original) {
        NSNumber *rawSize = [NSFileManager.defaultManager attributesOfItemAtPath:source.path error:nil][NSFileSize];
        SetBool(info, @"setBRawVideo:", YES);
        SetObject(info, @"setNsRawVidePath:", source.path);
        SetObject(info, @"setAsset:", asset);
        ((void(*)(id,SEL,unsigned long long))objc_msgSend)(info, NSSelectorFromString(@"setRawFileLength:"),
                                                        rawSize.unsignedLongLongValue);
    }
    return info;
}
@interface FNSendContext : NSObject
@property(nonatomic) id imageController;
@property(nonatomic, weak) id originalDelegate;
@property(nonatomic, weak) UIViewController *chat;
@property(nonatomic) NSString *recipient;
@property(nonatomic, weak) FNNavigationController *navigation;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL submitted;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) NSMutableArray *assets;
@property(nonatomic) NSMutableArray<FNTransfer *> *tasks;
@property(nonatomic) NSArray<NSDictionary *> *selected;
@property(nonatomic) BOOL original;
@property(nonatomic) NSURL *directory;
@property(nonatomic) UIAlertController *progress;
@property(nonatomic) NSString *nasIdentity;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger nasGeneration;
@property(nonatomic) AVAssetExportSession *videoExport;
@property(nonatomic) AVAssetImageGenerator *videoCover;
@end
@implementation FNSendContext
- (BOOL)valid {
    UIViewController *chat = self.chat;
    NSDictionary *checks = @{
        @"chatExists" : @(chat != nil),
        @"pickerPresented" : @(self.navigation.presentingViewController != nil),
        @"pickerInWindow" : @(self.navigation.viewIfLoaded.window != nil),
        @"delegateMatches" : @(Get(self.imageController, @"m_delegate") == self.originalDelegate),
        @"recipientMatches" : @([Recipient(self.imageController) isEqual:self.recipient]),
        @"controllerMatches" : @(Get(self.imageController, @"getViewController") == chat),
        @"navigationMatches" :
            @(!chat.navigationController || chat.navigationController.topViewController == chat),
        @"generationMatches" : @([FNClient shared].generation == self.nasGeneration)
    };
    [[NSJSONSerialization dataWithJSONObject:checks options:NSJSONWritingPrettyPrinted error:nil]
        writeToURL:[FNCacheDirectory() URLByAppendingPathComponent:@"send-checks.json"]
        atomically:YES];
    return [FNClient shared].generation == self.nasGeneration && !self.cancelled && !self.submitted &&
           self.navigation.presentingViewController && self.navigation.viewIfLoaded.window &&
           Get(self.imageController, @"m_delegate") == self.originalDelegate &&
           [Recipient(self.imageController) isEqual:self.recipient] &&
           Get(self.imageController, @"getViewController") == chat &&
           (!chat.navigationController || chat.navigationController.topViewController == chat) &&
           [[NSString stringWithFormat:@"%@|%@", [FNClient shared].baseURL.absoluteString,
                                       [FNClient shared].username] isEqual:self.nasIdentity];
}
- (void)fail:(NSError *)error {
    if (!self.busy)
        return;
    self.busy = NO;
    self.generation++;
    [self.videoExport cancelExport];
    self.videoExport = nil;
    [self.videoCover cancelAllCGImageGeneration];
    self.videoCover = nil;
    for (FNTransfer *t in self.tasks)
        [t cancel];
    [self.tasks removeAllObjects];
    self.navigation.modalInPresentation = NO;
    [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil];
    [self.assets removeAllObjects];
    BOOL cancelled = self.cancelled;
    UIAlertController *progress = self.progress;
    self.progress = nil;
    [progress
        dismissViewControllerAnimated:YES
                           completion:^{
                               if (!cancelled)
                                   FNAlert(self.navigation.topViewController, error.localizedDescription);
                           }];
}
- (void)sendFrom:(UIViewController *)vc photos:(NSArray *)photos original:(BOOL)original {
    if (self.busy || self.submitted || !photos.count)
        return;
    self.nasGeneration = [FNClient shared].generation;
    self.nasIdentity = [NSString
        stringWithFormat:@"%@|%@", [FNClient shared].baseURL.absoluteString, [FNClient shared].username];
    if (![self valid]) {
        FNAlert(vc, @"原聊天会话已改变，请返回聊天重新选择。");
        return;
    }
    self.selected = [photos copy];
    self.original = original;
    self.assets = [NSMutableArray array];
    self.tasks = [NSMutableArray array];
    self.directory = [FNCacheDirectory() URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    self.busy = YES;
    self.cancelled = NO;
    self.generation++;
    self.navigation.modalInPresentation = YES;
    self.progress = [UIAlertController alertControllerWithTitle:@"正在准备发送"
                                                        message:@"正在从 NAS 下载原始素材…"
                                                 preferredStyle:UIAlertControllerStyleAlert];
    [self.progress addAction:[UIAlertAction actionWithTitle:@"取消"
                                                      style:UIAlertActionStyleCancel
                                                    handler:^(UIAlertAction *a) {
                                                        self.cancelled = YES;
                                                        [self fail:FNError(@"已取消发送。")];
                                                        self.cancelled = NO;
                                                    }]];
    [vc presentViewController:self.progress
                     animated:YES
                   completion:^{
                       [self prepare:0];
                   }];
}
- (void)prepare:(NSUInteger)index {
    if (!self.busy)
        return;
    if (![self valid]) {
        [self fail:FNError(@"聊天会话或 NAS 账号已改变，已停止发送。")];
        return;
    }
    if (index == self.selected.count) {
        [self submit];
        return;
    }
    NSUInteger generation = self.generation;
    NSDictionary *p = self.selected[index];
    NSString *url = FNMediaURL(p, YES);
    if (!url.length) {
        [self fail:FNError(@"NAS 未返回原图地址，已停止发送。")];
        return;
    }
    NSString *ext =
        [p[@"fileName"] isKindOfClass:NSString.class] ? [p[@"fileName"] pathExtension].lowercaseString : @"";
    if (!FNIsSupportedMedia(p)) {
        [self fail:FNError(@"所选素材不是支持的图片格式。")];
        return;
    }
    NSURL *image = [self.directory
        URLByAppendingPathComponent:[NSString stringWithFormat:@"%lu.%@", (unsigned long)index, ext]];
    self.progress.message = [NSString
        stringWithFormat:@"正在下载第 %lu / %lu 项素材%@", (unsigned long)index + 1,
                         (unsigned long)self.selected.count, [p[@"isLive"] boolValue] ? @"及实况视频" : @""];
    FNTransfer *t = [[FNClient shared]
          download:url
                to:image
        completion:^(NSError *e) {
            if (!self.busy || generation != self.generation)
                return;
            if (e) {
                [self fail:e];
                return;
            }
            if (FNIsVideo(p)) {
                [self prepareVideo:p source:image index:index];
                return;
            }
            CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)image, NULL);
            BOOL readable = source && CGImageSourceGetCount(source) > 0;
            if (source)
                CFRelease(source);
            if (!readable) {
                [self fail:FNError(@"NAS 返回的文件不是有效图片，已停止发送。")];
                return;
            }
            if ([p[@"isLive"] boolValue]) {
                NSString *video = p[@"additional"][@"thumbnail"][@"videoUrl"];
                if (![video isKindOfClass:NSString.class] || !video.length) {
                    [self fail:FNError(@"NAS 没有返回实况视频地址，无法保留实况发送。")];
                    return;
                }
                NSURL *movie = [self.directory
                    URLByAppendingPathComponent:[NSString stringWithFormat:@"%lu.mov", (unsigned long)index]];
                FNTransfer *vt = [[FNClient shared] download:video
                                                                to:movie
                                                        completion:^(NSError *err) {
                                                            if (!self.busy || generation != self.generation)
                                                                return;
                                                            if (err) {
                                                                [self fail:err];
                                                                return;
                                                            }
                                                            [self addPhoto:p
                                                                     image:image
                                                                     video:movie
                                                                     index:index];
                                                        }];
                if (vt)
                    [self.tasks addObject:vt];
            } else
                [self addPhoto:p image:image video:nil index:index];
        }];
    if (t)
        [self.tasks addObject:t];
}
- (void)prepareVideo:(NSDictionary *)photo source:(NSURL *)source index:(NSUInteger)index {
    if (!FNVideoInfoAvailable(self.originalDelegate, self.original)) {
        [self fail:FNError(@"当前微信缺少视频消息接口，尚未提交发送。")];
        return;
    }
    NSError *error = nil;
    id localAsset = MakeAsset(photo, source, nil, self.original, &error);
    if (!localAsset) { [self fail:error]; return; }
    NSUInteger generation = self.generation;
    AVURLAsset *movie = [AVURLAsset URLAssetWithURL:source options:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:movie
                                                                presetName:AVAssetExportPreset1920x1080];
    if (!export || ![export.supportedFileTypes containsObject:AVFileTypeMPEG4]) {
        [self fail:FNError(@"此视频无法转换为微信兼容的 MP4，尚未提交发送。")];
        return;
    }
    NSURL *output = [self.directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%lu-send.mp4", (unsigned long)index]];
    NSURL *thumbURL = [self.directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%lu-cover.jpg", (unsigned long)index]];
    export.outputURL = output;
    export.outputFileType = AVFileTypeMPEG4;
    export.shouldOptimizeForNetworkUse = YES;
    self.videoExport = export;
    self.progress.message = [NSString stringWithFormat:@"正在处理第 %lu / %lu 项视频…",
        (unsigned long)index + 1, (unsigned long)self.selected.count];
    [export exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.busy || generation != self.generation) {
                [NSFileManager.defaultManager removeItemAtURL:output error:nil];
                return;
            }
            self.videoExport = nil;
            if (export.status != AVAssetExportSessionStatusCompleted) {
                [self fail:export.error ?: FNError(@"视频转换失败，尚未提交发送。")];
                return;
            }
            NSError *fileError = nil;
            if (![NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0644}
                                               ofItemAtPath:output.path error:&fileError]) {
                [self fail:fileError]; return;
            }
            AVAssetImageGenerator *cover = [[AVAssetImageGenerator alloc]
                initWithAsset:[AVURLAsset URLAssetWithURL:output options:nil]];
            cover.appliesPreferredTrackTransform = YES;
            cover.maximumSize = CGSizeMake(1280,1280);
            self.videoCover = cover;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
                NSError *coverError = nil;
                CGImageRef cg = [cover copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&coverError];
                UIImage *image = cg ? [UIImage imageWithCGImage:cg] : nil;
                if (cg) CGImageRelease(cg);
                id info = image ? FNMakeVideoInfo(source, output, thumbURL, image, localAsset,
                                                  self.original, &coverError) : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!self.busy || generation != self.generation) {
                        [NSFileManager.defaultManager removeItemAtURL:output error:nil];
                        [NSFileManager.defaultManager removeItemAtURL:thumbURL error:nil];
                        return;
                    }
                    self.videoCover = nil;
                    if (!info) { [self fail:coverError ?: FNError(@"视频封面无法生成。")]; return; }
                    [self.assets addObject:info];
                    FN_TRACE(@"videoMessagePrepared", (@{@"class":NSStringFromClass([info class])}));
                    [self prepare:index+1];
                });
            });
        });
    }];
}
- (void)addPhoto:(NSDictionary *)p image:(NSURL *)image video:(NSURL *)video index:(NSUInteger)index {
    NSError *e = nil;
    id asset = MakeAsset(p, image, video, self.original, &e);
    if (!asset) {
        [self fail:e];
        return;
    }
    [self.assets addObject:asset];
    [self prepare:index + 1];
}
- (void)submit {
    if (![self valid]) {
        [self fail:FNError(@"聊天会话已改变，已停止发送。")];
        return;
    }
    id delegate = Get(self.imageController, @"m_delegate");
    if (!FNMethod(object_getClass(delegate), @"processInsertedAsset:", "v", @[ @"@" ])) {
        [self fail:FNError(@"当前聊天没有素材发送接口，已停止发送。")];
        return;
    }
    if (![@{@"submittedAt" : @([NSDate date].timeIntervalSince1970), @"count" : @(self.assets.count)}
            writeToURL:[self.directory URLByAppendingPathComponent:@"handoff.plist"]
            atomically:YES]) {
        [self fail:FNError(@"无法保护待发送缓存，已停止发送。")];
        return;
    }
    self.submitted = YES;
    self.busy = NO;
    self.navigation.modalInPresentation = NO;
    NSArray *assets = [self.assets copy];
    id imageController = self.imageController;
    FNNavigationController *nav = self.navigation;
    // Handoff is irreversible; never offer an automatic retry once invoked.
    [self.progress
        dismissViewControllerAnimated:NO
                           completion:^{
                               @try {
                                   NSError *handoffError = nil;
                                   if (!FNMediaHandoff(assets, imageController, delegate, nav, &handoffError))
                                       FNAlert(nav.topViewController, handoffError.localizedDescription);
                               } @catch (NSException *exception) {
                                   FNAlert(nav.topViewController, @"微信素材接口异常。部分素材可能已提交，请"
                                                                  @"先检查聊天记录，勿直接重发。");
                               }
                           }];
    self.progress = nil;
    // Do not remove sent resources on a timer: WeChat may upload after this page closes.
    // Submitted directories survive process launches until explicit user cleanup.
    self.navigation = nil;
}
@end

BOOL FNOfferAlbum(id imageController, dispatch_block_t original) {
    UIViewController *vc = Get(imageController, @"getViewController");
    id delegate = Get(imageController, @"m_delegate");
    NSString *recipient = Recipient(imageController);
    if (!FNBridgeAvailable() || ![vc isKindOfClass:NSClassFromString(@"BaseMsgContentViewController")] ||
        !vc.viewIfLoaded.window || vc.presentedViewController || !recipient.length ||
        !FNMethod(object_getClass(delegate), @"processInsertedAsset:", "v", @[ @"@" ]))
        return NO;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择相册"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"系统相册"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
                                                if (Get(imageController, @"getViewController") == vc &&
                                                    [Recipient(imageController) isEqual:recipient])
                                                    original();
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"飞牛相册"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
                                                FNSendContext *context = [FNSendContext new];
                                                context.imageController = imageController;
                                                context.originalDelegate = delegate;
                                                context.chat = vc;
                                                context.recipient = recipient;
                                                FNBrowserController *browser = [FNBrowserController new];
                                                browser.selection = [FNSelection new];
                                                // Retain context in the browser, not the chat. NAS work
                                                // cannot outlive this flow.
                                                browser.sendSelection =
                                                    ^(UIViewController *sender, NSArray *photos, BOOL orig) {
                                                        [context sendFrom:sender photos:photos original:orig];
                                                    };
                                                FNNavigationController *nav = [[FNNavigationController alloc]
                                                    initWithRootViewController:browser];
                                                nav.modalPresentationStyle = UIModalPresentationFullScreen;
                                                context.navigation = nav;
                                                [vc presentViewController:nav animated:YES completion:nil];
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = alert.popoverPresentationController;
    if (pop) {
        pop.sourceView = vc.view;
        pop.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds), vc.view.bounds.size.height - 90, 1, 1);
        pop.permittedArrowDirections = UIPopoverArrowDirectionDown;
    }
    [vc presentViewController:alert animated:YES completion:nil];
    return YES;
}
#ifdef FN_DEVICE_TESTS
#include "../tests/DeviceAssetTests.inc"
#endif
#ifdef FN_VIDEO_PROBE
#include "../tests/VideoPreviewProbe.inc"
#endif
void FNPrepareCache(void) {
#ifdef FN_VIDEO_PROBE
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ FNRunVideoPreviewProbe(); });
#endif
    LocalAssetClass();
    LiveAssetClass();
    LocalVideoAssetClass();
#ifdef FN_DEVICE_TESTS
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        FNRunDeviceAssetTests();
    });
#endif
    // Only orphaned previews/downloads are swept. Submitted uploads require explicit cleanup.
    NSURL *dir = FNCacheDirectory();
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-7 * 24 * 3600];
    for (NSURL *item in
         [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir
                                     includingPropertiesForKeys:@[ NSURLContentModificationDateKey ]
                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                          error:nil]) {
        NSDate *modified = nil;
        [item getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        if (![NSFileManager.defaultManager
                fileExistsAtPath:[[item URLByAppendingPathComponent:@"handoff.plist"] path]] &&
            modified && [modified compare:cutoff] == NSOrderedAscending)
            [NSFileManager.defaultManager removeItemAtURL:item error:nil];
    }
    NSMutableDictionary *classes = [NSMutableDictionary dictionary];
    for (NSString *name in @[
             @"ImageController", @"MMAsset", @"MMAssetForLocalImage", @"MMAssetForPHAssetFramework",
             @"BaseMsgContentLogicController", @"BaseMsgContentViewController", @"MMAssetForLocalVideo"
         ]) {
        Class cls = NSClassFromString(name);
        NSMutableDictionary *methods = [NSMutableDictionary dictionary];
        unsigned int count = 0;
        Method *list = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *selector = NSStringFromSelector(method_getName(list[i]));
            methods[selector] = [NSString stringWithUTF8String:method_getTypeEncoding(list[i])];
        }
        free(list);
        classes[name] = methods;
    }
    NSDictionary *diagnostic = @{
        @"version" : [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
        @"bridgeAvailable" : @(FNBridgeAvailable()),
        @"classes" : classes
    };
    [[NSJSONSerialization dataWithJSONObject:diagnostic options:NSJSONWritingPrettyPrinted
                                       error:nil] writeToURL:[dir URLByAppendingPathComponent:@"runtime.json"]
                                                  atomically:YES];
    // Resolve beside the dylib, supporting both /var/jb and IPA Frameworks.
    Dl_info info;
    if (dladdr((const void *)&FNPrepareCache, &info) && info.dli_fname) {
        NSString *path = [NSString stringWithUTF8String:info.dli_fname];
        NSBundle *b = [NSBundle bundleWithPath:[[path stringByDeletingLastPathComponent]
                                                   stringByAppendingPathComponent:@"WeChatFnAlbum.bundle"]];
        (void)b;
    }
}
