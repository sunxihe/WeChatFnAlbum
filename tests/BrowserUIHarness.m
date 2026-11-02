#import "FNPreviewLoadingView.h"
// Simulator-only regression harness. Synthetic rows; no NAS connection or chat send.
#import "FNBrowser.h"
#import "FNCategories.h"
#import "FNTimelineScrubber.h"
#import "FNPreviewAudio.h"
#import "FNZoomImageView.h"
#include "PreviewAudioTests.inc"
#import <objc/runtime.h>
@interface FNFixtureTransfer : NSObject
@property(nonatomic) int64_t countOfBytesReceived;
@property(nonatomic) int64_t countOfBytesExpectedToReceive;
@property(nonatomic) BOOL cancelled;
@property(nonatomic, copy) void (^completion)(NSData *, NSError *);
@end
@implementation FNFixtureTransfer
- (void)cancel { self.cancelled = YES; }
@end
static NSMutableArray<FNFixtureTransfer *> *transfers;
static id FixtureMedia(id obj, SEL sel, NSString *path, void (^completion)(NSData *, NSError *)) {
    FNFixtureTransfer *transfer = [FNFixtureTransfer new];
    transfer.completion = completion;
    [transfers addObject:transfer];
    return transfer;
}
@interface UIViewController (PreviewHarness)
- (void)swipe:(UISwipeGestureRecognizer *)gesture;
@end
NSString *FNCompatibilityReport(void) {
    return @"Simulator UI regression";
}
static BOOL Authenticated(id obj, SEL sel) {
    return YES;
}

@interface FNBrowserController (UIHarness)
- (void)reload;
- (void)updateTimeline;
- (void)loadNewer;
@end
@interface FNFixtureBrowser : FNBrowserController
@end
@implementation FNFixtureBrowser
- (void)reload {
    if ([[self valueForKey:@"segment"] selectedSegmentIndex] == 3) {
        [super reload];
        return;
    }
    FNPhotoPager *pager = [FNPhotoPager new];
    [pager setValue:@[
        @{@"year" : @2026, @"month" : @10, @"day" : @30, @"itemCount" : @3},
        @{@"year" : @2020, @"month" : @1, @"day" : @1, @"itemCount" : @1}
    ]
             forKey:@"days"];
    [self setValue:pager forKey:@"pager"];
    [self setValue:[@[ @{@"id" : @1, @"fileName" : @"fixture.jpg", @"fn_dayIndex" : @0} ] mutableCopy]
            forKey:@"photos"];
    UICollectionView *grid = [self valueForKey:@"collectionView"];
    [grid reloadData];
    [self updateTimeline];
}
- (void)loadMore {
} // Never fetch a real NAS, even when the last fixture cell is visible.
@end

// Drive UIControl's declared Objective-C callbacks, not helpers named by the implementation.
@interface FNFixtureTouch : UITouch
@property(nonatomic) CGPoint position;
@end
@implementation FNFixtureTouch
- (CGPoint)locationInView:(UIView *)view {
    return self.position;
}
@end
@interface FNControlEvents : NSObject
@property(nonatomic) NSUInteger changes;
@property(nonatomic) NSUInteger releases;
- (void)changed;
- (void)released;
@end
@implementation FNControlEvents
- (void)changed {
    self.changes++;
}
- (void)released {
    self.releases++;
}
@end

@interface FNPreviousFixturePager : FNPhotoPager
@property(nonatomic) BOOL exhausted;
@end
@implementation FNPreviousFixturePager
- (BOOL)hasPrevious {
    return !self.exhausted;
}
- (void)previous:(void (^)(NSArray *, NSError *))completion {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < 17; i++)
        [rows addObject:@{@"id" : @(1000 + i), @"fileName" : @"newer.jpg", @"fn_dayIndex" : @0}];
    self.exhausted = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(rows, nil);
    });
}
@end

@interface FNPortraitFixture : FNCategoriesController
@end
@implementation FNPortraitFixture
- (void)loadMore {
    [self setValue:[@[@{@"id":@41, @"faceId":@123, @"name":@"", @"itemCount":@12},
                       @{@"id":@42, @"name":@""}] mutableCopy] forKey:@"entries"];
    [self setValue:@NO forKey:@"more"];
}
@end

