// Included only by FN_UI_DIAGNOSTICS. No text, photos, credentials or chat data.
#import <dlfcn.h>
#import <objc/runtime.h>
static NSArray *FNViewChain(UIView *view) {
    NSMutableArray *chain = [NSMutableArray array];
    for (UIView *v = view; v && chain.count < 16; v = v.superview) {
        NSMutableArray *gestures = [NSMutableArray array];
        for (UIGestureRecognizer *g in v.gestureRecognizers)
            [gestures addObject:@{@"class":NSStringFromClass(g.class), @"state":@(g.state),
                                  @"enabled":@(g.enabled), @"cancelsTouches":@(g.cancelsTouchesInView)}];
        [chain addObject:@{@"class":NSStringFromClass(v.class), @"frame":NSStringFromCGRect(v.frame),
                           @"bounds":NSStringFromCGRect(v.bounds), @"interaction":@(v.userInteractionEnabled),
                           @"hidden":@(v.hidden), @"alpha":@(v.alpha), @"gestures":gestures}];
    }
    return chain;
}
static NSDictionary *FNHit(UIView *view, UIView *root, CGPoint point) {
    UIWindow *window = root.window;
    CGPoint rp = [view convertPoint:point toView:root], wp = [view convertPoint:point toView:window];
    UIView *local = [root hitTest:rp withEvent:nil], *global = [window hitTest:wp withEvent:nil];
    return @{@"rootPoint":NSStringFromCGPoint(rp), @"windowPoint":NSStringFromCGPoint(wp),
             @"localHit":FNViewChain(local), @"windowHit":FNViewChain(global), @"target":FNViewChain(view)};
}
static void FNProbeBrowser(FNBrowserController *browser) {
    if (!browser.viewIfLoaded.window) return;
    UIView *root = browser.view;
    FNTimelineScrubber *scrubber = [browser valueForKey:@"scrubber"];
    UIButton *bar = [browser valueForKey:@"searchButton"];
    UITextField *field = [browser valueForKey:@"queryInput"];
    UIView *thumb = [scrubber valueForKey:@"thumb"];
    NSMutableDictionary *r = [@{@"build":@"0.2.1-ui-probe-1", @"time":@(NSDate.date.timeIntervalSince1970),
                                @"root":FNViewChain(root),
                                @"scrubber":FNHit(thumb, root, CGPointMake(14,24)),
                                @"fieldFirstResponder":@(field.isFirstResponder),
                                @"presentedClass":NSStringFromClass(browser.presentedViewController.class) ?: @"none"} mutableCopy];
    if (bar) r[@"search"] = FNHit(bar, root, CGPointMake(bar.bounds.size.width/2, 16));
    NSMutableArray *windows = [NSMutableArray array];
    for (UIWindow *w in UIApplication.sharedApplication.windows)
        [windows addObject:@{@"class":NSStringFromClass(w.class), @"frame":NSStringFromCGRect(w.frame),
                              @"level":@(w.windowLevel), @"key":@(w.keyWindow), @"hidden":@(w.hidden),
                              @"rootController":NSStringFromClass(w.rootViewController.class) ?: @"none"}];
    r[@"windows"] = windows;
    NSMutableDictionary *implementations = [NSMutableDictionary dictionary];
    for (NSString *className in @[@"UIView", @"UIWindow", @"UISearchBar", @"FNTimelineScrubber"])
        for (NSString *selector in @[@"hitTest:withEvent:", @"pointInside:withEvent:", @"becomeFirstResponder"] ) {
            Method method = class_getInstanceMethod(NSClassFromString(className), NSSelectorFromString(selector));
            Dl_info info = {0};
            if (method && dladdr((void *)method_getImplementation(method), &info) && info.dli_fname)
                implementations[[NSString stringWithFormat:@"%@.%@",className,selector]] = [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent];
        }
    r[@"methodOwners"] = implementations;
    [[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil]
        writeToURL:[FNCacheDirectory() URLByAppendingPathComponent:@"ui-probe.json"] atomically:YES];
}
