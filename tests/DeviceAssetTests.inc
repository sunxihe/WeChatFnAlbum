// Included only with FN_DEVICE_TESTS=1. No message APIs are invoked.
static void FNRunDeviceAssetTests(void) {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    @try {
        NSURL *dir = [FNCacheDirectory() URLByAppendingPathComponent:@"asset-selftest" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:dir
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(64, 64), YES, 1);
        [UIColor.systemGreenColor setFill];
        UIRectFill(CGRectMake(0, 0, 64, 64));
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        NSURL *file = [dir URLByAppendingPathComponent:@"test.png"];
        [UIImagePNGRepresentation(image) writeToURL:file atomically:YES];
        NSError *error = nil;
        id asset = MakeAsset(@{@"id" : @1, @"fileName" : @"test.png"}, file, nil, YES, &error);
        r[@"pngCreated"] = @(asset != nil);
        r[@"localFilePathMatches"] = @([Get(asset, @"localFilePath") isEqual:file.path]);
        if (asset) {
            r[@"isPicture"] = @(((BOOL(*)(id, SEL))objc_msgSend)(asset, NSSelectorFromString(@"isPicture")));
            r[@"thumbnailCreated"] = @(Get(asset, @"getThumbnail") != nil);
        }
        NSURL *videoFile = [dir URLByAppendingPathComponent:@"test.mp4"];
        NSURL *probeFile = [dir URLByAppendingPathComponent:@"probe.mov"];
        if ([NSFileManager.defaultManager fileExistsAtPath:probeFile.path]) {
            [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600}
                                          ofItemAtPath:probeFile.path error:nil];
            AVURLAsset *restricted = [AVURLAsset URLAssetWithURL:probeFile options:nil];
            r[@"probeMode0600Playable"] = @(restricted.playable);
            [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0644}
                                          ofItemAtPath:probeFile.path error:nil];
            AVURLAsset *probe = [AVURLAsset URLAssetWithURL:probeFile options:nil];
            NSError *probeError = nil;
            r[@"probePlayable"] = @(probe.playable);
            r[@"probeReadable"] = @(probe.readable);
            r[@"probeExportable"] = @(probe.exportable);
            r[@"probeVideoTracks"] = @([probe tracksWithMediaType:AVMediaTypeVideo].count);
            r[@"probePlayableStatus"] = @([probe statusOfValueForKey:@"playable" error:&probeError]);
            if (probeError) r[@"probeError"] = probeError.description;
            r[@"probeExportPresets"] = [AVAssetExportSession exportPresetsCompatibleWithAsset:probe];
            NSError *adapterError = nil;
            id adapter = MakeAsset(@{@"id":@4, @"fileName":@"probe.mov", @"fileType":@"video"},
                                   probeFile, nil, YES, &adapterError);
            r[@"probeNativeAdapter"] = @(adapter != nil);
            r[@"probeNativeThumbnail"] = @(adapter && Get(adapter,@"getThumbnail") != nil);
            if (adapterError) r[@"probeAdapterError"] = adapterError.localizedDescription;
        }
        if ([NSFileManager.defaultManager fileExistsAtPath:videoFile.path]) {
            NSError *videoError = nil;
            id videoAsset = MakeAsset(@{@"id":@3, @"fileName":@"test.mp4", @"fileType":@"video"}, videoFile, nil, YES, &videoError);
            r[@"videoAssetCreated"] = @(videoAsset != nil);
            if (videoAsset) {
                r[@"videoNativeClass"] = NSStringFromClass([videoAsset class]);
                r[@"videoIsVideo"] = @(((BOOL(*)(id,SEL))objc_msgSend)(videoAsset,NSSelectorFromString(@"isVideo")));
                id url = Get(videoAsset,@"getVideoUrl");
                r[@"videoURLClass"] = NSStringFromClass([url class]) ?: @"nil";
                r[@"videoURLMatches"] = @([url isKindOfClass:NSURL.class] && [[url path] isEqual:videoFile.path]);
                r[@"videoThumbnailCreated"] = @(Get(videoAsset,@"getThumbnail") != nil);
                r[@"videoDuration"] = [Get(videoAsset,@"videoDuration") description] ?: @"nil";
                id copied = [videoAsset copy];
                r[@"videoCopyPreservesURL"] = @([[Get(copied,@"getVideoUrl") path] isEqual:videoFile.path]);
                r[@"videoFileSizeCallback"] = @NO;
                void (^fileSize)(NSNumber *) = ^(NSNumber *value) {
                    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:videoFile.path error:nil];
                    r[@"videoFileSizeCallback"] = @([value isKindOfClass:NSNumber.class] &&
                        value.unsignedLongLongValue == [attrs[NSFileSize] unsignedLongLongValue]);
                };
                ((void(*)(id,SEL,id))objc_msgSend)(videoAsset,
                    NSSelectorFromString(@"asyncGetVideoFileSizeWithBlock:"), fileSize);
                NSError *infoError = nil;
                id info = FNMakeVideoInfo(videoFile, videoFile,
                    [dir URLByAppendingPathComponent:@"video-cover.jpg"], image, videoAsset, YES, &infoError);
                r[@"videoMessageInfoCreated"] = @(info != nil);
                r[@"videoMessagePathMatches"] = @([Get(info,@"video_path") isEqual:videoFile.path]);
                r[@"videoMessageOriginalPathMatches"] = @([Get(info,@"nsRawVidePath") isEqual:videoFile.path]);
                r[@"videoMessageHasCover"] = @([NSFileManager.defaultManager fileExistsAtPath:Get(info,@"thumb_path")]);
                if (infoError) r[@"videoMessageError"] = infoError.localizedDescription;
            }
            if (videoError) r[@"videoError"] = videoError.localizedDescription;
        }
        NSURL *gif = [dir URLByAppendingPathComponent:@"test.gif"];
        NSData *gifData = [[NSData alloc]
            initWithBase64EncodedString:@"R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
                                options:0];
        [gifData writeToURL:gif atomically:YES];
        id gifAsset = MakeAsset(@{@"id" : @2, @"fileName" : @"test.gif"}, gif, nil, YES, &error);
        r[@"gifDetected"] =
            @(gifAsset && ((BOOL(*)(id, SEL))objc_msgSend)(gifAsset, NSSelectorFromString(@"isGif")));
        Class live = LiveAssetClass();
        r[@"liveClassRegistered"] = @(live != Nil);
        if (error)
            r[@"error"] = error.localizedDescription;
        // Probe source-data callback without handing anything to a chat.
        if (asset) {
            __block BOOL called = NO;
            void (^ok)(id) = ^(id value) {
                called = YES;
                r[@"originDataResultClass"] = NSStringFromClass([value class]) ?: @"nil";
                r[@"originBytesAvailable"] = @([value isKindOfClass:NSData.class] && [value length] > 0);
            };
            void (^bad)(id) = ^(id e) {
                called = YES;
                r[@"originDataUnsupported"] = @YES;
            };
            ((void (*)(id, SEL, id, id))objc_msgSend)(
                asset, NSSelectorFromString(@"asyncImageOriginSourceData:errorBlock:"), ok, bad);
            r[@"originCallbackSynchronous"] = @(called);
            __block NSUInteger stages = 0;
            void (^process)(UIImage *, NSData *) = ^(UIImage *im, NSData *data) {
                stages++;
                r[@"processImageValid"] =
                    @([im isKindOfClass:UIImage.class] && [data isKindOfClass:NSData.class]);
            };
            void (^imageOK)(UIImage *, id) = ^(UIImage *im, id info) {
                r[@"processBeforeResult"] = @(stages == 1);
                r[@"bigImageAvailable"] = @(im != nil);
                r[@"bigImageDataClass"] = NSStringFromClass([info class]) ?: @"nil";
                r[@"bigImageDataAvailable"] = @([info isKindOfClass:NSData.class] && [info length] > 0);
            };
            ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(
                asset,
                NSSelectorFromString(@"getBigImageWithCompressConfig:ProcessBlock:ResultBlock:ErrorBlock:"),
                nil, process, imageOK, bad);
        }
    } @catch (NSException *exception) {
        r[@"exception"] = exception.name;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil]
            writeToURL:[FNCacheDirectory() URLByAppendingPathComponent:@"asset-tests.json"]
            atomically:YES];
    });
}