@interface FNUIHarnessDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic) FNFixtureBrowser *browser;
@property(nonatomic) NSMutableDictionary *report;
@end
@implementation FNUIHarnessDelegate
- (void)testPreviewLoading {
    UIViewController *preview = [NSClassFromString(@"FNPreviewController") new];
    [preview setValue:[FNSelection new] forKey:@"selection"];
    [preview setValue:@[
        @{@"id":@501, @"fileName":@"one.jpg", @"additional":@{@"thumbnail":@{@"originalUrl":@"/one.jpg"}}},
        @{@"id":@502, @"fileName":@"two.jpg", @"additional":@{@"thumbnail":@{@"originalUrl":@"/two.jpg"}}}
    ] forKey:@"photos"];
    [preview loadViewIfNeeded];
    UIView *mask = [preview valueForKey:@"loadingMask"];
    UILabel *label = [mask valueForKey:@"percentage"];
    [(id)mask updateBufferedSeconds:1.25 target:5];
    self.report[@"streamBufferShowsMeasuredPercentage"]=@([label.text isEqual:@"25%"] &&
        !((UIProgressView *)[mask valueForKey:@"bar"]).hidden &&
        [((UILabel *)[mask valueForKey:@"detail"]).text containsString:@"1.2"]);
    [(id)mask showTitle:@"加载中"];

    self.report[@"unknownPreviewSizeShowsLoading"] = @(!mask.hidden && [label.text isEqual:@"加载中…"]);
    FNFixtureTransfer *first = transfers.lastObject;
    first.countOfBytesReceived = 25;
    first.countOfBytesExpectedToReceive = 100;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/4),dispatch_get_main_queue(), ^{
        self.report[@"previewReportsReceivedPercentage"] = @(!mask.hidden && [label.text isEqual:@"25%"]);
        UISwipeGestureRecognizer *swipe = [UISwipeGestureRecognizer new];
        swipe.direction = UISwipeGestureRecognizerDirectionLeft;
        [preview swipe:swipe];
        FNFixtureTransfer *second = transfers.lastObject;
        second.countOfBytesReceived = 50;
        second.countOfBytesExpectedToReceive = 100;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(8,8), YES, 1);
        [UIColor.systemBlueColor setFill]; UIRectFill(CGRectMake(0,0,8,8));
        NSData *png = UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext());
        UIGraphicsEndImageContext();
        first.completion(png,nil); // Late completion from the cancelled first photo.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/4),dispatch_get_main_queue(), ^{
            self.report[@"oldPreviewCannotHideNewProgress"] = @(first.cancelled && first!=second &&
                !mask.hidden && [label.text isEqual:@"50%"]);
            second.completion(png,nil);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(), ^{
                self.report[@"previewHidesProgressAfterDecode"] = @(mask.hidden &&
                    ((UIImageView *)[preview valueForKey:@"image"]).image != nil &&
                    [preview valueForKey:@"loadingTimer"] == nil);
                FNZoomImageView *zoom = [preview valueForKey:@"zoom"];
                [zoom layoutIfNeeded];
                self.report[@"photoSupportsNativePinchZoom"] = @(zoom.pinchGestureRecognizer.enabled &&
                    [zoom.delegate viewForZoomingInScrollView:zoom] == zoom.imageView && zoom.maximumZoomScale >= 3);
                self.report[@"photoFitsAndCentersBeforeZoom"] = @(zoom.zoomScale == 1 &&
                    zoom.imageView.frame.size.width <= zoom.bounds.size.width+.1 &&
                    zoom.imageView.frame.size.height <= zoom.bounds.size.height+.1 &&
                    fabs(zoom.contentInset.top-zoom.contentInset.bottom)<.1);
                [zoom setZoomScale:2 animated:NO];
                self.report[@"zoomedPhotoCanPanBeyondViewport"] = @(zoom.zoomScale == 2 &&
                    (zoom.contentSize.width > zoom.bounds.size.width || zoom.contentSize.height > zoom.bounds.size.height));
                NSInteger index = [[preview valueForKey:@"index"] integerValue];
                UISwipeGestureRecognizer *drag = [UISwipeGestureRecognizer new];
                drag.direction = UISwipeGestureRecognizerDirectionRight;
                [preview swipe:drag];
                self.report[@"zoomedDragDoesNotSwitchPhoto"] = @([[preview valueForKey:@"index"] integerValue] == index);
                [zoom setImage:zoom.imageView.image];
                self.report[@"newImageResetsZoomAndEnablesPaging"] = @(zoom.zoomScale == 1 &&
                    [(id<UIGestureRecognizerDelegate>)preview gestureRecognizerShouldBegin:drag]);
                [zoom setZoomScale:2 animated:NO];
                CGSize size = zoom.bounds.size;
                zoom.bounds = CGRectMake(0,0,size.height,size.width);
                [zoom layoutIfNeeded];
                self.report[@"rotationResetsPhotoToFit"] = @(zoom.zoomScale == 1 &&
                    zoom.imageView.frame.size.width <= zoom.bounds.size.width+.1 &&
                    zoom.imageView.frame.size.height <= zoom.bounds.size.height+.1);
                [self save];
            });
        });
    });
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    class_replaceMethod(FNClient.class, @selector(authenticated), (IMP)Authenticated, "B@:");
    transfers = [NSMutableArray array];
    Method media = class_getInstanceMethod(FNClient.class,@selector(media:completion:));
    class_replaceMethod(FNClient.class,@selector(media:completion:),(IMP)FixtureMedia,method_getTypeEncoding(media));
    self.report = [PreviewAudioChecks() mutableCopy];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.browser = [FNFixtureBrowser new];
    self.window.rootViewController = [[FNNavigationController alloc] initWithRootViewController:self.browser];
    [self.window makeKeyAndVisible];
    [self.browser loadViewIfNeeded];
    UICollectionView *durationGrid = [self.browser valueForKey:@"collectionView"];
    [self.browser setValue:[@[@{@"id":@999,@"fileName":@"sample.mp4",@"mediaDuration":@3661}] mutableCopy] forKey:@"photos"];
    [self.browser.view layoutIfNeeded];
    [durationGrid reloadData];
    [durationGrid layoutIfNeeded];
    UICollectionViewCell *durationCell = [durationGrid cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
    [durationCell layoutIfNeeded];
    UILabel *duration = [durationCell valueForKey:@"duration"];
    self.report[@"videoDurationAtBottomRight"] = @(!duration.hidden && [duration.text isEqual:@"01:01:01"] &&
        fabs(CGRectGetMaxX(duration.frame)-(durationCell.bounds.size.width-5))<.1 &&
        fabs(CGRectGetMaxY(duration.frame)-(durationCell.bounds.size.height-5))<.1);
    [durationCell prepareForReuse];
    self.report[@"reusedCellClearsVideoDuration"] = @(duration.hidden && !duration.text.length);
    [self.browser reload];
    [self testPreviewLoading];
    [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardDidShowNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
                                                    self.report[@"keyboardShown"] = @YES;
                                                    [self save];
                                                }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        @try {
            FNPortraitFixture *people = [FNPortraitFixture new];
            people.kind = @"person";
            [people loadViewIfNeeded];
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(64,64), YES, 1);
            [UIColor.systemGreenColor setFill];
            UIRectFill(CGRectMake(0,0,64,64));
            UIImage *portrait = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            [[people valueForKey:@"portraits"] setObject:portrait forKey:@"/p/api/v1/stream/face/123"];
            UITableViewCell *personCell = [people tableView:people.tableView cellForRowAtIndexPath:
                [NSIndexPath indexPathForRow:0 inSection:0]];
            UIListContentConfiguration *personContent = (id)personCell.contentConfiguration;
            self.report[@"unnamedPersonShowsPortrait"] = @(personContent.image == portrait &&
                [personContent.text isEqual:@"未命名人物"] && people.tableView.rowHeight >= 80 &&
                personContent.imageProperties.reservedLayoutSize.width == 64);
            UITableViewCell *fallbackCell = [people tableView:people.tableView cellForRowAtIndexPath:
                [NSIndexPath indexPathForRow:1 inSection:0]];
            self.report[@"missingFaceHasPlaceholder"] = @(((UIListContentConfiguration *)fallbackCell.contentConfiguration).image != nil &&
                ((UIListContentConfiguration *)fallbackCell.contentConfiguration).image != portrait);
            [self.browser.view layoutIfNeeded];
            UICollectionView *grid = [self.browser valueForKey:@"collectionView"];
            FNTimelineScrubber *scrubber = [self.browser valueForKey:@"scrubber"];
            UIButton *search = [self.browser valueForKey:@"searchButton"];
            [scrubber layoutIfNeeded];
            UIView *thumb = [scrubber valueForKey:@"thumb"];
            CGPoint thumbPoint =
                [thumb convertPoint:CGPointMake(CGRectGetMidX(thumb.bounds), CGRectGetMidY(thumb.bounds))
                             toView:self.browser.view];
            self.report[@"scrubberOutsideScrollView"] = @(![scrubber isDescendantOfView:grid]);
            self.report[@"thumbHitReachesControl"] = @([self.browser.view hitTest:thumbPoint
                                                                        withEvent:nil] == scrubber);
            CGPoint trackPoint = [scrubber convertPoint:CGPointMake(32, scrubber.bounds.size.height * .7)
                                                 toView:self.browser.view];
            self.report[@"trackHitReachesControl"] = @([self.browser.view hitTest:trackPoint
                                                                        withEvent:nil] == scrubber);
            self.report[@"searchOutsideScrollView"] = @(![search isDescendantOfView:grid]);
            self.report[@"searchDoesNotCoverGrid"] =
                @(CGRectGetMaxY(search.frame) <= CGRectGetMinY(grid.frame));
            self.report[@"noModalSearchController"] = @(self.browser.presentedViewController == nil);
            // Exercise the user entry action; the harness must not focus the field itself.
            [search sendActionsForControlEvents:UIControlEventTouchUpInside];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                UITextField *field = [self.browser valueForKey:@"queryInput"];
                self.report[@"modalFieldInWindow"] = @(field.window != nil);
                self.report[@"fieldIsFirstResponder"] = @(field.isFirstResponder);
                self.report[@"searchAlertPresented"] =
                    @([self.browser.presentedViewController isKindOfClass:UIAlertController.class]);
                [self save];
                [self.browser
                    dismissViewControllerAnimated:NO
                                       completion:^{
                                           UISegmentedControl *segment =
                                               [self.browser valueForKey:@"segment"];
                                           segment.selectedSegmentIndex = 3;
                                           [segment sendActionsForControlEvents:UIControlEventValueChanged];
                                           [grid reloadData];
                                           [grid layoutIfNeeded];
                                           self.report[@"categoryEntryVisible"] =
                                               @([grid numberOfItemsInSection:0] == 3);
                                           [(id<UICollectionViewDelegate>)self.browser
                                                         collectionView:grid
                                               didSelectItemAtIndexPath:[NSIndexPath indexPathForItem:2
                                                                                            inSection:0]];
                                           dispatch_after(
                                               dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                               dispatch_get_main_queue(), ^{
                                                   FNCategoriesController *types =
                                                       (id)self.browser.navigationController
                                                           .topViewController;
                                                   [types.view layoutIfNeeded];
                                                   BOOL hasTypes =
                                                       [types isKindOfClass:FNCategoriesController.class] &&
                                                       [types.tableView numberOfRowsInSection:0] == 7;
                                                   if (hasTypes)
                                                       [(id<UITableViewDelegate>)types
                                                                         tableView:types.tableView
                                                           didSelectRowAtIndexPath:[NSIndexPath
                                                                                       indexPathForRow:0
                                                                                             inSection:0]];
                                                   FNBrowserController *result =
                                                       (id)self.browser.navigationController
                                                           .topViewController;
                                                   self.report[@"mediaTypeRouteUsesFilter"] =
                                                       @(hasTypes &&
                                                         [result isKindOfClass:FNBrowserController.class] &&
                                                         [result.queryFilters.firstObject[@"filterName"]
                                                             isEqual:@"file_type"] &&
                                                         [result.queryFilters.firstObject[@"filterValue"]
                                                             isEqual:@"video"]);
                                                   [self save];
                                               });
                                       }];
            });
            FNFixtureTouch *touch = [FNFixtureTouch new];
            FNControlEvents *events = [FNControlEvents new];
            [scrubber addTarget:events action:@selector(changed) forControlEvents:UIControlEventValueChanged];
            [scrubber addTarget:events
                          action:@selector(released)
                forControlEvents:UIControlEventTouchUpInside];
            UIControl *control = scrubber;
            touch.position = CGPointMake(32, 24);
            BOOL began = [control beginTrackingWithTouch:touch withEvent:nil];
            touch.position = CGPointMake(32, 24 + .75 * (scrubber.bounds.size.height - 48));
            BOOL continued = [control continueTrackingWithTouch:touch withEvent:nil];
            self.report[@"dragCallbacksUpdateValue"] =
                @(began && continued && events.changes == 2 && fabs(scrubber.fraction - .75) < .001);
            [scrubber layoutIfNeeded];
            self.report[@"thumbMovesVertically"] = @(thumb.frame.origin.y > scrubber.bounds.size.height * .5);
            [control endTrackingWithTouch:touch withEvent:nil];
            self.report[@"releaseCommitsOnce"] = @(events.releases == 1);
            [scrubber removeTarget:events action:NULL forControlEvents:UIControlEventAllEvents];
            UIRefreshControl *refresh = [self.browser valueForKey:@"refresh"];
            self.report[@"dateJumpDisablesRefresh"] = @(!refresh.enabled);
            FNPreviousFixturePager *pager = [FNPreviousFixturePager new];
            [pager setValue:[[self.browser valueForKey:@"pager"] days] forKey:@"days"];
            [self.browser setValue:pager forKey:@"pager"];
            NSMutableArray *historical = [NSMutableArray array];
            for (NSUInteger i = 0; i < 180; i++)
                [historical addObject:@{@"id" : @(i + 1), @"fileName" : @"history.jpg", @"fn_dayIndex" : @1}];
            [self.browser setValue:historical forKey:@"photos"];
            [grid reloadData];
            [grid layoutIfNeeded];
            [grid setContentOffset:CGPointMake(0, 400) animated:NO];
            [grid layoutIfNeeded];
            NSIndexPath *anchor =
                [[grid.indexPathsForVisibleItems sortedArrayUsingSelector:@selector(compare:)] firstObject];
            CGFloat relativeY =
                [grid layoutAttributesForItemAtIndexPath:anchor].frame.origin.y - grid.contentOffset.y;
            [self.browser loadNewer];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSIndexPath *shifted = [NSIndexPath indexPathForItem:anchor.item + 17 inSection:0];
                CGFloat newRelativeY =
                    [grid layoutAttributesForItemAtIndexPath:shifted].frame.origin.y - grid.contentOffset.y;
                self.report[@"newerInsertionPreservesAnchor"] =
                    @(anchor && fabs(newRelativeY - relativeY) < .5 && historical.count == 197);
                [refresh sendActionsForControlEvents:UIControlEventValueChanged];
                self.report[@"historicalPullKeepsRange"] =
                    @(historical.count == 197 && [self.browser valueForKey:@"photos"] == historical);
                [self save];
            });
        } @catch (NSException *e) {
            self.report[@"exception"] = e.name;
        }
        [self save];
    });
    return YES;
}
- (void)save {
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                            inDomains:NSUserDomainMask]
                           .firstObject;
    [[NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted error:nil]
        writeToURL:[directory URLByAppendingPathComponent:@"ui-report.json"]
        atomically:YES];
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(FNUIHarnessDelegate.class));
    }
}
