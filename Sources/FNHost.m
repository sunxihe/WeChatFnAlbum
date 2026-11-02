#import "FNHost.h"

BOOL FNIsWeChatMainApplication(NSDictionary *info, NSString *bundlePath) {
    // Signing tools can change CFBundleIdentifier for multiple installations.
    // Match the main executable, then let FNBridgeAvailable validate native APIs.
    // Never activate inside notification/share extensions.
    return [bundlePath.pathExtension.lowercaseString isEqualToString:@"app"] &&
           [info[@"CFBundlePackageType"] isEqual:@"APPL"] && [info[@"CFBundleExecutable"] isEqual:@"WeChat"];
}
