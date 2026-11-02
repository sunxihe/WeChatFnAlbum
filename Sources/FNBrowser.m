#import "FNBrowser.h"
#import "FNNetworkRouting.h"
#import "FNCategories.h"
#import "FNTimelineScrubber.h"
#import "FNPreviewLoadingView.h"
#import "FNPreviewAudio.h"
#import "FNZoomImageView.h"
#import "FNWeChatBridge.h"
#import <AVKit/AVKit.h>
#import <ImageIO/ImageIO.h>
#import <WebKit/WebKit.h>

void FNAlert(UIViewController *vc, NSString *message) {
    if (!vc || vc.presentedViewController)
        return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"飞牛相册"
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}
NSURL *FNCacheDirectory(void) {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask]
                      .firstObject;
    NSURL *dir = [base URLByAppendingPathComponent:@"WeChatFnAlbum" isDirectory:YES];
    [NSFileManager.defaultManager
               createDirectoryAtURL:dir
        withIntermediateDirectories:YES
                         attributes:@{
                             NSFileProtectionKey : NSFileProtectionCompleteUntilFirstUserAuthentication
                         }
                              error:nil];
    [dir setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return dir;
}
@implementation FNNavigationController
- (void)DismissModalViewControllerAnimated:(BOOL)animated {
    [self dismissViewControllerAnimated:animated completion:nil];
}
@end
@implementation FNSelection
- (instancetype)init {
    if ((self = [super init])) {
        _photos = [NSMutableArray array];
        _limit = 9;
    }
    return self;
}
@end
static NSString *PhotoID(NSDictionary *p) {
    return [p[@"id"] description] ?: @"";
}
static NSUInteger Selected(FNSelection *s, NSDictionary *p) {
    return [s.photos indexOfObjectPassingTest:^BOOL(NSDictionary *obj, NSUInteger i, BOOL *stop) {
        return [PhotoID(p) isEqual:PhotoID(obj)];
    }];
}
static BOOL Toggle(UIViewController *vc, FNSelection *s, NSDictionary *p) {
    NSUInteger i = Selected(s, p);
    if (i != NSNotFound) {
        [s.photos removeObjectAtIndex:i];
        return YES;
    }
    if (s.photos.count >= (NSUInteger)s.limit) {
        FNAlert(vc, [NSString stringWithFormat:@"最多选择 %ld 张图片。", (long)s.limit]);
        return NO;
    }
    [s.photos addObject:p];
    return YES;
}
static UIImage *Decode(NSData *data, CGFloat size) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source)
        return nil;
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(
        source, 0, (__bridge CFDictionaryRef) @{
            (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
            (__bridge id)kCGImageSourceThumbnailMaxPixelSize : @(size),
            (__bridge id)kCGImageSourceCreateThumbnailWithTransform : @YES
        });
    CFRelease(source);
    UIImage *image = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg)
        CGImageRelease(cg);
    return image;
}
static NSCache *Images(void) {
    static NSCache *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NSCache new];
        c.totalCostLimit = 40 * 1024 * 1024;
    });
    return c;
}
static NSString *ThumbnailIdentity(NSString *url) {
    FNClient *client = [FNClient shared];
    return [NSString stringWithFormat:@"%@:%@:%lu:%@", client.baseURL.absoluteString,
                                     client.username, (unsigned long)client.generation, url];
}
static NSString *OriginalTitle(BOOL original, NSArray<NSDictionary *> *photos) {
    NSString *size=FNMediaSizeText(photos);
    return [NSString stringWithFormat:@"%@ 原图%@",original ? @"◉" : @"○",
        size.length ? [NSString stringWithFormat:@" (%@)",size] : @""];
}
@interface FNCell : UICollectionViewCell
@property(nonatomic) UIImageView *image;
@property(nonatomic) UIButton *check;
@property(nonatomic) UILabel *badge;
@property(nonatomic) UILabel *duration;
@property(nonatomic) NSString *identity;
@property(nonatomic) FNTransfer *task;
@property(nonatomic, copy) dispatch_block_t toggle;
@end
@implementation FNCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.secondarySystemBackgroundColor;
        _image = [UIImageView new];
        _image.contentMode = UIViewContentModeScaleAspectFill;
        _image.clipsToBounds = YES;
        [self.contentView addSubview:_image];
        _check = [UIButton buttonWithType:UIButtonTypeCustom];
        _check.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        _check.layer.cornerRadius = 15;
        _check.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [_check addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_check];
        _badge = [UILabel new];
        _badge.textColor = UIColor.whiteColor;
        _badge.backgroundColor = [UIColor colorWithWhite:0 alpha:.4];
        _badge.font = [UIFont boldSystemFontOfSize:11];
        [self.contentView addSubview:_badge];
        _duration = [UILabel new];
        _duration.textColor = UIColor.whiteColor;
        _duration.backgroundColor = [UIColor colorWithWhite:0 alpha:.6];
        _duration.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
        _duration.textAlignment = NSTextAlignmentCenter;
        _duration.layer.cornerRadius = 3;
        _duration.clipsToBounds = YES;
        [self.contentView addSubview:_duration];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.image.frame = self.contentView.bounds;
    self.check.frame = CGRectMake(self.bounds.size.width - 38, 6, 30, 30);
    self.badge.frame = CGRectMake(5, self.bounds.size.height - 23, 52, 18);
    CGFloat width = ceil([self.duration sizeThatFits:CGSizeMake(120, 18)].width) + 8;
    self.duration.frame = CGRectMake(self.bounds.size.width - width - 5, self.bounds.size.height - 23, width, 18);
}
- (void)prepareForReuse {
    [super prepareForReuse];
    [self.task cancel];
    self.task = nil;
    self.identity = nil;
    self.duration.text = nil;
    self.duration.hidden = YES;
    self.image.image = nil;
    self.toggle = nil;
}
- (void)tap {
    if (self.toggle)
        self.toggle();
}
@end

