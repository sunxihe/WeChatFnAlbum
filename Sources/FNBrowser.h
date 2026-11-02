#import "FNProtocol.h"
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void FNAlert(UIViewController *vc, NSString *message);
FOUNDATION_EXPORT NSURL *FNCacheDirectory(void);
@interface FNNavigationController : UINavigationController
- (void)DismissModalViewControllerAnimated:(BOOL)animated;
@end
@interface FNSelection : NSObject
@property(nonatomic) NSMutableArray<NSDictionary *> *photos;
@property(nonatomic) BOOL original;
@property(nonatomic) NSInteger limit;
@end
@interface FNBrowserController : UIViewController
@property(nonatomic) FNSelection *selection;
@property(nonatomic, copy, nullable) NSString *albumID;
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *queryFilters;
@property(nonatomic, copy) void (^sendSelection)(UIViewController *, NSArray<NSDictionary *> *, BOOL);
@end
@interface FNLoginController : UIViewController
@property(nonatomic, copy) void (^onLogin)(void);
@end
NS_ASSUME_NONNULL_END
