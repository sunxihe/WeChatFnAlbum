#import "FNNASVideoPreview.h"
NSDictionary *FNPreviewVideoQuality(NSArray *qualities) {
    if (![qualities isKindOfClass:NSArray.class]) return nil;
    NSDictionary *best = nil;
    for (id value in qualities) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        id resolution = value[@"resolution"], bitrate = value[@"bitrate"];
        if (![resolution isKindOfClass:NSString.class] || ![bitrate isKindOfClass:NSNumber.class] ||
            [bitrate longLongValue] <= 0 || ![resolution length] ||
            [resolution rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound ||
            [resolution integerValue] <= 0) continue;
        NSInteger height = [resolution integerValue], previous = [best[@"resolution"] integerValue];
        // Prefer 480p; if unavailable prefer 720p, then the smallest advertised size.
        NSInteger rank = height == 480 ? 0 : height == 720 ? 1 : height+2;
        NSInteger oldRank = previous == 480 ? 0 : previous == 720 ? 1 : previous+2;
        if (!best || rank < oldRank || (rank == oldRank && [bitrate longLongValue] < [best[@"bitrate"] longLongValue])) best = value;
    }
    return best;
}
@interface FNNASVideoPreview ()
@property(nonatomic) FNClient *client;
@property(nonatomic) NSNumber *photoID;
@property(nonatomic) BOOL preparing;
@property(nonatomic) NSMutableArray *waiters;
@property(nonatomic) NSDictionary<NSString *,NSNumber *> *preparationTimings;
@property(nonatomic) NSString *path;
@property(nonatomic) NSString *qualityLabel;
@property(nonatomic) NSString *playLink;
@property(nonatomic) NSTimer *heartbeat;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL stopped;
@property(nonatomic) BOOL recording;
@property(nonatomic) NSString *playbackToken;
@end
static FNNASVideoPreview *WarmPreview;
static NSTimer *WarmExpiry;
@implementation FNNASVideoPreview
+ (void)clearWarmPreview {
    FNNASVideoPreview *old=WarmPreview;
    WarmPreview=nil;
    [WarmExpiry invalidate]; WarmExpiry=nil;
    [old stop];
}
+ (void)holdWarmPreview:(FNNASVideoPreview *)preview {
    [self clearWarmPreview];
    WarmPreview=preview;
    WarmExpiry=[NSTimer timerWithTimeInterval:20 repeats:NO block:^(NSTimer *t) { [self clearWarmPreview]; }];
    [NSRunLoop.mainRunLoop addTimer:WarmExpiry forMode:NSRunLoopCommonModes];
}
+ (instancetype)takePhoto:(NSDictionary *)photo client:(FNClient *)client {
    FNNASVideoPreview *cached=WarmPreview;
    if (cached && !cached.stopped && cached.client==client && cached.generation==client.generation &&
        [cached.photoID isEqual:photo[@"id"]]) {
        WarmPreview=nil;
        [WarmExpiry invalidate]; WarmExpiry=nil;
        return cached;
    }
    [self clearWarmPreview];
    return [[self alloc] initWithClient:client];
}
+ (void)prewarmPhoto:(NSDictionary *)photo client:(FNClient *)client {
    if (!client.authenticated || ![photo[@"id"] isKindOfClass:NSNumber.class]) return;
    if (WarmPreview && WarmPreview.client==client && WarmPreview.generation==client.generation &&
        [WarmPreview.photoID isEqual:photo[@"id"]] && !WarmPreview.stopped) return;
    FNNASVideoPreview *preview=[[self alloc] initWithClient:client];
    [self holdWarmPreview:preview];
    [preview preparePhoto:photo completion:^(NSError *error) {
        if (error && WarmPreview==preview) [self clearWarmPreview];
    }];
}
- (void)park {
    self.onCredentialsChanged=nil;
    if (self.stopped || !self.path.length || self.client.generation!=self.generation ||
        !self.client.authenticated || WarmPreview) { [self stop]; return; }
    [FNNASVideoPreview holdWarmPreview:self];
}
- (void)preparePhoto:(NSDictionary *)photo completion:(void (^)(NSError *))completion {
    if (self.stopped || (self.photoID && (self.generation!=self.client.generation || ![self.photoID isEqual:photo[@"id"]]))) {
        completion(FNError(@"预览已取消或素材已改变。")); return;
    }
    if (self.path.length && self.client.generation==self.generation) { completion(nil); return; }
    if (!self.waiters) self.waiters=[NSMutableArray array];
    [self.waiters addObject:[completion copy]];
    if (self.preparing) return;
    self.preparing=YES;
    self.photoID=photo[@"id"];
    [self beginPhoto:photo completion:^(NSError *error) {
        self.preparing=NO;
        NSArray *callbacks=[self.waiters copy]; [self.waiters removeAllObjects];
        for (void (^callback)(NSError *) in callbacks) callback(error);
    }];
}

