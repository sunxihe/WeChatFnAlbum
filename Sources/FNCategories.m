#import "FNCategories.h"
#import <ImageIO/ImageIO.h>

@interface FNCategoryCell : UITableViewCell
@property(nonatomic, copy) NSString *identity;
@property(nonatomic) FNTransfer *task;
@end
@implementation FNCategoryCell
- (void)prepareForReuse {
    [super prepareForReuse];
    [self.task cancel];
    self.task = nil;
    self.identity = nil;
}
@end

@interface FNCategoriesController ()
@property(nonatomic) NSMutableArray<NSDictionary *> *entries;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL more;
@property(nonatomic) NSUInteger offset;
@property(nonatomic) UILabel *status;
@property(nonatomic) NSCache *portraits;
@end
@implementation FNCategoriesController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.entries = [NSMutableArray array];
    self.portraits = [NSCache new];
    self.portraits.totalCostLimit = 6 * 1024 * 1024;
    self.tableView.rowHeight = [self.kind isEqual:@"person"] ? 88 : 60;
    self.status = [UILabel new];
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.textColor = UIColor.secondaryLabelColor;
    self.tableView.backgroundView = self.status;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [self reload];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
}
- (void)reload {
    if (self.loading) {
        [self.refreshControl endRefreshing];
        return;
    }
    self.offset = 0;
    self.more = YES;
    [self.entries removeAllObjects];
    [self.tableView reloadData];
    [self loadMore];
}
- (void)loadMore {
    if (self.loading || !self.more)
        return;
    if ([self.kind isEqual:@"media"]) {
        [self.entries addObjectsFromArray:FNMediaTypeCategories()];
        self.more = NO;
        [self.refreshControl endRefreshing];
        [self.tableView reloadData];
        return;
    }
    self.loading = YES;
    self.status.text = self.entries.count ? @"" : @"正在读取分类…";
    BOOL person = [self.kind isEqual:@"person"];
    NSString *path = person ? @"/p/api/v1/ai-person/list" : @"/p/api/v1/explore/geos";
    NSDictionary *params =
        person ? @{@"getAll" : @"true", @"orderBy" : @"name"} : @{@"offset" : @(self.offset), @"limit" : @60};
    [[FNClient shared] get:path
                    params:params
                completion:^(NSDictionary *result, NSError *error) {
                    self.loading = NO;
                    [self.refreshControl endRefreshing];
                    NSArray *list = result[@"list"];
                    if (!error && ![list isKindOfClass:NSArray.class])
                        error = FNError(@"分类列表格式不兼容。");
                    if (!error) {
                        for (id entry in list)
                            if ([entry isKindOfClass:NSDictionary.class] &&
                                FNCategoryFilters(self.kind, entry).count &&
                                !(person && [entry[@"isHide"] boolValue]))
                                [self.entries addObject:entry];
                        self.offset += list.count;
                        self.more = !person &&
                                    (result[@"hasNext"] ? [result[@"hasNext"] boolValue] : list.count == 60);
                    }
                    self.status.text = self.entries.count
                                           ? @""
                                           : (error ? error.localizedDescription
                                                    : (person ? @"暂无人物，请先在 NAS 相册中启用人物识别。"
                                                              : @"暂无带地点信息的照片。"));
                    [self.tableView reloadData];
                    if (error && self.entries.count)
                        FNAlert(self, error.localizedDescription);
                    if (!error && !self.entries.count && self.more)
                        [self loadMore];
                }];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.entries.count;
}
- (NSString *)labelForEntry:(NSDictionary *)entry {
    if ([self.kind isEqual:@"location"]) {
        NSString *country = entry[@"country"], *city = entry[@"city"];
        return city.length ? [NSString stringWithFormat:@"%@ · %@", country, city] : country;
    }
    NSString *name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : @"";
    return name.length ? name : @"未命名人物";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    FNCategoryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"category"];
    if (!cell)
        cell = [[FNCategoryCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"category"];
    [cell.task cancel];
    cell.task = nil;
    NSDictionary *entry = self.entries[path.row];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = [self labelForEntry:entry];
    content.secondaryText =
        entry[@"itemCount"] ? [NSString stringWithFormat:@"%@ 项", entry[@"itemCount"]] : @"";
    content.image =
        [UIImage systemImageNamed:[self.kind isEqual:@"person"]
                                      ? @"person.crop.circle"
                                      : ([self.kind isEqual:@"location"] ? @"mappin.and.ellipse"
                                                                         : @"photo.on.rectangle")];
    NSString *portrait = FNPersonPortraitURL(entry);
    BOOL person = [self.kind isEqual:@"person"];
    cell.identity = person ? portrait : @"";
    if (person) {
        content.imageProperties.maximumSize = CGSizeMake(64, 64);
        content.imageProperties.reservedLayoutSize = CGSizeMake(64, 64);
        content.imageProperties.cornerRadius = 32;
        content.imageProperties.tintColor = nil;
        UIImage *cached = [self.portraits objectForKey:portrait];
        if (cached) content.image = cached;
    }
    cell.contentConfiguration = content;
    if (person && portrait.length && ![self.portraits objectForKey:portrait]) {
        __weak FNCategoryCell *weakCell = cell;
        NSCache *cache = self.portraits;
        cell.task = [[FNClient shared] media:portrait completion:^(NSData *data, NSError *error) {
            if (error || !data.length) return;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
                CGImageRef cg = source ? CGImageSourceCreateThumbnailAtIndex(source, 0,
                    (__bridge CFDictionaryRef)@{(__bridge id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                      (__bridge id)kCGImageSourceThumbnailMaxPixelSize:@160,
                      (__bridge id)kCGImageSourceCreateThumbnailWithTransform:@YES}) : NULL;
                UIImage *image = cg ? [UIImage imageWithCGImage:cg] : nil;
                if (cg) CGImageRelease(cg);
                if (source) CFRelease(source);
                if (!image) return;
                [cache setObject:image forKey:portrait cost:(NSUInteger)(image.size.width * image.size.height * 4)];
                dispatch_async(dispatch_get_main_queue(), ^{
                    FNCategoryCell *visible = weakCell;
                    if (![visible.identity isEqual:portrait]) return;
                    UIListContentConfiguration *updated = [(UIListContentConfiguration *)visible.contentConfiguration copy];
                    updated.image = image;
                    visible.contentConfiguration = updated;
                });
            });
        }];
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (path.row + 5 >= self.entries.count)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self loadMore];
        });
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *entry = self.entries[path.row];
    FNBrowserController *browser = [FNBrowserController new];
    browser.queryFilters = FNCategoryFilters(self.kind, entry);
    browser.title = [self labelForEntry:entry];
    browser.selection = self.selection;
    browser.sendSelection = self.sendSelection;
    [self.navigationController pushViewController:browser animated:YES];
}
@end
