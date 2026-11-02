// Development-only: original media Range support, no message APIs or credential logging.
#import "../Sources/FNNASVideoPreview.h"
static NSURLSession *FNOriginalProbeSession;
static void FNWriteOriginalProbe(NSDictionary *report) {
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
        writeToURL:[FNCacheDirectory() URLByAppendingPathComponent:@"video-stream-probe.json"] atomically:YES];
}
static void FNRunVideoPreviewProbe(void) {
    FNWriteOriginalProbe(@{@"stage":@"restore"});
    [FNClient.shared restore:^(NSDictionary *r,NSError *e) {
        if (e) { FNWriteOriginalProbe(@{@"error":e.localizedDescription}); return; }
        [FNClient.shared filteredPhotos:FNCategoryFilters(@"media",@{@"value":@"video"}) completion:^(NSDictionary *r,NSError *e) {
            id identity=[r[@"idList"] firstObject];
            if (e || !identity) { FNWriteOriginalProbe(@{@"stage":@"no video"}); return; }
            [FNClient.shared photoDetails:@[identity] completion:^(NSDictionary *r,NSError *e) {
                NSDictionary *photo=[r[@"list"] firstObject];
                NSError *error=e;
                NSDictionary *config=photo ? [FNClient.shared originalVideoPlaybackConfiguration:FNMediaURL(photo,YES) error:&error] : nil;
                if (!config || error) { FNWriteOriginalProbe(@{@"error":error.localizedDescription ?: @"missing video"}); return; }
                NSURLSessionConfiguration *settings=NSURLSessionConfiguration.ephemeralSessionConfiguration;
                settings.timeoutIntervalForRequest=10; settings.timeoutIntervalForResource=15;
                [settings.HTTPCookieStorage setCookies:config[@"cookies"] forURL:config[@"url"] mainDocumentURL:config[@"url"]];
                FNOriginalProbeSession=[NSURLSession sessionWithConfiguration:settings];
                NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:config[@"url"]];
                [request setValue:@"bytes=0-65535" forHTTPHeaderField:@"Range"];
                NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;
                [[FNOriginalProbeSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
                    NSHTTPURLResponse *http=(id)response;
                    FNWriteOriginalProbe(@{@"status":@(http.statusCode),@"bytes":@(data.length),
                        @"seconds":@(NSProcessInfo.processInfo.systemUptime-started),
                        @"rangeSupported":@(http.statusCode==206),@"contentRange":http.allHeaderFields[@"Content-Range"] ?: @"",
                        @"mime":http.MIMEType ?: @"",@"error":error.localizedDescription ?: @""});
                    [FNOriginalProbeSession finishTasksAndInvalidate]; FNOriginalProbeSession=nil;
                }] resume];
            }];
        }];
    }];
}
