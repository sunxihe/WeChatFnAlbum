#import "FNMediaHandoff.h"
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL Has(id object, NSString *name, NSArray *args) {
    Method method = class_getInstanceMethod(object_getClass(object), NSSelectorFromString(name));
    if (!method || method_getNumberOfArguments(method) != args.count + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL ok = type && !strcmp(type, "v");
    free(type);
    for (NSUInteger i=0;ok && i<args.count;i++) {
        type = method_copyArgumentType(method, (unsigned)i+2);
        ok = type && !strcmp(type, [args[i] UTF8String]);
        free(type);
    }
    return ok;
}
BOOL FNMediaHandoff(NSArray *assets, id imageController, id videoDelegate, id picker, NSError **error) {
    NSUInteger lastImage = NSNotFound;
    BOOL hasVideo = NO;
    Class videoInfo = NSClassFromString(@"CaptureVideoInfo");
    for (NSUInteger i=0;i<assets.count;i++) {
        if ([assets[i] isKindOfClass:videoInfo]) hasVideo=YES;
        else lastImage=i;
    }
    // Validate every required destination before invoking any irreversible callback.
    if (!assets.count ||
        (hasVideo && !Has(videoDelegate,@"CameraControllerDidTakeVideo:",@[@"@"])) ||
        (lastImage != NSNotFound && !Has(imageController,@"didSelectMMAsset:finish:fromImagePicker:",@[@"@",@"B",@"@"])) ||
        (lastImage == NSNotFound && !Has(picker,@"DismissModalViewControllerAnimated:",@[@"B"]))) {
        if (error) *error = [NSError errorWithDomain:@"WeChatFnAlbum" code:1 userInfo:
            @{NSLocalizedDescriptionKey:@"当前微信的素材完成接口不兼容，尚未提交发送。"}];
        return NO;
    }
    for (NSUInteger i=0;i<assets.count;i++) {
        if ([assets[i] isKindOfClass:videoInfo])
            ((void(*)(id,SEL,id))objc_msgSend)(videoDelegate,
                NSSelectorFromString(@"CameraControllerDidTakeVideo:"),assets[i]);
        else
            ((void(*)(id,SEL,id,BOOL,id))objc_msgSend)(imageController,
                NSSelectorFromString(@"didSelectMMAsset:finish:fromImagePicker:"),assets[i],i==lastImage,picker);
    }
    if (lastImage == NSNotFound)
        ((void(*)(id,SEL,BOOL))objc_msgSend)(picker,NSSelectorFromString(@"DismissModalViewControllerAnimated:"),YES);
    return YES;
}