@interface FNPreviewController : UIViewController <WKNavigationDelegate, UIGestureRecognizerDelegate>
@property(nonatomic) NSArray<NSDictionary *> *photos;
@property(nonatomic) NSInteger index;
@property(nonatomic) FNSelection *selection;
@property(nonatomic, copy) void (^sendSelection)(UIViewController *, NSArray *, BOOL);
@property(nonatomic) UIImageView *image;
@property(nonatomic) FNZoomImageView *zoom;
@property(nonatomic) UIButton *liveButton;
@property(nonatomic) UIBarButtonItem *check;
@property(nonatomic) WKWebView *gif;
@property(nonatomic) AVPlayerViewController *player;
@property(nonatomic) FNPreviewAudio *audio;
@property(nonatomic) BOOL previewVisible;
@property(nonatomic) NSNumber *localVideoID;
@property(nonatomic) NSUInteger streamRetries;
@property(nonatomic) NSTimer *streamTimer;
#ifdef FN_VIDEO_PROBE
@property(nonatomic) NSTimer *videoProbeTimer;
#endif
@property(nonatomic) NSMutableArray<FNTransfer *> *tasks;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSURL *previewFile;
@property(nonatomic) FNPreviewLoadingView *loadingMask;
@property(nonatomic) NSTimer *loadingTimer;
@property(nonatomic) FNTransfer *loadingTask;
@property(nonatomic) NSUInteger loadingTicket;
@property(nonatomic) NSUInteger gifLoadingTicket;
@end
@implementation FNPreviewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.tasks = [NSMutableArray array];
    self.audio = [FNPreviewAudio new];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(suspendPreviewAudio) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(restorePreviewAudio) name:UIApplicationDidBecomeActiveNotification object:nil];
    self.zoom = [[FNZoomImageView alloc] initWithFrame:self.view.bounds];
    self.zoom.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.image = self.zoom.imageView;
    [self.view addSubview:self.zoom];
    self.liveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.liveButton setTitle:@"◎ 实况" forState:UIControlStateNormal];
    self.liveButton.tintColor = UIColor.whiteColor;
    [self.liveButton addTarget:self action:@selector(playLive) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.liveButton];
    self.loadingMask = [[FNPreviewLoadingView alloc] initWithFrame:self.view.bounds];
    self.loadingMask.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.loadingMask];
    self.check = [[UIBarButtonItem alloc] initWithTitle:@"○"
                                                  style:UIBarButtonItemStylePlain
                                                 target:self
                                                 action:@selector(toggle)];
    self.navigationItem.rightBarButtonItem = self.check;
    for (NSNumber *direction in
         @[ @(UISwipeGestureRecognizerDirectionLeft), @(UISwipeGestureRecognizerDirectionRight) ]) {
        UISwipeGestureRecognizer *g = [[UISwipeGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(swipe:)];
        g.direction = direction.unsignedIntegerValue;
        g.delegate = self;
        [self.view addGestureRecognizer:g];
        [self.zoom.panGestureRecognizer requireGestureRecognizerToFail:g];
    }
    [self display];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    self.previewVisible = YES;
    [self restorePreviewAudio];
    [self updateControls];
}
#ifdef FN_VIDEO_PROBE
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.videoProbeTimer invalidate];
    __weak typeof(self) weak=self;
    self.videoProbeTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        FNPreviewController *s=weak;
        if (!s) { [t invalidate]; return; }
        AVPlayerItem *item=s.player.player.currentItem;
        NSMutableArray *tracks=[NSMutableArray array];
        for (AVPlayerItemTrack *track in item.tracks) {
            NSMutableArray *formats=[NSMutableArray array];
            for (id description in track.assetTrack.formatDescriptions) {
                FourCharCode code=CMFormatDescriptionGetMediaSubType((__bridge CMFormatDescriptionRef)description);
                char bytes[]={(char)(code>>24),(char)(code>>16),(char)(code>>8),(char)code,0};
                [formats addObject:[NSString stringWithUTF8String:bytes] ?: @"unknown"];
            }
            [tracks addObject:@{@"type":track.assetTrack.mediaType ?: @"",@"enabled":@(track.enabled),@"formats":formats}];
        }
        NSDictionary *report=@{@"status":@(item.status),@"time":@(isfinite(CMTimeGetSeconds(item.currentTime)) ? CMTimeGetSeconds(item.currentTime) : 0),
            @"presentation":NSStringFromCGSize(item.presentationSize),@"readyForDisplay":@(s.player.readyForDisplay),
            @"rootBounds":NSStringFromCGRect(s.view.bounds),@"playerFrame":NSStringFromCGRect(s.player.view.frame),
            @"playerBounds":NSStringFromCGRect(s.player.view.bounds),@"playerHidden":@(s.player.view.hidden),@"tracks":tracks,
            @"maskHidden":@(s.loadingMask.hidden),@"error":item.error.localizedDescription ?: @""};
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
            writeToURL:[FNCacheDirectory() URLByAppendingPathComponent:@"video-render-probe.json"] atomically:YES];
    }];
}
#endif
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.liveButton.frame =
        CGRectMake(18, self.view.bounds.size.height - self.view.safeAreaInsets.bottom - 55, 100, 40);
    self.player.view.frame = self.zoom.frame;
    self.gif.frame = self.zoom.frame;
    [self.view bringSubviewToFront:self.liveButton];
    self.loadingMask.frame = self.view.bounds;
    [self.view bringSubviewToFront:self.loadingMask];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.previewVisible = NO;
#ifdef FN_VIDEO_PROBE
    [self.videoProbeTimer invalidate];
