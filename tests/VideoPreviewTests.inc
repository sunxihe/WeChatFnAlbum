#import "FNNASVideoPreview.h"
@interface FNClient (AcknowledgementFixture)
- (void)perform:(NSURLRequest *)request completion:(FNResult)completion;
@end
@interface FNAcknowledgementClient : FNClient
@property(nonatomic) NSDictionary *response;
@end
@implementation FNAcknowledgementClient
- (FNTransfer *)transferRequest:(NSURLRequest *)request to:(NSURL *)target completion:(void (^)(NSData *,NSURLResponse *,NSError *))completion {
    completion([NSJSONSerialization dataWithJSONObject:self.response options:0 error:nil],nil,nil);
    return nil;
}
@end
@interface FNPreviewFixtureClient : FNClient
@property(nonatomic) NSUInteger fakeGeneration;
@property(nonatomic) NSMutableArray *events;
@property(nonatomic, copy) FNResult pendingPlay;
@property(nonatomic) BOOL deferPlay;
@property(nonatomic) BOOL missingQuality;
@property(nonatomic) NSString *fixtureToken;
@end
@implementation FNPreviewFixtureClient
- (instancetype)init { if ((self=[super init])) { _events=[NSMutableArray array]; _fixtureToken=@"token-a"; } return self; }
- (NSDictionary *)videoPlaybackConfiguration:(NSString *)path error:(NSError **)error {
    NSHTTPCookie *cookie=[NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName:@"fnos-token",NSHTTPCookieValue:self.fixtureToken,
        NSHTTPCookieDomain:@"fixture",NSHTTPCookiePath:@"/"}];
    return @{@"cookies":@[cookie]};
}
- (BOOL)authenticated { return YES; }
- (NSUInteger)generation { return self.fakeGeneration; }
- (void)get:(NSString *)path params:(NSDictionary *)params completion:(FNResult)completion {
    Require([path isEqual:@"/p/api/v1/video/decode/info"] && [params[@"id"] isEqual:@7],@"quality query");
    completion(@{@"quality":self.missingQuality ? @[] : @[@{@"resolution":@"480",@"bitrate":@1000000}]},nil);
}
- (void)post:(NSString *)path body:(NSDictionary *)body completion:(FNResult)completion {
    [self.events addObject:path.lastPathComponent];
    if ([path hasSuffix:@"/play"]) {
        Require([body[@"id"] isEqual:@7] && [body[@"resolution"] isEqual:@"480"] &&
            [body[@"bitrate"] isEqual:@1000000] && [body[@"audioIndex"] isEqual:@(-2)] && [body[@"videoEncoder"] isEqual:@"h264"] &&
            [body[@"audioEncoder"] isEqual:@"aac"] && [body[@"channels"] isEqual:@2],@"play payload/audio");
        if (self.deferPlay) self.pendingPlay=completion;
        else completion(@{@"playLink":@"/fixture/index.m3u8"},nil);
    } else completion(@{},nil);
}
@end
@interface FNNASVideoPreview (FixtureRecord)
- (void)record;
@end
static void TestVideoPreview(void) {
    FNAcknowledgementClient *ack=[FNAcknowledgementClient new];
    for (NSString *endpoint in @[@"record",@"quit"]) {
        NSURLRequest *request=[NSURLRequest requestWithURL:[NSURL URLWithString:[@"http://fixture/p/api/v1/video/decode/" stringByAppendingString:endpoint]]];
        for (id value in @[NSNull.null,@YES]) {
            ack.response=@{@"code":@0,@"data":value};
            [ack perform:request completion:^(NSDictionary *r,NSError *e) { Require(r && !e,@"accept successful lifecycle ack"); }];
        }
        ack.response=@{@"code":@5000,@"data":NSNull.null};
        [ack perform:request completion:^(NSDictionary *r,NSError *e) { Require(!r && e,@"never mask failed lifecycle ack"); }];
    }
    ack.response=@{@"code":@0,@"data":NSNull.null};
    [ack perform:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://fixture/p/api/v1/video/decode/play"]] completion:^(NSDictionary *r,NSError *e) { Require(!r && e,@"play must still return dictionary"); }];

    FNClient *real=FNClient.shared;
    [real setValue:[NSURL URLWithString:@"https://nas.fixture:5667"] forKey:@"baseURL"];
    [real setValue:@"synthetic-token" forKey:@"token"];
    NSError *configurationError=nil;
    NSDictionary *configuration=[real videoPlaybackConfiguration:@"/p/api/v1/video/decode/stream/fixture/index.m3u8" error:&configurationError];
    Require(configuration && !configurationError && [configuration[@"cookies"] count]==2,@"scoped playback configuration");
    for (NSHTTPCookie *cookie in configuration[@"cookies"])
        Require([cookie.domain isEqual:@"nas.fixture"] && [cookie.path isEqual:@"/p/api/v1/video/decode/stream/"] &&
            cookie.secure && cookie.HTTPOnly,@"stream cookies must be scoped and secure on HTTPS");
    Require(![real videoPlaybackConfiguration:@"https://outside.fixture/p/api/v1/video/decode/stream/a" error:nil] &&
        ![real videoPlaybackConfiguration:@"/original.mp4" error:nil],@"reject foreign or non-stream playback URL");
    NSDictionary *originalConfig=[real originalVideoPlaybackConfiguration:@"/p/api/v1/stream/v/fixture" error:&configurationError];
    Require(originalConfig && !configurationError,@"original video configuration");
    for (NSHTTPCookie *cookie in originalConfig[@"cookies"])
        Require([cookie.path isEqual:@"/p/api/v1/stream/v/fixture"] && [cookie.domain isEqual:@"nas.fixture"] && cookie.secure && cookie.HTTPOnly,@"original cookies scoped to exact media resource");
    Require(![real originalVideoPlaybackConfiguration:@"https://outside.fixture/video.mp4" error:nil] &&
        ![real originalVideoPlaybackConfiguration:@"/media/bad;path" error:nil],@"reject foreign and malformed original URLs");
    NSArray *qualities=@[@{@"resolution":@"1080",@"bitrate":@6000000},
        @{@"resolution":@"720",@"bitrate":@3000000},@{@"resolution":@"480",@"bitrate":@1000000}];
    Require([FNPreviewVideoQuality(qualities)[@"resolution"] isEqual:@"480"],@"prefer compact advertised quality");
    Require(!FNPreviewVideoQuality(@[NSNull.null,@{@"resolution":@"origin",@"bitrate":@5},
        @{@"resolution":@"480",@"bitrate":@0}]),@"reject invalid/original quality");
    FNPreviewFixtureClient *client=[FNPreviewFixtureClient new];
    FNNASVideoPreview *preview=[[FNNASVideoPreview alloc] initWithClient:client];
    __block BOOL prepared=NO;
    [preview preparePhoto:@{@"id":@7} completion:^(NSError *e) { prepared=!e; }];
    Require(prepared && [preview.path isEqual:@"/p/api/v1/video/decode/stream/fixture/index.m3u8"],@"stream path");
    __block NSUInteger rotations=0;
    preview.onCredentialsChanged=^{ rotations++; };
    client.fixtureToken=@"token-b";
    [preview record];
    Require(rotations==1,@"playback credentials refreshed after API rotation");
    [preview record];
    Require(rotations==1,@"unchanged token must not restart playback");
    [preview stop]; [preview stop];
    Require([client.events isEqual:@[@"play",@"record",@"record",@"record",@"quit"]],@"heartbeat and quit exactly once");
    client=[FNPreviewFixtureClient new]; client.deferPlay=YES;
    preview=[[FNNASVideoPreview alloc] initWithClient:client];
    __block BOOL cancelled=NO;
    [preview preparePhoto:@{@"id":@7} completion:^(NSError *e) { cancelled=e!=nil; }];
    [preview stop]; client.pendingPlay(@{@"playLink":@"/late/index.m3u8"},nil); client.pendingPlay=nil;
    Require(cancelled && [client.events isEqual:@[@"play",@"quit"]],@"late transcode allocation released");
    client=[FNPreviewFixtureClient new]; client.missingQuality=YES;
    preview=[[FNNASVideoPreview alloc] initWithClient:client];
    __block BOOL missing=NO;
    [preview preparePhoto:@{@"id":@7} completion:^(NSError *e) { missing=e!=nil; }];
    Require(missing && !client.events.count,@"no silent original video download");
    client=[FNPreviewFixtureClient new];
    preview=[[FNNASVideoPreview alloc] initWithClient:client];
    [preview preparePhoto:@{@"id":@7} completion:^(NSError *e) {}];
    client.fakeGeneration++;
    [preview preparePhoto:@{@"id":@7} completion:^(NSError *e) { Require(e!=nil,@"cannot prepare an old object with a changed session"); }];
    [preview stop];
    Require([client.events isEqual:@[@"play",@"record"]],@"do not send old link with new account");
    client=[FNPreviewFixtureClient new]; client.deferPlay=YES;
    [FNNASVideoPreview prewarmPhoto:@{@"id":@7} client:client];
    preview=[FNNASVideoPreview takePhoto:@{@"id":@7} client:client];
    __block BOOL acquired=NO;
    [preview preparePhoto:@{@"id":@7} completion:^(NSError *e) { acquired=!e; }];
    Require([client.events isEqual:@[@"play"]],@"prewarm and tap share a single pending request");
    client.pendingPlay(@{@"playLink":@"/fixture/index.m3u8"},nil); client.pendingPlay=nil;
    Require(acquired,@"tap completes when prewarm is ready");
    [preview park];
    FNNASVideoPreview *again=[FNNASVideoPreview takePhoto:@{@"id":@7} client:client];
    Require(again==preview,@"recent session reused without new transcode");
    [again preparePhoto:@{@"id":@7} completion:^(NSError *e) { Require(!e,@"prepared reuse succeeds"); }];
    Require([client.events isEqual:@[@"play",@"record"]],@"no repeated info/play on warm reuse");
    [again park]; [FNNASVideoPreview clearWarmPreview];
    Require([client.events isEqual:@[@"play",@"record",@"quit"]],@"warm cleanup releases NAS task once");

}
