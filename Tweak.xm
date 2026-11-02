#import "Sources/FNWeChatBridge.h"
#import "Sources/FNHost.h"
%config(generator=internal);
%hook ImageController
- (void)OpenMediaBrowser {
    if (!FNOfferAlbum(self, ^{ %orig; })) { %orig; }
}
%end
%ctor {
    @autoreleasepool {
        NSBundle *host = NSBundle.mainBundle;
        if (FNIsWeChatMainApplication(host.infoDictionary, host.bundlePath)) {
            FNPrepareCache();
            if (FNBridgeAvailable()) { %init; }
        }
    }
}
