#import <UIKit/UIKit.h>
#import "FNProtocol.h"
// Called only when opening a new browser, never while preparing/sending media.
FOUNDATION_EXPORT void FNPrepareNetworkRoute(FNResult completion);
@interface FNNetworkRoutingController : UIViewController
@property(nonatomic, copy) dispatch_block_t onChange;
@end
