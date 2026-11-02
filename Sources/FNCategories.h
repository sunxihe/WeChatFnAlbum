#import "FNBrowser.h"
@interface FNCategoriesController : UITableViewController
@property(nonatomic, copy) NSString *kind;
@property(nonatomic) FNSelection *selection;
@property(nonatomic, copy) void (^sendSelection)(UIViewController *, NSArray<NSDictionary *> *, BOOL);
@end