- (instancetype)init { return [self initWithClient:FNClient.shared]; }
- (instancetype)initWithClient:(FNClient *)client { if ((self=[super init])) _client=client; return self; }
- (void)closeLink:(NSString *)link {
    FNClient *client = self.client;
    if (link.length && client.generation == self.generation && client.authenticated)
        [client post:@"/p/api/v1/video/decode/quit" body:@{@"playLink":link} completion:^(NSDictionary *r,NSError *e) {}];
}
- (void)beginPhoto:(NSDictionary *)photo completion:(void (^)(NSError *))completion {
    FNClient *client = self.client;
    self.generation = client.generation;
    id identity = photo[@"id"];
    if (![identity isKindOfClass:NSNumber.class] || [identity longLongValue] <= 0) {
        completion(FNError(@"视频缺少有效 ID，无法申请流畅预览。")); return;
    }
    NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;
    [client get:@"/p/api/v1/video/decode/info" params:@{@"id":identity} completion:^(NSDictionary *info,NSError *error) {
        if (self.stopped || client.generation != self.generation) { completion(FNError(@"预览已取消。")); return; }
        NSTimeInterval infoFinished=NSProcessInfo.processInfo.systemUptime;
        self.preparationTimings=@{@"infoSeconds":@(infoFinished-started)};
        NSDictionary *quality = FNPreviewVideoQuality(info[@"quality"]);
        if (error || !quality) { completion(error ?: FNError(@"NAS 未提供可用的流畅清晰度，请选择原视频预览。")); return; }
        self.qualityLabel = [NSString stringWithFormat:@"流畅 %@p", quality[@"resolution"]];
        [client post:@"/p/api/v1/video/decode/play" body:@{@"id":identity,@"bitrate":quality[@"bitrate"],
                @"resolution":quality[@"resolution"],@"audioIndex":@(-2),
                // Match the NAS web player compatibility options; HEVC in TS is audio-only on AVPlayer.
                @"videoEncoder":@"h264",@"audioEncoder":@"aac",@"channels":@2} completion:^(NSDictionary *result,NSError *error) {
            self.preparationTimings=@{@"infoSeconds":@(infoFinished-started),
                @"playSeconds":@(NSProcessInfo.processInfo.systemUptime-infoFinished)};
            NSString *link = [result[@"playLink"] isKindOfClass:NSString.class] ? result[@"playLink"] : nil;
            if (self.stopped || client.generation != self.generation) {
                [self closeLink:link]; completion(FNError(@"预览已取消。")); return;
            }
            if (error || !link.length || ![link hasPrefix:@"/"] || [link hasPrefix:@"//"] ||
                [link containsString:@".."] || [link containsString:@"#"]) {
                [self closeLink:link];
                completion(error ?: FNError(@"NAS 返回的流畅预览地址不兼容。")); return;
            }
            self.playLink = link;
            self.path = [@"/p/api/v1/video/decode/stream" stringByAppendingString:link];
            __weak typeof(self) weak = self;
            self.heartbeat = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { [weak record]; }];
            [NSRunLoop.mainRunLoop addTimer:self.heartbeat forMode:NSRunLoopCommonModes];
            self.playbackToken = [self currentPlaybackToken];
            [self record];
            completion(nil);
        }];
    }];
}
- (NSString *)currentPlaybackToken {
    NSDictionary *configuration = [self.client videoPlaybackConfiguration:self.path error:nil];
    for (NSHTTPCookie *cookie in configuration[@"cookies"])
        if ([cookie.name isEqual:@"fnos-token"]) return cookie.value;
    return nil;
}
- (void)record {
    if (self.stopped || self.recording || !self.playLink.length) return;
    FNClient *client = self.client;
    if (client.generation != self.generation) { [self stop]; return; }
    self.recording = YES;
    [client post:@"/p/api/v1/video/decode/record" body:@{@"playLink":self.playLink} completion:^(NSDictionary *r,NSError *e) {
        self.recording = NO;
        if (!e && !self.stopped && client.generation == self.generation) {
            NSString *token = [self currentPlaybackToken];
            BOOL changed = self.playbackToken.length && token.length && ![token isEqual:self.playbackToken];
            self.playbackToken = token;
            if (changed && self.onCredentialsChanged) self.onCredentialsChanged();
        }
    }];
}
- (void)stop {
    if (self.stopped) return;
    self.stopped = YES;
    self.onCredentialsChanged = nil;
    self.playbackToken = nil;
    [self.heartbeat invalidate]; self.heartbeat = nil;
    [self closeLink:self.playLink]; self.playLink = nil;
}
- (void)dealloc { [self stop]; }
@end
