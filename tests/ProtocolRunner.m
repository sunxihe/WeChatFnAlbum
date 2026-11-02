#import "FNHost.h"
#import "FNImageDelivery.h"
#import "FNMediaHandoff.h"
#import "FNProtocol.h"
#import <Foundation/Foundation.h>
static void Output(id value) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    puts([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String);
}
static void Require(BOOL ok, NSString *message) {
    if (!ok) {
        fprintf(stderr, "%s\n", message.UTF8String);
        exit(1);
    }
}
// Test doubles only; no WeChat code or message APIs are linked into this runner.
@interface CaptureVideoInfo : NSObject
@end
@implementation CaptureVideoInfo
@end
@interface FNTestImageDestination : NSObject
@property(nonatomic) NSMutableArray *events;
@end
@implementation FNTestImageDestination
- (instancetype)init { if ((self=[super init])) _events=[NSMutableArray array]; return self; }
- (void)didSelectMMAsset:(id)asset finish:(BOOL)finish fromImagePicker:(id)picker {
    Require(![asset isKindOfClass:CaptureVideoInfo.class], @"video entered image callback");
    [self.events addObject:@{@"asset":asset, @"finish":@(finish)}];
}
@end
@interface FNTestVideoDestination : NSObject
@property(nonatomic) NSMutableArray *events;
@end
@implementation FNTestVideoDestination
- (instancetype)init { if ((self=[super init])) _events=[NSMutableArray array]; return self; }
- (void)CameraControllerDidTakeVideo:(id)info { [self.events addObject:info]; }
@end
@interface FNTestPicker : NSObject
@property(nonatomic) NSUInteger dismissals;
@end
@implementation FNTestPicker
- (void)DismissModalViewControllerAnimated:(BOOL)animated { self.dismissals++; }
@end
static void TestMediaHandoff(void) {
    FNTestImageDestination *images=[FNTestImageDestination new];
    FNTestVideoDestination *videos=[FNTestVideoDestination new];
    FNTestPicker *picker=[FNTestPicker new];
    id a=[CaptureVideoInfo new], b=[CaptureVideoInfo new];
    NSError *error=nil;
    Require(FNMediaHandoff(@[@"first",a,@"second",b],images,videos,picker,&error), @"mixed handoff");
    Require(images.events.count==2 && videos.events.count==2 && videos.events[0]==a && videos.events[1]==b,
            @"media routing preserves each kind and order");
    Require(![images.events[0][@"finish"] boolValue] && [images.events[1][@"finish"] boolValue] &&
            picker.dismissals==0, @"final photo finishes image callback even when video is last");
    [images.events removeAllObjects]; [videos.events removeAllObjects];
    Require(FNMediaHandoff(@[a,b],images,videos,picker,&error) && !images.events.count &&
            videos.events.count==2 && picker.dismissals==1, @"video-only handoff dismisses once");
    [videos.events removeAllObjects];
    Require(!FNMediaHandoff(@[@"image",a],images,[NSObject new],picker,&error) && error &&
            !images.events.count && !videos.events.count, @"incompatible video destination fails before any send");
}
#include "TokenRenewalTests.inc"
#include "VideoPreviewTests.inc"
static FNImageDelivery *EscapingDelivery(NSMutableArray *events) {
    NSString *marker = NSUUID.UUID.UUIDString;
    FNImageDelivery *delivery = [[FNImageDelivery alloc]
        initWithProcess:^(UIImage *image, NSData *data) {
            Require(marker.length > 0 && [data isEqual:[@"original" dataUsingEncoding:NSUTF8StringEncoding]],
                    @"process payload lifetime");
            [events addObject:@"process"];
        }
        result:^(UIImage *image, NSData *data) {
            Require(marker.length > 0 && [data isEqual:[@"original" dataUsingEncoding:NSUTF8StringEncoding]],
                    @"result payload lifetime");
            [events addObject:@"result"];
        }];
    return delivery;
}
static void TestEscapingCallbacks(void) {
    NSMutableArray *events = [NSMutableArray array];
    FNImageDelivery *delivery = EscapingDelivery(events);
    struct BlockHeader {
        void *isa;
        unsigned int flags;
        unsigned int reserved;
    };
    const struct BlockHeader *process = (__bridge const void *)delivery.process;
    const struct BlockHeader *result = (__bridge const void *)delivery.result;
    Require((process->flags & (1u << 24)) && (result->flags & (1u << 24)), @"callbacks must own heap blocks");
    volatile unsigned char churn[32768];
    for (NSUInteger i = 0; i < sizeof(churn); i++)
        churn[i] = (unsigned char)i;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delivery deliverImage:nil data:[@"original" dataUsingEncoding:NSUTF8StringEncoding]];
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (events.count < 2 && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Require([events isEqual:@[ @"process", @"result" ]], @"escaping callbacks and order");
}
typedef void (^FNTestDone)(NSError *);
typedef void (^FNTestStep)(FNTestDone);
static void RunSteps(NSArray *steps, NSUInteger index, FNTestDone finish) {
    if (index == steps.count) {
        finish(nil);
        return;
    }
    FNTestStep step = steps[index];
    step(^(NSError *e) {
        if (e)
            finish(e);
        else
            RunSteps(steps, index + 1, finish);
    });
}
static void TestReversePaging(FNPhotoPager *base, FNTestDone done) {
    FNPhotoPager *pager = [base pagerStartingAtDay:1];
    [pager next:^(NSArray *older, NSError *error) {
        Require(!error && older.count == 7 && pager.hasPrevious && !pager.hasNext,
                @"historical initial cursor");
        [pager previous:^(NSArray *newer, NSError *newerError) {
            Require(!newerError && newer.count == 60 && [newer[0][@"id"] integerValue] == 30005 &&
                        [newer[59][@"id"] integerValue] == 30064,
                    @"newer day tail ordering");
            [pager previous:^(NSArray *failed, NSError *expectedError) {
                Require(expectedError != nil && failed == nil && pager.hasPrevious,
                        @"newer failure preserves head");
                [pager previous:^(NSArray *latest, NSError *retryError) {
                    Require(!retryError && latest.count == 5 && [latest[0][@"id"] integerValue] == 30000 &&
                                !pager.hasPrevious && !pager.hasNext,
                            @"newer retry and independent forward cursor");
                    NSMutableArray *all = [latest mutableCopy];
                    [all addObjectsFromArray:newer];
                    [all addObjectsFromArray:older];
                    Require([NSSet setWithArray:[all valueForKey:@"id"]].count == 72,
                            @"bidirectional duplicates or gaps");
                    [pager previous:^(NSArray *empty, NSError *endError) {
                        Require(!endError && empty.count == 0, @"latest boundary");
                        done(nil);
                    }];
                }];
            }];
        }];
    }];
}
static void TestCategories(FNClient *client, FNTestDone done) {
    RunSteps(@[
        ^(FNTestDone next) {
            [client get:@"/p/api/v1/ai-person/list"
                    params:@{@"orderBy" : @"name", @"getAll" : @"true"}
                completion:^(NSDictionary *r, NSError *e) {
                    Require(!e && [r[@"list"] count] == 1, @"person directory");
                    FNPhotoPager *p = [FNPhotoPager new];
                    p.queryFilters = FNCategoryFilters(@"person", r[@"list"][0]);
                    [p next:^(NSArray *rows, NSError *error) {
                        Require(!error && rows.count == 1 && [rows[0][@"id"] integerValue] == 1002,
                                @"person filter results");
                        next(nil);
                    }];
                }];
        },
        ^(FNTestDone next) {
            [client get:@"/p/api/v1/explore/geos"
                params:@{
                    @"offset" : @0,
                    @"limit" : @60
                }
                completion:^(NSDictionary *r, NSError *e) {
                    Require(!e && [r[@"list"] count] == 1, @"location directory");
                    FNPhotoPager *p = [FNPhotoPager new];
                    p.queryFilters = FNCategoryFilters(@"location", r[@"list"][0]);
                    [p next:^(NSArray *rows, NSError *error) {
                        Require(!error && rows.count == 1 && [rows[0][@"id"] integerValue] == 1003,
                                @"country/city filter results");
                        next(nil);
                    }];
                }];
        },
        ^(FNTestDone next) {
            FNPhotoPager *p = [FNPhotoPager new];
            p.queryFilters = FNCategoryFilters(@"media", FNMediaTypeCategories()[0]);
            [p next:^(NSArray *rows, NSError *e) {
                Require(!e && rows.count == 1 && FNIsVideo(rows[0]) && FNIsSupportedMedia(rows[0]) &&
                            !p.hasNext && [FNMediaURL(rows[0], YES) isEqual:@"/video.mp4"] &&
                            [FNMediaURL(rows[0], NO) isEqual:@"/small.jpg"],
                        @"video filter hydration");
                next(nil);
            }];
        }
    ],
             0, done);
}
static void TestNewFeatures(FNClient *c, FNPhotoPager *p, NSDictionary *fixture, FNTestDone finish) {
    // The direct HTTP fixture handles POST bodies; the WS proxy was used for login.
    [c setValue:[NSURL URLWithString:fixture[@"httpAddress"]] forKey:@"baseURL"];
    RunSteps(@[
        ^(FNTestDone next) {
            TestReversePaging(p, next);
        },
        ^(FNTestDone next) {
            TestCategories(c, next);
        },
        ^(FNTestDone next) {
            [c search:@"海边日落 + \"test\""
                completion:^(NSDictionary *r, NSError *e) {
                    Require(!e && [r[@"list"] count] == 1, e.localizedDescription ?: @"AI result");
                    next(nil);
                }];
        },
        ^(FNTestDone next) {
            [c search:@"模型未安装"
                completion:^(NSDictionary *r, NSError *e) {
                    Require(!r && [e.localizedDescription containsString:@"模型"], @"AI nested model error");
                    next(nil);
                }];
        },
        ^(FNTestDone next) {
            [c search:@"模型不统一"
                completion:^(NSDictionary *r, NSError *e) {
                    Require(!r && [e.localizedDescription containsString:@"重置"],
                            @"AI envelope model error");
                    next(nil);
                }];
        },
        ^(FNTestDone next) {
            FNPhotoPager *seek = [p pagerStartingAtDay:1];
            [seek next:^(NSArray *rows, NSError *e) {
                Require(!e && rows.count == 7 && !seek.hasNext, @"date seek page size");
                Require([rows[0][@"id"] integerValue] == 29000 && [rows[0][@"fn_dayIndex"] integerValue] == 1,
                        @"date seek target");
                FNPhotoPager *back = [seek pagerStartingAtDay:0];
                [back next:^(NSArray *latest, NSError *backError) {
                    Require(!backError && latest.count == 60 && [latest[0][@"id"] integerValue] == 30000,
                            @"seek back to latest");
                    next(nil);
                }];
            }];
        },
        ^(FNTestDone next) {
            FNPhotoPager *album = [FNPhotoPager new];
            album.albumID = @"1";
            [album next:^(NSArray *rows, NSError *e) {
                Require(!e && rows.count == 60 && album.days.count == 2, @"album timeline");
                FNPhotoPager *seek = [album pagerStartingAtDay:1];
                [seek next:^(NSArray *older, NSError *seekError) {
                    Require(!seekError && older.count == 7 && [older[0][@"id"] integerValue] == 29000,
                            @"album date filter");
                    next(nil);
                }];
            }];
        },
        ^(FNTestDone next) {
            FNPhotoPager *search = [FNPhotoPager new];
            search.searchKeyword = @"分页搜索";
            [search next:^(NSArray *rows, NSError *e) {
                Require(!e && rows.count == 60 && search.hasNext, @"AI first page");
                Require([rows[0][@"id"] integerValue] == 1 && FNMediaURL(rows[0], YES).length,
                        @"AI detail hydration and ordering");
                [search next:^(NSArray *tail, NSError *tailError) {
                    Require(!tailError && tail.count == 5 && !search.hasNext &&
                                [tail[0][@"id"] integerValue] == 61,
                            @"AI next page");
                    next(nil);
                }];
            }];
        }
    ],
             0, finish);
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSDictionary *fixture = [NSJSONSerialization
            JSONObjectWithData:[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]]
                       options:0
                         error:nil];
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        if ([mode isEqual:@"renewal"]) return RunTokenRenewal(fixture);
        if ([mode isEqual:@"video-preview"]) { TestVideoPreview(); Output(@{@"ok":@YES}); return 0; }
        if ([mode isEqual:@"handoff"]) {
            TestMediaHandoff(); Output(@{@"ok":@YES}); return 0;
        }
        if ([mode isEqual:@"media"]) {
            Require(!FNMediaSizeText(@[]).length &&
                [FNMediaSizeText(@[@{@"fileSize":@1000000},@{@"fileSize":@"2000000"}]) isEqual:FNMediaSizeText(@[@{@"fileSize":@3000000}])] &&
                [FNMediaSizeText(@[@{}]) isEqual:@"大小未知"] &&
                [FNMediaSizeText(@[@{@"fileSize":@"invalid"}]) isEqual:@"大小未知"] &&
                [FNMediaSizeText(@[@{@"fileSize":@(LLONG_MAX)},@{@"fileSize":@1}]) isEqual:@"大小未知"], @"original size sum and invalid metadata");
            Require([FNVideoDurationText(@{@"fileName":@"v.mp4",@"mediaDuration":@65}) isEqual:@"01:05"] &&
                    [FNVideoDurationText(@{@"fileType":@"video",@"mediaDuration":@3661}) isEqual:@"01:01:01"] &&
                    !FNVideoDurationText(@{@"fileName":@"a.jpg",@"mediaDuration":@65}).length &&
                    !FNVideoDurationText(@{@"fileName":@"v.mp4",@"mediaDuration":NSNull.null}).length &&
                    !FNVideoDurationText(@{@"fileName":@"v.mp4",@"mediaDuration":@(-1)}).length,
                    @"video seconds, long duration and invalid/missing metadata");
            Require(FNRouteUsesLocal(1,@"Home",@"Home") && !FNRouteUsesLocal(1,@"Home",@"home") &&
                    !FNRouteUsesLocal(1,@"Home",nil) && !FNRouteUsesLocal(1,@"",@"") &&
                    FNRouteUsesLocal(2,nil,nil) && !FNRouteUsesLocal(3,@"Home",@"Home"),
                    @"SSID exact match, unknown fallback and manual route");
            Require([FNPersonPortraitURL(@{@"faceId":@123}) isEqual:@"/p/api/v1/stream/face/123"] &&
                        !FNPersonPortraitURL(@{@"faceId":NSNull.null}).length &&
                        !FNPersonPortraitURL(@{@"faceId":@0}).length,
                    @"person portrait uses face ID, missing face uses placeholder");
            Require(FNIsVideo(@{@"fileName" : @"movie.MP4"}) && FNIsVideo(@{@"fileName" : @"capture.mov"}),
                    @"video extensions");
            Require(FNIsVideo(@{@"fileName" : @"capture", @"fileType" : @"video"}), @"video metadata type");
            Require(!FNIsVideo(@{@"fileName" : @"test.gif"}) && !FNIsSupportedMedia((id)NSNull.null),
                    @"invalid media");
            NSDictionary *video = @{
                @"fileName" : @"movie.mp4",
                @"additional" : @{@"thumbnail" : @{@"originalUrl" : @"/large.mp4"}}
            };
            Require(!FNMediaURL(video, NO).length && [FNMediaURL(video, YES) isEqual:@"/large.mp4"],
                    @"video grid must not buffer original movie");
            NSDictionary *separateVideo = @{
                @"fileName":@"movie.mov", @"fileType":@"video",
                @"additional":@{@"thumbnail":@{@"originalUrl":@"/poster.jpg", @"videoUrl":@"/actual.mov", @"sUrl":@"/small.jpg"}}
            };
            Require([FNMediaURL(separateVideo, YES) isEqual:@"/actual.mov"] &&
                    [FNMediaURL(separateVideo, NO) isEqual:@"/small.jpg"],
                    @"movie playback and sending use video URL, grid uses poster");
            Require([FNMediaURL(@{@"fileName":@"live.heic", @"isLive":@YES,
                    @"additional":separateVideo[@"additional"]}, YES) isEqual:@"/poster.jpg"],
                    @"live photo still uses its image original and separate paired movie");
            Require(FNIsPhoto(@{@"fileName" : @"raw.NEF"}) &&
                        FNIsPhoto(@{@"fileName" : @"opaque", @"fileType" : @"image"}),
                    @"raw image metadata");
            Require(FNMediaTypeCategories().count == 7 &&
                        [FNCategoryFilters(@"media", @{@"value" : @"live_photo"})[0][@"filterValue"]
                            isEqual:@"live_photo"],
                    @"media category values");
            Require(FNCategoryFilters(@"person", @{@"name" : @"invalid"}).count == 0 &&
                        FNCategoryFilters(@"media", @{@"value" : @"unknown"}).count == 0,
                    @"invalid category filters");
            Output(@{@"ok" : @YES});
            return 0;
        }
        if ([mode isEqual:@"hosts"]) {
            for (NSDictionary *row in fixture[@"hosts"])
                Require(FNIsWeChatMainApplication(row[@"info"], row[@"path"]) == [row[@"expected"] boolValue],
                        @"signed host detection mismatch");
            Output(@{@"ok" : @YES});
            return 0;
        }
        if ([mode isEqual:@"callbacks"]) {
            TestEscapingCallbacks();
            Output(@{@"ok" : @YES});
            return 0;
        }
        if ([mode isEqual:@"unit"]) {
            for (NSDictionary *r in fixture[@"endpoints"]) {
                NSError *e = nil;
                NSURL *u = FNEndpoint(r[@"input"], &e);
                Require(r[@"output"] == NSNull.null ? !u : [u.absoluteString isEqual:r[@"output"]],
                        [NSString stringWithFormat:@"Endpoint failed: %@", r[@"input"]]);
            }
            for (NSDictionary *r in fixture[@"signatures"]) {
                NSString *s = FNAuthx([NSURL URLWithString:r[@"url"]], @"123456", @"1793320000000");
                Require([s isEqual:r[@"expected"]], @"GET authx mismatch");
            }
            NSData *key = [[NSData alloc] initWithBase64EncodedString:fixture[@"key"] options:0],
                   *iv = [[NSData alloc] initWithBase64EncodedString:fixture[@"iv"] options:0];
            NSError *e = nil;
            NSDictionary *envelope = FNEncrypted(fixture[@"payload"], fixture[@"pub"], key, iv, &e);
            Require(envelope != nil, e.localizedDescription ?: @"RSA encryption failed");
            NSData *cipher = [[NSData alloc] initWithBase64EncodedString:envelope[@"aes"] options:0];
            NSData *plain = FNAES(cipher, key, iv, NO, &e);
            Require([[NSJSONSerialization JSONObjectWithData:plain options:0
                                                       error:nil] isEqual:fixture[@"payload"]],
                    @"AES CBC roundtrip failed");
            Output(envelope);
            return 0;
        }
        __block BOOL done = NO;
        __block int status = 0;
        FNClient *c = [FNClient shared];
        void (^finish)(NSError *) = ^(NSError *e) {
            if (e) {
                fprintf(stderr, "%s\n", e.localizedDescription.UTF8String);
                status = 1;
            } else
                Output(@{@"ok" : @YES});
            [c logout];
            done = YES;
        };
        void (^readPhotos)(void) = ^{
            [c get:@"/p/api/v1/album/list"
                params:@{
                    @"sort_by" : @"date_time",
                    @"sort_direction" : @"desc",
                    @"offset" : @0,
                    @"limit" : @60
                }
                completion:^(NSDictionary *r, NSError *e) {
                    if (e) {
                        finish(e);
                        return;
                    }
                    FNPhotoPager *p = [FNPhotoPager new];
                    [p next:^(NSArray *a, NSError *e1) {
                        if (e1 || a.count != 60) {
                            finish(e1 ?: FNError(@"first page count"));
                            return;
                        }
                        [p next:^(NSArray *b, NSError *e2) {
                            if (e2 || b.count != 12 || p.hasNext) {
                                finish(e2 ?: FNError(@"second page cursor"));
                                return;
                            }
                            FNPhotoPager *f = [FNPhotoPager new];
                            f.favorites = YES;
                            [f next:^(NSArray *d, NSError *e3) {
                                if (e3 || d.count != 5 || f.hasNext) {
                                    finish(e3 ?: FNError(@"favorites cursor"));
                                    return;
                                }
                                [c media:@"https://elsewhere.invalid/private"
                                    completion:^(NSData *x, NSError *e4) {
                                        Require(e4 != nil, @"cross origin allowed");
                                        [c media:@"/redirect"
                                            completion:^(NSData *y, NSError *e5) {
                                                Require(e5 != nil, @"redirect followed");
                                                NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                                    stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
                                                [c download:@"/fixture-media" to:file completion:^(NSError *downloadError) {
                                                    Require(!downloadError, @"media download failed");
                                                    NSDictionary *attrs = [NSFileManager.defaultManager
                                                        attributesOfItemAtPath:file.path error:nil];
                                                    Require([attrs[NSFilePosixPermissions] unsignedIntegerValue] == 0644,
                                                            @"download remains unreadable to iOS media service");
                                                    Require([[NSData dataWithContentsOfURL:file] isEqual:
                                                        [@"synthetic media bytes" dataUsingEncoding:NSUTF8StringEncoding]],
                                                        @"download bytes changed");
                                                    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
                                                    TestNewFeatures(c, p, fixture, finish);
                                                }];
                                            }];
                                    }];
                            }];
                        }];
                    }];
                }];
        };
        [c loginAddress:fixture[@"address"]
                   user:@"fixture-user"
               password:@"fixture-password"
               remember:[fixture[@"persist"] boolValue]
             completion:^(NSDictionary *r, NSError *e) {
                 if (e) {
                     finish(e);
                     return;
                 }
                 if ([r[@"twofa"] boolValue])
                     [c twoFactor:@"123456"
                         completion:^(NSDictionary *r2, NSError *e2) {
                             if (e2)
                                 finish(e2);
                             else if ([fixture[@"persist"] boolValue]) {
                                 Require(!r[@"warning"], r[@"warning"] ?: @"keychain save");
                                 [c setValue:nil forKey:@"token"];
                                 [c restore:^(NSDictionary *restored, NSError *restoreError) {
                                     if (restoreError)
                                         finish(restoreError);
                                     else
                                         readPhotos();
                                 }];
                             } else
                                 readPhotos();
                         }];
                 else if ([fixture[@"persist"] boolValue]) {
                     Require(!r[@"warning"], r[@"warning"] ?: @"keychain save");
                     [c setValue:nil forKey:@"token"];
                     [c restore:^(NSDictionary *restored, NSError *restoreError) {
                         if (restoreError)
                             finish(restoreError);
                         else
                             readPhotos();
                     }];
                 } else
                     readPhotos();
             }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:50];
        while (!done && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        Require(done, @"integration timed out");
        return status;
    }
}