#endif
    [self suspendPreviewAudio];
    if (self.isMovingFromParentViewController || self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        self.generation++;
        [self stopStreamPreview];
        [self cancelLoading];
        for (FNTransfer *task in self.tasks) [task cancel];
    }
}
- (void)dealloc {
#ifdef FN_VIDEO_PROBE
    [self.videoProbeTimer invalidate];
#endif
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.streamTimer invalidate];
    [self.loadingTimer invalidate];
    [self.player.player pause];
    [self.audio end];
    [self.player.player replaceCurrentItemWithPlayerItem:nil];
    if (self.previewFile)
        [NSFileManager.defaultManager removeItemAtURL:self.previewFile error:nil];
    for (FNTransfer *t in self.tasks)
        [t cancel];
}
- (void)suspendPreviewAudio {
    [self.player.player pause];
    [self.audio end];
}
- (BOOL)preparePreviewAudio {
    NSError *error = nil;
    if ([self.audio begin:&error]) return YES;
    FNAlert(self, [NSString stringWithFormat:@"预览声音启动失败：%@", error.localizedDescription ?: @"系统音频暂不可用，请稍后重试。"]);
    return NO;
}
- (void)restorePreviewAudio {
    if (self.previewVisible && self.player) [self preparePreviewAudio];
}
- (void)playPreview {
    if (!self.previewVisible || ![self preparePreviewAudio]) return;
    [self.player.player play];
}
- (void)stopStreamPreview {
    [self.streamTimer invalidate]; self.streamTimer = nil;
}
- (void)streamFailed:(NSError *)error generation:(NSUInteger)generation ticket:(NSUInteger)ticket {
    if (generation != self.generation) return;
    [self stopStreamPreview];
    [self suspendPreviewAudio];
    [self finishLoading:ticket];
    self.player.view.hidden = YES;
    self.zoom.hidden = NO;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"原视频暂时无法流式播放"
        message:[NSString stringWithFormat:@"%@\n可完整下载后再预览。", error.localizedDescription ?: @"视频读取或播放失败。"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"完整下载后预览" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        if (generation != self.generation) return;
        self.localVideoID=self.photos[self.index][@"id"];
        [self display];
    }]];
    if (self.previewVisible && !self.presentedViewController) [self presentViewController:alert animated:YES completion:nil];
}
- (void)beginStreamPhoto:(NSDictionary *)photo generation:(NSUInteger)generation ticket:(NSUInteger)ticket {
    self.liveButton.hidden=YES;
    [self.loadingMask showTitle:@"正在缓冲原视频"];
    NSError *error=nil;
    NSDictionary *configuration=[FNClient.shared originalVideoPlaybackConfiguration:FNMediaURL(photo,YES) error:&error];
    if (!configuration) { [self streamFailed:error generation:generation ticket:ticket]; return; }
    NSUInteger nasGeneration=FNClient.shared.generation;
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:configuration[@"url"] options:@{AVURLAssetHTTPCookiesKey:configuration[@"cookies"]}];
    AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:asset];
    item.preferredForwardBufferDuration=2;
    [self.player.player pause];
    [self.player.view removeFromSuperview];
    [self.player removeFromParentViewController];
    self.player=[AVPlayerViewController new];
    self.player.player=[AVPlayer playerWithPlayerItem:item];
    self.player.player.muted=NO; self.player.player.volume=1;
    self.player.showsPlaybackControls=YES;
    self.player.view.frame=self.zoom.frame;
    self.player.view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self addChildViewController:self.player];
    [self.view insertSubview:self.player.view aboveSubview:self.zoom];
    [self.player didMoveToParentViewController:self];
    self.zoom.hidden=YES;
    self.title=[NSString stringWithFormat:@"%ld / %lu · 原视频",(long)self.index+1,(unsigned long)self.photos.count];
    [self playPreview];
    __weak typeof(self) weak=self;
    __block BOOL startedPromptly=NO;
    [self.streamTimer invalidate];
    self.streamTimer=[NSTimer timerWithTimeInterval:.2 repeats:YES block:^(NSTimer *timer) {
        FNPreviewController *current=weak;
        if (!current || generation!=current.generation) { [timer invalidate]; return; }
        if (FNClient.shared.generation!=nasGeneration) {
            [current streamFailed:FNError(@"NAS 会话已改变，请重新进入预览。") generation:generation ticket:ticket]; return;
        }
        AVPlayerItem *item=current.player.player.currentItem;
        if (item.status==AVPlayerItemStatusFailed) {
            if (!current.streamRetries++ && [photo[@"id"] isKindOfClass:NSNumber.class]) {
                [timer invalidate];
                CMTime position=current.player.player.currentTime;
                NSUInteger retryTicket=[current beginLoading:@"正在重新连接视频"];
                // API calls use the client's existing single-flight token renewal before retrying the media URL.
                [FNClient.shared photoDetails:@[photo[@"id"]] completion:^(NSDictionary *r,NSError *refreshError) {
                    FNPreviewController *visible=weak;
                    if (!visible || generation!=visible.generation || !visible.previewVisible) return;
                    if (refreshError) { [visible streamFailed:refreshError generation:generation ticket:retryTicket]; return; }
                    NSArray *rows=[r[@"list"] isKindOfClass:NSArray.class] ? r[@"list"] : nil;
                    NSDictionary *freshPhoto=[rows.firstObject isKindOfClass:NSDictionary.class] ? rows.firstObject : photo;
                    [visible beginStreamPhoto:freshPhoto generation:generation ticket:retryTicket];
                    if (CMTIME_IS_NUMERIC(position) && CMTimeGetSeconds(position)>0)
                        [visible.player.player seekToTime:position];
                }];
            } else [current streamFailed:item.error generation:generation ticket:ticket];
            return;
        }
        if (ticket==current.loadingTicket && !current.loadingMask.hidden) {
            double position=CMTimeGetSeconds(item.currentTime);
            position=isfinite(position) ? MAX(0,position) : 0;
            double buffered=0;
            for (NSValue *value in item.loadedTimeRanges) {
                CMTimeRange range=value.CMTimeRangeValue;
                double start=CMTimeGetSeconds(range.start),end=CMTimeGetSeconds(CMTimeRangeGetEnd(range));
                if (isfinite(start) && isfinite(end) && start<=position+.1 && end>position) buffered=MAX(buffered,end-position);
            }
            double duration=CMTimeGetSeconds(item.duration);
            [current.loadingMask updateBufferedSeconds:buffered target:isfinite(duration) && duration>position ? MIN(2,duration-position) : 2];
        }
        if (!startedPromptly && item.status==AVPlayerItemStatusReadyToPlay && !item.playbackBufferEmpty && current.previewVisible) {
            startedPromptly=YES; [current.player.player playImmediatelyAtRate:1];
        }
        if (item.status==AVPlayerItemStatusReadyToPlay && current.player.readyForDisplay) [current finishLoading:ticket];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.streamTimer forMode:NSRunLoopCommonModes];
}
- (void)cancelLoading {
    self.loadingTicket++;
    [self.loadingTimer invalidate];
    self.loadingTimer = nil;
    self.loadingTask = nil;
    self.loadingMask.hidden = YES;
}
- (NSUInteger)beginLoading:(NSString *)title {
    [self cancelLoading];
    [self.loadingMask showTitle:title];
    return self.loadingTicket;
}
- (void)trackLoadingTask:(FNTransfer *)task ticket:(NSUInteger)ticket {
    if (!task || ticket != self.loadingTicket || self.loadingMask.hidden) return;
    self.loadingTask = task;
    __weak typeof(self) weak = self;
    self.loadingTimer = [NSTimer timerWithTimeInterval:.1 repeats:YES block:^(NSTimer *timer) {
        FNPreviewController *s = weak;
        if (!s || ticket != s.loadingTicket || s.loadingMask.hidden) { [timer invalidate]; return; }
        [s.loadingMask updateReceived:s.loadingTask.countOfBytesReceived
                            expected:s.loadingTask.countOfBytesExpectedToReceive];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.loadingTimer forMode:NSRunLoopCommonModes];
}
- (void)downloadFinished:(NSUInteger)ticket title:(NSString *)title {
    if (ticket != self.loadingTicket) return;
    [self.loadingTimer invalidate];
    self.loadingTimer = nil;
    self.loadingTask = nil;
    [self.loadingMask showOpening:title];
}
- (void)finishLoading:(NSUInteger)ticket {
    if (ticket == self.loadingTicket) [self cancelLoading];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if ([gesture isKindOfClass:UISwipeGestureRecognizer.class] && !self.zoom.hidden)
        return self.zoom.zoomScale <= 1.01 &&
            self.zoom.pinchGestureRecognizer.state != UIGestureRecognizerStateBegan &&
            self.zoom.pinchGestureRecognizer.state != UIGestureRecognizerStateChanged;
    return YES;
}
- (void)swipe:(UISwipeGestureRecognizer *)g {
    if (![self gestureRecognizerShouldBegin:g]) return;
    NSInteger i = self.index + (g.direction == UISwipeGestureRecognizerDirectionLeft ? 1 : -1);
    if (i < 0 || i >= (NSInteger)self.photos.count)
        return;
    self.index = i;
    [self display];
}
- (void)updateControls {
    NSDictionary *p = self.photos[self.index];
    NSUInteger i = Selected(self.selection, p);
    self.check.title = i == NSNotFound ? @"○" : [NSString stringWithFormat:@"✓ %lu", (unsigned long)i + 1];
    UIBarButtonItem *flex =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil
                                                      action:nil];
    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithTitle:OriginalTitle(self.selection.original, @[self.photos[self.index]])
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(original)],
        flex,
        [[UIBarButtonItem alloc]
            initWithTitle:[NSString
                              stringWithFormat:@"发送 (%lu)", (unsigned long)self.selection.photos.count]
                    style:UIBarButtonItemStyleDone
                   target:self
                   action:@selector(send)]
    ];
}
- (void)toggle {
    Toggle(self, self.selection, self.photos[self.index]);
    [self updateControls];
}
- (void)original {
    self.selection.original = !self.selection.original;
    [self updateControls];
}
- (void)send {
    if (!self.selection.photos.count && !Toggle(self, self.selection, self.photos[self.index]))
        return;
    if (self.sendSelection)
        self.sendSelection(self, self.selection.photos, self.selection.original);
}
- (void)display {
    NSUInteger gen = ++self.generation;
    self.streamRetries=0;
    [self stopStreamPreview];
    [self cancelLoading];
    for (FNTransfer *t in self.tasks)
        [t cancel];
    [self.tasks removeAllObjects];
    [self suspendPreviewAudio];
    [self.player.view removeFromSuperview];
    [self.player removeFromParentViewController];
    self.player = nil;
    if (self.previewFile)
        [NSFileManager.defaultManager removeItemAtURL:self.previewFile error:nil];
    self.previewFile = nil;
    [self.gif removeFromSuperview];
    self.gif = nil;
    self.zoom.hidden = NO;
    [self.zoom setImage:nil];
    NSDictionary *photo = self.photos[self.index];
    [self.zoom setImage:[Images() objectForKey:ThumbnailIdentity(FNMediaURL(photo, NO))]];
    self.title =
        [NSString stringWithFormat:@"%ld / %lu", (long)self.index + 1, (unsigned long)self.photos.count];
    self.liveButton.hidden = ![photo[@"isLive"] boolValue];
    self.liveButton.enabled = YES;
    [self.liveButton setTitle:@"◎ 实况" forState:UIControlStateNormal];
    [self updateControls];
    NSString *url = FNMediaURL(photo, YES);
    if (!url.length)
        url = FNMediaURL(photo, NO);
    __weak typeof(self) weak = self;
    NSUInteger ticket = [self beginLoading:FNIsVideo(photo) ? @"正在加载视频" : @"正在加载照片"];
    if (FNIsVideo(photo)) {
        if (![self.localVideoID isEqual:photo[@"id"]]) {
            [self beginStreamPhoto:photo generation:gen ticket:ticket];
            return;
        }
        NSString *extension = [photo[@"fileName"] pathExtension];
        NSURL *target = [FNCacheDirectory()
            URLByAppendingPathComponent:[NSUUID.UUID.UUIDString
                                            stringByAppendingPathExtension:extension.length ? extension
                                                                                            : @"mp4"]];
        self.previewFile = target;
        [self.liveButton setTitle:@"加载视频…" forState:UIControlStateNormal];
        self.liveButton.hidden = NO;
        self.liveButton.enabled = NO;
        FNTransfer *task = [[FNClient shared]
              download:url
                    to:target
            completion:^(NSError *error) {
                FNPreviewController *s = weak;
                if (!s || gen != s.generation) {
                    [NSFileManager.defaultManager removeItemAtURL:target error:nil];
                    return;
                }
                s.liveButton.hidden = YES;
                if (error) {
                    [s finishLoading:ticket];
                    FNAlert(s, error.localizedDescription);
                    return;
                }
                [s downloadFinished:ticket title:@"正在打开视频"];
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:target options:nil];
                [asset
                    loadValuesAsynchronouslyForKeys:@[ @"playable" ]
                                  completionHandler:^{
                                      dispatch_async(dispatch_get_main_queue(), ^{
                                          if (gen != s.generation)
                                              return;
                                          if (!asset.playable) {
                                              [s finishLoading:ticket];
                                              NSError *readError = nil;
                                              [asset statusOfValueForKey:@"playable" error:&readError];
#if FN_DEVICE_TESTS
                                              NSMutableDictionary *report = [NSMutableDictionary dictionary];
                                              NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:target.path error:nil];
                                              report[@"bytes"] = attrs[NSFileSize] ?: @0;
                                              report[@"permissions"] = attrs[NSFilePosixPermissions] ?: @0;
                                              report[@"extension"] = target.pathExtension ?: @"";
                                              NSData *bytes = [NSData dataWithContentsOfURL:target options:NSDataReadingMappedIfSafe error:nil];
                                              report[@"appReadableBytes"] = @(bytes.length);
                                              report[@"header"] = [[bytes subdataWithRange:NSMakeRange(0, MIN(32, bytes.length))] description] ?: @"";
                                              report[@"error"] = readError.description ?: @"nil";
                                              report[@"videoURLAvailable"] = @([photo[@"additional"][@"thumbnail"][@"videoUrl"] length] > 0);
                                              report[@"videoURLSameAsOriginal"] = @([photo[@"additional"][@"thumbnail"][@"videoUrl"] isEqual:url]);
                                              NSURL *sample = [FNCacheDirectory() URLByAppendingPathComponent:@"asset-selftest/failed-preview.mov"];
                                              [NSFileManager.defaultManager removeItemAtURL:sample error:nil];
                                              [NSFileManager.defaultManager copyItemAtURL:target toURL:sample error:nil];
                                              [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
                                                writeToURL:[FNCacheDirectory() URLByAppendingPathComponent:@"video-read.json"] atomically:YES];
#endif
                                              FNAlert(
                                                  s,
                                                  readError ? [NSString stringWithFormat:@"视频读取失败：%@", readError.localizedDescription]
                                                            : @"当前 iOS 无法播放此视频格式，需要兼容的编码或 NAS 转码。");
                                              return;
                                          }
                                          s.player = [AVPlayerViewController new];
                                          s.player.player = [AVPlayer
                                              playerWithPlayerItem:[AVPlayerItem playerItemWithAsset:asset]];
                                          s.player.player.muted = NO;
                                          s.player.player.volume = 1.0;
                                          s.player.showsPlaybackControls = YES;
                                          s.player.view.frame = s.zoom.frame;
                                          s.player.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                                                           UIViewAutoresizingFlexibleHeight;
                                          [s addChildViewController:s.player];
                                          [s.view insertSubview:s.player.view aboveSubview:s.zoom];
                                          [s.player didMoveToParentViewController:s];
                                          s.zoom.hidden = YES;
                                          [s playPreview];
                                          [s finishLoading:ticket];
                                      });
                                  }];
            }];
        if (task)
            [self.tasks addObject:task];
        [self trackLoadingTask:task ticket:ticket];
    } else if ([[[photo[@"fileName"] description] pathExtension].lowercaseString isEqual:@"gif"]) {
        NSURL *target = [FNCacheDirectory()
            URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"gif"]];
        self.previewFile = target;
        FNTransfer *t =
            [[FNClient shared] download:url
                                     to:target
                             completion:^(NSError *e) {
                                 FNPreviewController *s = weak;
                                 if (!s || gen != s.generation) {
                                     [NSFileManager.defaultManager removeItemAtURL:target error:nil];
                                     return;
                                 }
                                 if (e) {
                                     [s finishLoading:ticket];
                                     FNAlert(s, e.localizedDescription);
                                     return;
                                 }
                                 [s downloadFinished:ticket title:@"正在打开动图"];
                                 WKWebViewConfiguration *config = [WKWebViewConfiguration new];
                                 config.defaultWebpagePreferences.allowsContentJavaScript = NO;
                                 config.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
                                 s.gif = [[WKWebView alloc] initWithFrame:s.zoom.frame configuration:config];
                                 s.gif.navigationDelegate = s;
                                 s.gifLoadingTicket = ticket;
                                 s.gif.opaque = NO;
                                 s.gif.backgroundColor = UIColor.blackColor;
                                 s.gif.scrollView.backgroundColor = UIColor.blackColor;
                                 [s.view insertSubview:s.gif aboveSubview:s.zoom];
                                 s.zoom.hidden = YES;
                                 [s.gif loadFileURL:target allowingReadAccessToURL:target];
                             }];
        if (t)
            [self.tasks addObject:t];
        [self trackLoadingTask:t ticket:ticket];
    } else {
        FNTransfer *t =
            [[FNClient shared] media:url
                          completion:^(NSData *data, NSError *e) {
                              FNPreviewController *s = weak;
                              if (!s || gen != s.generation)
                                  return;
                              if (e) {
                                  [s finishLoading:ticket];
                                  FNAlert(s, e.localizedDescription);
                                  return;
                              }
                              [s downloadFinished:ticket title:@"正在显示照片"];
                              dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                                  UIImage *im = Decode(data, 2048);
                                  dispatch_async(dispatch_get_main_queue(), ^{
                                      if (gen == s.generation) {
                                          [s.zoom setImage:im];
                                          [s finishLoading:ticket];
                                          if (!im) FNAlert(s, @"预览图片无法解码，请重新选择。");
                                      }
                                  });
                              });
                          }];
        if (t)
            [self.tasks addObject:t];
        [self trackLoadingTask:t ticket:ticket];
    }
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (webView == self.gif) [self finishLoading:self.gifLoadingTicket];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (webView != self.gif) return;
    [self finishLoading:self.gifLoadingTicket];
    FNAlert(self, error.localizedDescription);
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailNavigation:navigation withError:error];
}
- (void)playLive {
    if (self.player) {
        BOOL play = self.player.player.rate == 0;
        if (play) {
            [self.player.player seekToTime:kCMTimeZero];
            [self playPreview];
        } else
            [self.player.player pause];
        return;
    }
    NSDictionary *p = self.photos[self.index];
    NSString *video = p[@"additional"][@"thumbnail"][@"videoUrl"];
    if (![video isKindOfClass:NSString.class] || !video.length) {
        FNAlert(self, @"NAS 没有返回实况视频地址，无法预览。");
        return;
    }
    NSUInteger gen = self.generation;
    NSUInteger ticket = [self beginLoading:@"正在加载实况"];
    self.liveButton.enabled = NO;
    [self.liveButton setTitle:@"加载实况…" forState:UIControlStateNormal];
    __weak typeof(self) weak = self;
    NSURL *target = [FNCacheDirectory()
        URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"mov"]];
    self.previewFile = target;
    FNTransfer *t = [[FNClient shared] download:video
                                                   to:target
                                           completion:^(NSError *e) {
                                               FNPreviewController *s = weak;
                                               if (!s || gen != s.generation) {
                                                   [NSFileManager.defaultManager removeItemAtURL:target error:nil];
                                                   return;
                                               }
                                               s.liveButton.enabled = YES;
                                               [s.liveButton setTitle:@"◎ 实况"
                                                             forState:UIControlStateNormal];
                                               if (e) {
                                                   [s finishLoading:ticket];
                                                   FNAlert(s, e.localizedDescription);
                                                   return;
                                               }
                                               [s downloadFinished:ticket title:@"正在打开实况"];
                                               s.player = [AVPlayerViewController new];
                                               s.player.showsPlaybackControls = NO;
                                               s.player.player = [AVPlayer playerWithURL:target];
                                               s.player.player.muted = NO;
                                               s.player.player.volume = 1.0;
                                               s.player.videoGravity = AVLayerVideoGravityResizeAspect;
                                               s.player.view.frame = s.zoom.frame;
                                               [s addChildViewController:s.player];
                                               [s.view insertSubview:s.player.view aboveSubview:s.zoom];
                                               [s.player didMoveToParentViewController:s];
                                          s.zoom.hidden = YES;
                                               [s playPreview];
                                               [s finishLoading:ticket];
                                           }];
    if (t)
        [self.tasks addObject:t];
    [self trackLoadingTask:t ticket:ticket];
}
@end

