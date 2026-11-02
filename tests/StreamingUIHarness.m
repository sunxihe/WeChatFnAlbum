// Synthetic original-video HTTP Range fixture only; no WeChat or user media.
#import "FNBrowser.h"
#import <AVKit/AVKit.h>
@interface UIViewController (StreamHarness)
- (void)original;
- (void)stopStreamPreview;
@end
NSString *FNCompatibilityReport(void) { return @"Synthetic original streaming test"; }
@interface FNStreamHarness : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic) UIViewController *preview;
@property(nonatomic) NSTimer *timer;
@property(nonatomic) NSMutableDictionary *report;
@property(nonatomic) AVPlayerItem *firstItem;
@property(nonatomic) NSUInteger ticks;
@property(nonatomic) NSUInteger phase;
@property(nonatomic) NSTimeInterval started;
@end
@implementation FNStreamHarness
- (void)write {
    NSURL *directory=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted error:nil]
        writeToURL:[directory URLByAppendingPathComponent:@"stream-report.json"] atomically:YES];
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.started=NSProcessInfo.processInfo.systemUptime;
    NSString *address=[NSString stringWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"fixture" withExtension:@"txt"] encoding:NSUTF8StringEncoding error:nil];
    FNClient *client=FNClient.shared;
    [client setValue:[NSURL URLWithString:address] forKey:@"baseURL"];
    [client setValue:@"fixture-token" forKey:@"token"];
    [client setValue:@"fixture" forKey:@"username"];
    self.report=[NSMutableDictionary dictionary];
    self.preview=[NSClassFromString(@"FNPreviewController") new];
    [self.preview setValue:[FNSelection new] forKey:@"selection"];
    [self.preview setValue:@[@{@"id":@7,@"fileName":@"fixture.mp4",@"fileType":@"video",@"fileSize":@3000000,@"additional":@{@"thumbnail":@{@"videoUrl":@"/original.mp4"}}}] forKey:@"photos"];
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[[FNNavigationController alloc] initWithRootViewController:self.preview];
    [self.window makeKeyAndVisible];
    __weak typeof(self) weak=self;
    self.timer=[NSTimer scheduledTimerWithTimeInterval:.2 repeats:YES block:^(NSTimer *timer) {
        FNStreamHarness *s=weak;
        if (!s) return;
        AVPlayerViewController *player=[s.preview valueForKey:@"player"];
        AVPlayerItem *item=player.player.currentItem;
        if (++s.ticks>180 || s.preview.presentedViewController) {
            s.report[@"done"]=@YES; s.report[@"failed"]=@YES;
            s.report[@"error"]=item.error.localizedDescription ?: @"timeout or preview error alert";
            [timer invalidate]; [s write]; return;
        }
        if (item.status!=AVPlayerItemStatusReadyToPlay || CMTimeGetSeconds(player.player.currentTime)<.15 ||
            item.presentationSize.width<=0 || item.presentationSize.height<=0 || !player.readyForDisplay) return;
        if (s.phase==0) {
            AVURLAsset *asset=(id)item.asset;
            s.report[@"remoteOriginalPlayback"]=@(!asset.URL.isFileURL && [asset.URL.path isEqual:@"/original.mp4"]);
            s.report[@"noCompleteFileDownload"]=@([s.preview valueForKey:@"previewFile"]==nil);
            s.report[@"firstFrameSeconds"]=@(NSProcessInfo.processInfo.systemUptime-s.started);
            s.firstItem=item;
            NSURL *mark=[NSURL URLWithString:@"/fixture/mark-start" relativeToURL:client.baseURL];
            s.phase=2;
            [[NSURLSession.sharedSession dataTaskWithURL:mark completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) {
                dispatch_async(dispatch_get_main_queue(),^{ s.phase=1; [s.preview original]; });
            }] resume];
        } else if (s.phase==1) {
            s.report[@"loadingMaskHiddenAfterFirstFrame"]=@(((UIView *)[s.preview valueForKey:@"loadingMask"]).hidden);
            s.report[@"originalToggleDoesNotRestart"]=@(item==s.firstItem && ((FNSelection *)[s.preview valueForKey:@"selection"]).original);
            [player.player pause]; [s.preview stopStreamPreview];
            s.report[@"done"]=@YES; [timer invalidate]; [s write];
        }
    }];
    return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(FNStreamHarness.class)); } }
