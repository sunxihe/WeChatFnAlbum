#import "FNNetworkRouting.h"
#import "FNBrowser.h"
#import <CoreLocation/CoreLocation.h>
#import <NetworkExtension/NetworkExtension.h>

static NSString *const RouteKey = @"org.ac.WeChatFnAlbum.networkRoute";
static NSDictionary *Configuration(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:RouteKey];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
static void CurrentSSID(void (^completion)(NSString *)) {
    // fetchCurrent returns nil when the signed host lacks Wi-Fi entitlement/location access.
    // A bounded wait also handles a stalled system service without blocking the browser.
    __block BOOL finished = NO;
    void (^finish)(NSString *) = ^(NSString *ssid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (finished) return;
            finished = YES;
            completion(ssid.length ? ssid : nil);
        });
    };
    [NEHotspotNetwork fetchCurrentWithCompletionHandler:^(NEHotspotNetwork *network) {
        finish(network.SSID);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC),dispatch_get_main_queue(), ^{ finish(nil); });
}
void FNPrepareNetworkRoute(FNResult completion) {
    NSDictionary *config = Configuration();
    NSInteger mode = [config[@"mode"] integerValue];
    if (mode < 1 || mode > 3) { [[FNClient shared] clearRouting]; completion(@{},nil); return; }
    void (^apply)(NSString *) = ^(NSString *ssid) {
        BOOL local = FNRouteUsesLocal(mode,config[@"ssid"],ssid);
        NSString *address = config[local ? @"local" : @"remote"];
        if (![address isKindOfClass:NSString.class] || !address.length) {
            completion(nil,FNError(@"请先在设置的「内外网访问」中填写 NAS 地址。")); return;
        }
        [[FNClient shared] routeToAddress:address trustedAddresses:@[config[@"local"] ?: @"",config[@"remote"] ?: @""]
                             completion:completion];
    };
    if (mode == 1) CurrentSSID(apply); else apply(nil);
}

@interface FNNetworkRoutingController () <CLLocationManagerDelegate>
@property(nonatomic) UISegmentedControl *mode;
@property(nonatomic) UITextField *ssid;
@property(nonatomic) UITextField *local;
@property(nonatomic) UITextField *remote;
@property(nonatomic) UILabel *status;
@property(nonatomic) UIButton *save;
@property(nonatomic) CLLocationManager *location;
@end
@implementation FNNetworkRoutingController
- (UITextField *)field:(NSString *)placeholder value:(id)value {
    UITextField *field = [UITextField new];
    field.placeholder = placeholder;
    field.text = [value isKindOfClass:NSString.class] ? value : @"";
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    [field.heightAnchor constraintEqualToConstant:44].active = YES;
    return field;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"内外网访问";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    NSDictionary *config = Configuration();
    self.mode = [[UISegmentedControl alloc] initWithItems:@[@"关闭",@"自动",@"内网",@"外网"]];
    NSInteger mode = [config[@"mode"] integerValue];
    self.mode.selectedSegmentIndex = mode >= 0 && mode <= 3 ? mode : 0;
    self.ssid = [self field:@"家中 Wi-Fi 名称（区分大小写）" value:config[@"ssid"]];
    self.local = [self field:@"内网地址，例如 192.168.2.126" value:config[@"local"]];
    self.remote = [self field:@"外网地址，例如 https://nas.example.com" value:config[@"remote"]];
    self.local.keyboardType = self.remote.keyboardType = UIKeyboardTypeURL;
    UIButton *detect = [UIButton buttonWithType:UIButtonTypeSystem];
    [detect setTitle:@"读取当前 Wi-Fi / 请求定位授权" forState:UIControlStateNormal];
    [detect addTarget:self action:@selector(detect) forControlEvents:UIControlEventTouchUpInside];
    self.status = [UILabel new];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont systemFontOfSize:13];
    self.status.textColor = UIColor.secondaryLabelColor;
    self.status.text = @"自动模式：Wi-Fi 名称完全一致时使用内网，其余情况使用外网。蜂窝流量或无法读取名称时静默走外网，可手动选择内网。\n\n两地址必须指向同一台 NAS，登录凭据会用于这两个地址。只填 IP 默认 HTTP 5666；外网域名建议填写实际协议与端口。\n\n读取 Wi-Fi 受微信签名权限及精确定位授权限制，单独注入 dylib 无法补齐签名权限。地址仅在重新进入相册或保存此页时切换。";
    self.save = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.save setTitle:@"保存并应用" forState:UIControlStateNormal];
    [self.save addTarget:self action:@selector(saveConfiguration) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.mode,self.ssid,self.local,self.remote,detect,self.save,self.status]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new];
    scroll.frame = self.view.bounds; scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll]; [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24]]];
}
- (void)readSSID {
    CurrentSSID(^(NSString *ssid) {
        if (ssid.length) {
            self.status.text = [@"当前 Wi-Fi：" stringByAppendingString:ssid];
            if (!self.ssid.text.length) self.ssid.text = ssid;
        } else self.status.text = @"无法读取 Wi-Fi 名称。请检查微信的精确定位授权，以及签名是否保留 Access Wi-Fi Information 权限。若当前签名不支持，可手动选择内网或外网。";
    });
}
- (void)detect {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    if ([info[@"NSLocationWhenInUseUsageDescription"] length] &&
        CLLocationManager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        self.location = [CLLocationManager new];
        self.location.delegate = self;
        [self.location requestWhenInUseAuthorization];
    } else [self readSSID];
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (manager.authorizationStatus != kCLAuthorizationStatusNotDetermined) [self readSSID];
}
- (void)saveConfiguration {
    NSString *(^trim)(NSString *) = ^NSString *(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @""; };
    NSInteger mode = self.mode.selectedSegmentIndex;
    NSDictionary *value = @{@"mode":@(mode),@"ssid":self.ssid.text ?: @"",@"local":trim(self.local.text),@"remote":trim(self.remote.text)};
    NSError *error = nil;
    if (mode && (!FNEndpoint(value[@"local"],&error) || !FNEndpoint(value[@"remote"],&error))) {
        FNAlert(self,error.localizedDescription); return;
    }
    if (mode == 1 && ![value[@"ssid"] length]) { FNAlert(self,@"请填写家中的 Wi-Fi 名称。"); return; }
    [self.view endEditing:YES];
    [NSUserDefaults.standardUserDefaults setObject:value forKey:RouteKey];
    self.save.enabled = NO; self.navigationItem.hidesBackButton = YES;
    FNPrepareNetworkRoute(^(NSDictionary *result, NSError *error) {
        self.save.enabled = YES; self.navigationItem.hidesBackButton = NO;
        if (error) { FNAlert(self,error.localizedDescription); return; }
        if (self.onChange) self.onChange();
        self.status.text = result[@"warning"] ?: @"已保存。下次进入飞牛相册时会按此配置连接。";
    });
}
@end