@interface FNBrowserController () <UICollectionViewDelegateFlowLayout, UICollectionViewDataSource>
@property(nonatomic) UICollectionView *collectionView;
@property(nonatomic) NSMutableArray<NSDictionary *> *photos;
@property(nonatomic) NSMutableArray<NSDictionary *> *albums;
@property(nonatomic) FNPhotoPager *pager;
@property(nonatomic) UISegmentedControl *segment;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL browsingFromDate;
@property(nonatomic) BOOL albumsMore;
@property(nonatomic) NSUInteger albumOffset;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) UIRefreshControl *refresh;
@property(nonatomic) UILabel *status;
@property(nonatomic) FNTimelineScrubber *scrubber;
@property(nonatomic) UIButton *searchButton;
@property(nonatomic) UIButton *clearSearchButton;
@property(nonatomic, weak) UITextField *queryInput;
@property(nonatomic, copy) NSString *searchKeyword;
@end
#ifdef FN_UI_DIAGNOSTICS
#import "../tests/BrowserProbe.inc"
#endif
@implementation FNBrowserController
- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.selection)
        self.selection = [FNSelection new];
    self.photos = [NSMutableArray array];
    self.albums = [NSMutableArray array];
    self.title = self.title ?: @"飞牛相册";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 2;
    layout.minimumLineSpacing = 2;
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.delegate = self;
    self.collectionView.dataSource = self;
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.collectionView];
    self.collectionView.backgroundColor = UIColor.systemBackgroundColor;
    self.collectionView.delaysContentTouches = NO;
    [self.collectionView registerClass:FNCell.class forCellWithReuseIdentifier:@"photo"];
    self.refresh = [UIRefreshControl new];
    [self.refresh addTarget:self
                     action:@selector(refreshRequested)
           forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = self.refresh;
    self.status = [UILabel new];
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.textColor = UIColor.secondaryLabelColor;
    self.status.userInteractionEnabled = YES;
    [self.status addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(reload)]];
    self.collectionView.backgroundView = self.status;
    if (!self.albumID && !self.queryFilters.count) {
        self.segment = [[UISegmentedControl alloc] initWithItems:@[ @"照片", @"相册", @"收藏", @"分类" ]];
        self.segment.selectedSegmentIndex = 0;
        [self.segment addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
        self.navigationItem.titleView = self.segment;
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                          target:self
                                                          action:@selector(close)];
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                             style:UIBarButtonItemStylePlain
                                            target:self
                                            action:@selector(settings)];
    }
    self.scrubber = [FNTimelineScrubber new];
    self.scrubber.hidden = YES;
    [self.scrubber addTarget:self action:@selector(scrubChanged) forControlEvents:UIControlEventValueChanged];
    [self.scrubber addTarget:self action:@selector(scrubEnded) forControlEvents:UIControlEventTouchUpInside];
    [self.scrubber addTarget:self
                      action:@selector(updateTimeline)
            forControlEvents:UIControlEventTouchCancel];
    // Keep interactive overlays outside the scroll view's pan recognizer hierarchy.
    [self.view addSubview:self.scrubber];
    if (!self.albumID && !self.queryFilters.count) {
        self.searchButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.searchButton.backgroundColor = UIColor.secondarySystemBackgroundColor;
        self.searchButton.layer.cornerRadius = 10;
        self.searchButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        self.searchButton.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
        [self.searchButton setImage:[UIImage systemImageNamed:@"magnifyingglass"]
                           forState:UIControlStateNormal];
        [self.searchButton addTarget:self
                              action:@selector(openSearch)
                    forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.searchButton];
        self.clearSearchButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.clearSearchButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"]
                                forState:UIControlStateNormal];
        self.clearSearchButton.accessibilityLabel = @"清除 AI 搜索，返回照片列表";
        [self.clearSearchButton addTarget:self
                                   action:@selector(clearSearch)
                         forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.clearSearchButton];
        [self updateSearchTitle];
    }
    self.status.text = @"正在选择 NAS 访问地址…";
    __weak typeof(self) weak = self;
    FNPrepareNetworkRoute(^(NSDictionary *route, NSError *routeError) {
        if (!weak) return;
        if (routeError) {
            weak.status.text = [routeError.localizedDescription stringByAppendingString:@"\n请到右上角设置检查内外网访问配置。"];
            return;
        }
        [[FNClient shared] restore:^(NSDictionary *r, NSError *e) {
            if (!weak) return;
            if ([FNClient shared].authenticated) {
                [weak reload];
                NSString *warning = r[@"warning"] ?: route[@"warning"];
                if (warning) FNAlert(weak,warning);
            } else if (e) {
                weak.status.text = [e.localizedDescription stringByAppendingString:@"\n点击重试，或点右上角设置重新登录。"];
            } else [weak settings];
        }];
    });
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    [self controls];
    [self.collectionView reloadData];
}
#ifdef FN_UI_DIAGNOSTICS
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    __weak typeof(self) weak = self;
    for (NSUInteger i = 0; i < 180; i++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (weak)
                FNProbeBrowser(weak);
        });
}
#endif
- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self.collectionView.collectionViewLayout invalidateLayout];
}
- (void)controls {
    UIBarButtonItem *flex =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil
                                                      action:nil];
    UIBarButtonItem *send = [[UIBarButtonItem alloc]
        initWithTitle:[NSString stringWithFormat:@"发送 (%lu)", (unsigned long)self.selection.photos.count]
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(send)];
    send.enabled = self.selection.photos.count > 0;
    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithTitle:OriginalTitle(self.selection.original, self.selection.photos)
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(original)],
        flex, send
    ];
}
- (void)original {
    self.selection.original = !self.selection.original;
    [self controls];
}
- (void)send {
    [self.view endEditing:YES];
    if (self.sendSelection)
        self.sendSelection(self, self.selection.photos, self.selection.original);
}
- (void)close {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}
- (void)settings {
    FNLoginController *login = [FNLoginController new];
    __weak typeof(self) weak = self;
    login.onLogin = ^{
        [weak.selection.photos removeAllObjects];
        [Images() removeAllObjects];
        [weak reload];
    };
    [self.navigationController pushViewController:login animated:YES];
}
- (BOOL)showCategories {
    return !self.searchKeyword.length && !self.albumID && !self.queryFilters.count &&
           self.segment.selectedSegmentIndex == 3;
}
- (BOOL)showDirectories {
    return [self showAlbums] || [self showCategories];
}
- (BOOL)showAlbums {
    return !self.searchKeyword.length && !self.albumID && !self.queryFilters.count &&
           self.segment.selectedSegmentIndex == 1;
}
- (void)reload {
    self.browsingFromDate = NO;
    self.refresh.enabled = YES;
    if (![FNClient shared].authenticated) {
        [self.refresh endRefreshing];
        if (self.loading)
            return;
        self.loading = YES;
        self.status.text = @"正在连接 NAS…";
        [[FNClient shared] restore:^(NSDictionary *r, NSError *e) {
            self.loading = NO;
            if ([FNClient shared].authenticated)
                [self reload];
            else {
                self.status.text = e ? e.localizedDescription : @"请点击设置登录 NAS。";
                [self.refresh endRefreshing];
            }
        }];
        return;
    }
    self.generation++;
    self.loading = NO;
    self.segment.enabled = !self.searchKeyword.length;
    self.scrubber.hidden = YES;
    self.pager = [FNPhotoPager new];
    self.pager.searchKeyword = self.searchKeyword;
    self.pager.queryFilters = self.queryFilters;
    self.pager.albumID = self.albumID;
    self.pager.favorites = self.segment.selectedSegmentIndex == 2;
    self.albumOffset = 0;
    self.albumsMore = YES;
    [self.photos removeAllObjects];
    [self.albums removeAllObjects];
    if ([self showCategories]) {
        [self.albums addObjectsFromArray:@[
            @{@"albumName" : @"人物", @"kind" : @"person", @"symbol" : @"person.2.fill"},
            @{@"albumName" : @"地点", @"kind" : @"location", @"symbol" : @"mappin.and.ellipse"},
            @{@"albumName" : @"媒体类型", @"kind" : @"media", @"symbol" : @"photo.on.rectangle.angled"}
        ]];
        self.refresh.enabled = NO;
        [self.refresh endRefreshing];
        self.status.text = @"";
        [self.collectionView reloadData];
        return;
    }
    [self.collectionView reloadData];
    [self loadMore];
}
- (void)loadMore {
    if ([self showCategories])
        return;
    if (self.loading || ([self showAlbums] ? !self.albumsMore : !self.pager.hasNext))
        return;
    self.loading = YES;
    self.status.text = (self.photos.count || self.albums.count) ? @"" : @"正在读取相册…";
    NSUInteger gen = self.generation;
    if (self.searchKeyword.length && !self.photos.count)
        self.status.text = @"正在由 NAS 进行 AI 搜索…";
    if ([self showAlbums]) {
        [[FNClient shared] get:@"/p/api/v1/album/list"
                        params:@{
                            @"sort_by" : @"date_time",
                            @"sort_direction" : @"desc",
                            @"offset" : @(self.albumOffset),
                            @"limit" : @60
                        }
                    completion:^(NSDictionary *r, NSError *e) {
                        if (gen != self.generation)
                            return;
                        NSArray *list = r[@"list"];
                        if (!e && ![list isKindOfClass:NSArray.class])
                            e = FNError(@"相册列表格式不兼容。");
                        if (!e) {
                            [self.albums addObjectsFromArray:list];
                            self.albumOffset += list.count;
                            self.albumsMore =
                                r[@"hasNext"]
                                    ? [r[@"hasNext"] boolValue]
                                    : (r[@"total"] ? self.albumOffset < [r[@"total"] unsignedIntegerValue]
                                                   : list.count == 60);
                        }
                        [self loaded:e];
                    }];
    } else {
        [self.pager next:^(NSArray *rows, NSError *e) {
            if (gen != self.generation)
                return;
            if (!e)
                for (NSDictionary *p in rows)
                    if (FNIsSupportedMedia(p) && PhotoID(p).length)
                        [self.photos addObject:p];
            [self loaded:e];
        }];
    }
}
- (void)refreshRequested {
    if (self.browsingFromDate) {
        [self.refresh endRefreshing];
        [self loadNewer];
    } else
        [self reload];
}
- (void)loadNewer {
    if (self.loading || !self.browsingFromDate || !self.pager.hasPrevious)
        return;
    self.loading = YES;
    NSUInteger generation = self.generation;
    [self.pager previous:^(NSArray *rows, NSError *error) {
        if (generation != self.generation)
            return;
        NSMutableArray *prefix = [NSMutableArray array];
        NSMutableSet *ids = [NSMutableSet set];
        for (NSDictionary *photo in self.photos)
            [ids addObject:PhotoID(photo)];
        if (!error)
            for (NSDictionary *photo in rows) {
                NSString *identity = PhotoID(photo);
                if (FNIsSupportedMedia(photo) && identity.length && ![ids containsObject:identity]) {
                    [prefix addObject:photo];
                    [ids addObject:identity];
                }
            }
        // Capture the current anchor at response time: the user may have scrolled during download.
        NSIndexPath *anchor = [[self.collectionView.indexPathsForVisibleItems
            sortedArrayUsingSelector:@selector(compare:)] firstObject];
        UICollectionViewLayoutAttributes *before =
            anchor ? [self.collectionView layoutAttributesForItemAtIndexPath:anchor] : nil;
        CGFloat relativeY = before.frame.origin.y - self.collectionView.contentOffset.y;
        if (prefix.count) {
            [self.photos insertObjects:prefix
                             atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, prefix.count)]];
            [self.collectionView reloadData];
            [self.collectionView layoutIfNeeded];
            if (before) {
                NSIndexPath *shifted = [NSIndexPath indexPathForItem:anchor.item + prefix.count inSection:0];
                UICollectionViewLayoutAttributes *after =
                    [self.collectionView layoutAttributesForItemAtIndexPath:shifted];
                if (after)
                    [self.collectionView setContentOffset:CGPointMake(self.collectionView.contentOffset.x,
                                                                      after.frame.origin.y - relativeY)
                                                 animated:NO];
            }
        }
        self.loading = NO;
        [self.refresh endRefreshing];
        [self updateTimeline];
        if (error)
            FNAlert(self, error.localizedDescription);
        else if (!prefix.count && self.pager.hasPrevious)
            [self loadNewer];
    }];
}
- (void)loaded:(NSError *)error {
    self.loading = NO;
    [self.refresh endRefreshing];
    self.status.text = error ? [error.localizedDescription stringByAppendingString:@"\n点击空白处重试。"]
                             : ((self.photos.count || self.albums.count) ? @"" : @"暂无照片或视频");
    if (!error && self.searchKeyword.length && !self.photos.count)
        self.status.text = @"没有找到匹配的图片，换一种描述再试试。";
    [self.collectionView reloadData];
    [self updateTimeline];
    if (error && (self.photos.count || self.albums.count))
        FNAlert(self, error.localizedDescription);
    if (!error && ![self showDirectories] && !self.photos.count && self.pager.hasNext)
        [self loadMore];
}
- (void)updateSearchTitle {
    [self.searchButton setTitle:self.searchKeyword.length ? [@"  " stringByAppendingString:self.searchKeyword]
                                                          : @"  AI 搜索全部照片，例如：海边日落"
                       forState:UIControlStateNormal];
    self.searchButton.accessibilityLabel = self.searchKeyword.length
                                               ? [@"AI 搜索：" stringByAppendingString:self.searchKeyword]
                                               : @"AI 搜索全部照片";
    self.clearSearchButton.hidden = !self.searchKeyword.length;
    [self.view setNeedsLayout];
}
- (void)openSearch {
    if (self.presentedViewController)
        return;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"AI 搜索照片"
                                            message:@"描述想找的照片，例如：海边日落。搜索由当前 NAS 完成。"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"输入图片描述";
        field.text = self.searchKeyword ?: @"";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.returnKeyType = UIReturnKeyDone;
    }];
    self.queryInput = alert.textFields.firstObject;
    __weak typeof(self) weak = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UITextField *input = alert.textFields.firstObject;
    [alert addAction:[UIAlertAction actionWithTitle:@"搜索"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                [weak submitSearch:input.text ?: @""];
                                            }]];
    [self presentViewController:alert
                       animated:YES
                     completion:^{
                         [weak.queryInput becomeFirstResponder];
                     }];
}
- (void)submitSearch:(NSString *)text {
    self.searchKeyword =
        [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self updateSearchTitle];
    [self reload];
    [self scrollToTop];
}
- (void)clearSearch {
    self.searchKeyword = nil;
    [self updateSearchTitle];
    [self reload];
    [self scrollToTop];
}
- (void)scrollToTop {
    [self.collectionView setContentOffset:CGPointMake(-self.collectionView.adjustedContentInset.left,
                                                      -self.collectionView.adjustedContentInset.top)
                                 animated:NO];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect area = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    CGFloat searchHeight = self.searchButton ? MIN(56, area.size.height) : 0;
    CGFloat clearWidth = self.searchKeyword.length ? 44 : 0;
    self.searchButton.frame =
        CGRectMake(area.origin.x + 8, area.origin.y + 6, MAX(0, area.size.width - 16 - clearWidth),
                   MAX(0, searchHeight - 12));
    self.clearSearchButton.frame = CGRectMake(CGRectGetMaxX(area) - 8 - clearWidth, area.origin.y + 6,
                                              clearWidth, MAX(0, searchHeight - 12));
    CGRect grid = CGRectMake(area.origin.x, area.origin.y + searchHeight, area.size.width,
                             MAX(0, area.size.height - searchHeight));
    if (!CGSizeEqualToSize(self.collectionView.bounds.size, grid.size))
        [self.collectionView.collectionViewLayout invalidateLayout];
    self.collectionView.frame = grid;
    [self positionScrubber];
}
- (void)positionScrubber {
    CGRect frame = self.collectionView.frame;
    self.scrubber.frame =
        CGRectMake(CGRectGetMaxX(frame) - 48, CGRectGetMinY(frame) + 12, 48, MAX(0, frame.size.height - 24));
    [self.view bringSubviewToFront:self.scrubber];
}
- (NSUInteger)scrubDay {
    return self.pager.days.count > 1
               ? (NSUInteger)llround(self.scrubber.fraction * (self.pager.days.count - 1))
               : 0;
}
- (void)scrubChanged {
    NSUInteger i = [self scrubDay];
    if (i >= self.pager.days.count)
        return;
    NSDictionary *day = self.pager.days[i];
    self.scrubber.dateText = [NSString stringWithFormat:@"%04ld年%02ld月%02ld日", [day[@"year"] longValue],
                                                        [day[@"month"] longValue], [day[@"day"] longValue]];
}
- (void)scrubEnded {
    if (self.scrubber.hidden || !self.pager.days.count)
        return;
    self.generation++; // Discard old page callbacks even when an earlier request is still running.
    self.browsingFromDate = YES;
    [self.refresh endRefreshing];
    self.refresh.enabled = NO;
    self.pager = [self.pager pagerStartingAtDay:[self scrubDay]];
    self.loading = NO;
    [self.photos removeAllObjects];
    [self.collectionView reloadData];
    [self scrollToTop];
    [self loadMore];
}
- (void)updateTimeline {
    self.scrubber.hidden = self.searchKeyword.length || [self showDirectories] || !self.pager.days.count;
    self.collectionView.showsVerticalScrollIndicator = self.scrubber.hidden;
    if (self.scrubber.hidden || self.scrubber.tracking)
        return;
    NSArray *visible =
        [self.collectionView.indexPathsForVisibleItems sortedArrayUsingSelector:@selector(compare:)];
    NSIndexPath *first = visible.firstObject;
    if (first && first.item < self.photos.count) {
        NSDictionary *photo = self.photos[first.item];
        NSUInteger i = 0;
        if ([photo[@"fn_dayIndex"] isKindOfClass:NSNumber.class])
            i = [photo[@"fn_dayIndex"] unsignedIntegerValue];
        else {
            NSString *date = [photo[@"photoDateTime"] isKindOfClass:NSString.class] ? photo[@"photoDateTime"]
                                                                                    : photo[@"dateTime"];
            if (![date isKindOfClass:NSString.class] || date.length < 10)
                return;
            NSString *prefix = [[date substringToIndex:10] stringByReplacingOccurrencesOfString:@":"
                                                                                     withString:@"-"];
            for (NSDictionary *day in self.pager.days) {
                NSString *key =
                    [NSString stringWithFormat:@"%04ld-%02ld-%02ld", [day[@"year"] longValue],
                                               [day[@"month"] longValue], [day[@"day"] longValue]];
                if ([prefix isEqual:key])
                    break;
                i++;
            }
        }
        if (i < self.pager.days.count)
            self.scrubber.fraction = self.pager.days.count > 1 ? (CGFloat)i / (self.pager.days.count - 1) : 0;
    }
    [self scrubChanged];
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self positionScrubber];
    [self updateTimeline];
    if (scrollView.dragging || scrollView.decelerating)
        [self.scrubber showDate];
    if ((scrollView.dragging || scrollView.decelerating) && scrollView.contentOffset.y < 240 &&
        !self.scrubber.tracking)
        [self loadNewer];
}
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return [self showDirectories] ? self.albums.count : self.photos.count;
}
- (CGSize)collectionView:(UICollectionView *)cv
                    layout:(UICollectionViewLayout *)layout
    sizeForItemAtIndexPath:(NSIndexPath *)path {
    CGFloat w = cv.bounds.size.width - cv.adjustedContentInset.left - cv.adjustedContentInset.right;
    NSInteger cols = MAX(3, (NSInteger)(w / 135));
    CGFloat side = floor((w - (cols - 1) * 2) / cols);
    return CGSizeMake(side, side);
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)path {
    FNCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"photo" forIndexPath:path];
    BOOL album = [self showDirectories];
    NSDictionary *p = album ? self.albums[path.item] : self.photos[path.item];
    NSString *url =
        album ? ([p[@"posterUrl"] isKindOfClass:NSString.class] ? p[@"posterUrl"] : @"") : FNMediaURL(p, NO);
    NSString *identity = ThumbnailIdentity(url);
    cell.identity = identity;
    cell.image.image =
        p[@"symbol"] ? [UIImage systemImageNamed:p[@"symbol"]] : [Images() objectForKey:identity];
    if (!cell.image.image && FNIsVideo(p) && !url.length)
        cell.image.image = [UIImage systemImageNamed:@"play.rectangle"];
    cell.image.tintColor = UIColor.systemGreenColor;
    cell.check.hidden = album;
    cell.duration.text = album ? @"" : FNVideoDurationText(p);
    cell.duration.hidden = !cell.duration.text.length;
    cell.duration.accessibilityLabel = [@"视频时长 " stringByAppendingString:cell.duration.text];
    [cell setNeedsLayout];
    cell.badge.text =
        album ? [p[@"albumName"] description]
              : (FNIsVideo(p)
                     ? @"▶ 视频"
                     : ([p[@"isLive"] boolValue]
                            ? @"◎ 实况"
                            : ([[[p[@"fileName"] description] pathExtension].lowercaseString isEqual:@"gif"]
                                   ? @" GIF"
                                   : @"")));
    if (!album) {
        NSUInteger i = Selected(self.selection, p);
        [cell.check setTitle:i == NSNotFound ? @"○" : [NSString stringWithFormat:@"%lu", (unsigned long)i + 1]
                    forState:UIControlStateNormal];
        cell.check.backgroundColor =
            i == NSNotFound ? [UIColor colorWithWhite:0 alpha:.35] : UIColor.systemGreenColor;
        cell.check.accessibilityLabel = @"勾选图片";
        __weak typeof(self) weak = self;
        cell.toggle = ^{
            Toggle(weak, weak.selection, p);
            [weak controls];
            [weak.collectionView reloadData];
        };
    }
    if (!cell.image.image && url.length) {
        __weak FNCell *weakCell = cell;
        cell.task = [[FNClient shared]
                 media:url
            completion:^(NSData *data, NSError *e) {
                if (e)
                    return;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    UIImage *image = Decode(data, 384);
                    if (image)
                        [Images() setObject:image
                                     forKey:identity
                                       cost:(NSUInteger)(image.size.width * image.size.height * 4)];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([weakCell.identity isEqual:identity])
                            weakCell.image.image = image;
                    });
                });
            }];
    }
    if (path.item + 10 >= ([self showDirectories] ? self.albums.count : self.photos.count))
        dispatch_async(dispatch_get_main_queue(), ^{
            [self loadMore];
        });
    return cell;
}
- (void)collectionView:(UICollectionView *)cv
    didEndDisplayingCell:(UICollectionViewCell *)cell
      forItemAtIndexPath:(NSIndexPath *)path {
    [((FNCell *)cell).task cancel];
}
- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)path {
    if ([self showCategories]) {
        NSDictionary *entry = self.albums[path.item];
        FNCategoriesController *categories =
            [[FNCategoriesController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        categories.kind = entry[@"kind"];
        categories.title = entry[@"albumName"];
        categories.selection = self.selection;
        categories.sendSelection = self.sendSelection;
        [self.navigationController pushViewController:categories animated:YES];
    } else if ([self showDirectories]) {
        NSDictionary *p = self.albums[path.item];
        FNBrowserController *child = [FNBrowserController new];
        child.albumID = [p[@"albumId"] description];
        child.title = [p[@"albumName"] description];
        child.selection = self.selection;
        child.sendSelection = self.sendSelection;
        [self.navigationController pushViewController:child animated:YES];
    } else {
        FNPreviewController *preview = [FNPreviewController new];
        preview.photos = [self.photos copy];
        preview.index = path.item;
        preview.selection = self.selection;
        preview.sendSelection = self.sendSelection;
        [self.navigationController pushViewController:preview animated:YES];
    }
}
@end

@interface FNLoginController ()
@property(nonatomic) UITextField *address;
@property(nonatomic) UITextField *user;
@property(nonatomic) UITextField *password;
@property(nonatomic) UISwitch *remember;
@property(nonatomic) UIButton *button;
@property(nonatomic) UILabel *info;
@end
@implementation FNLoginController
- (UITextField *)field:(NSString *)placeholder {
    UITextField *f = [UITextField new];
    f.placeholder = placeholder;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    [f.heightAnchor constraintEqualToConstant:44].active = YES;
    return f;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"飞牛相册设置";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.address = [self field:@"NAS IP 或域名，例如 192.168.2.126"];
    self.address.text = [FNClient shared].baseURL.absoluteString;
    self.address.keyboardType = UIKeyboardTypeURL;
    self.user = [self field:@"账号"];
    self.user.text = [FNClient shared].username;
    self.password = [self field:@"密码"];
    self.password.secureTextEntry = YES;
    self.password.textContentType = UITextContentTypePassword;
    self.remember = [UISwitch new];
    self.remember.on = YES;
    UILabel *label = [UILabel new];
    label.text = @"记住登录态";
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ label, self.remember ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionEqualSpacing;
    self.button = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.button setTitle:@"登录 NAS" forState:UIControlStateNormal];
    [self.button addTarget:self action:@selector(login) forControlEvents:UIControlEventTouchUpInside];
    UIButton *logout = [UIButton buttonWithType:UIButtonTypeSystem];
    [logout setTitle:@"退出 NAS 账号并清除登录态" forState:UIControlStateNormal];
    [logout addTarget:self action:@selector(logout) forControlEvents:UIControlEventTouchUpInside];
    self.info = [UILabel new];
    self.info.numberOfLines = 0;
    self.info.font = [UIFont systemFontOfSize:13];
    self.info.textColor = UIColor.secondaryLabelColor;
    self.info.text = [NSString
        stringWithFormat:
            @"只填 IP 自动使用 HTTP 5666。\n密码不会保存。重新签名或卸载应用可能需要重新登录。\n\n%@",
            FNCompatibilityReport()];
    UIButton *network = [UIButton buttonWithType:UIButtonTypeSystem];
    [network setTitle:@"内外网访问（按 Wi-Fi 切换）" forState:UIControlStateNormal];
    [network addTarget:self action:@selector(networkSettings) forControlEvents:UIControlEventTouchUpInside];
    UIButton *clean = [UIButton buttonWithType:UIButtonTypeSystem];
    [clean setTitle:@"清理已完成发送的缓存" forState:UIControlStateNormal];
    [clean addTarget:self action:@selector(clean) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.address, self.user, self.password, row, self.button, network, logout, clean, self.info
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new];
    scroll.frame = self.view.bounds;
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24]
    ]];
}
- (void)networkSettings {
    FNNetworkRoutingController *controller = [FNNetworkRoutingController new];
    __weak typeof(self) weak = self;
    controller.onChange = ^{
        weak.address.text = [FNClient shared].baseURL.absoluteString;
        if (weak.onLogin) weak.onLogin();
    };
    [self.navigationController pushViewController:controller animated:YES];
}
- (void)busy:(BOOL)busy {
    self.button.enabled = !busy;
    self.address.enabled = !busy;
    self.user.enabled = !busy;
    self.password.enabled = !busy;
    self.navigationItem.hidesBackButton = busy;
}
- (void)login {
    if (!self.user.text.length || !self.password.text.length) {
        FNAlert(self, @"请输入账号和密码。");
        return;
    }
    [self.view endEditing:YES];
    [self busy:YES];
    NSString *password = self.password.text;
    self.password.text = @"";
    [[FNClient shared] loginAddress:self.address.text
                               user:self.user.text
                           password:password
                           remember:self.remember.on
                         completion:^(NSDictionary *r, NSError *e) {
                             [self finish:r error:e];
                         }];
}
- (void)finish:(NSDictionary *)r error:(NSError *)error {
    [self busy:NO];
    if (error) {
        FNAlert(self, error.localizedDescription);
        return;
    }
    if ([r[@"twofa"] boolValue]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"两步验证"
                                                                   message:@"输入飞牛账号的六位验证码"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
            f.keyboardType = UIKeyboardTypeNumberPad;
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"验证"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                                [self busy:YES];
                                                [[FNClient shared] twoFactor:a.textFields.firstObject.text
                                                                  completion:^(NSDictionary *v, NSError *e) {
                                                                      [self finish:v error:e];
                                                                  }];
                                            }]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    if (self.onLogin)
        self.onLogin();
    [self.navigationController popViewControllerAnimated:YES];
    if (r[@"warning"])
        FNAlert(self.navigationController.topViewController, r[@"warning"]);
}
- (void)clean {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"确认微信已完成发送？"
                         message:
                             @"请先确认所有照片已发送成功，且无需重试。清理会移除插件缓存的原图和实况视频。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"已完成发送，清理"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *action) {
                                            NSURL *dir = FNCacheDirectory();
                                            for (NSURL *item in
                                                 [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir
                                                                             includingPropertiesForKeys:nil
                                                                                                options:0
                                                                                                  error:nil])
                                                if (![item.lastPathComponent isEqual:@"runtime.json"])
                                                    [NSFileManager.defaultManager removeItemAtURL:item
                                                                                            error:nil];
                                            [Images() removeAllObjects];
                                        }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)logout {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"退出飞牛账号？"
                                                               message:@"将清除该插件保存的 NAS 登录态。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"退出账号"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *action) {
                                            [[FNClient shared] logout];
                                            [Images() removeAllObjects];
                                            if (self.onLogin)
                                                self.onLogin();
                                            self.info.text = @"已退出 NAS。可重新输入账号登录。";
                                        }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end
