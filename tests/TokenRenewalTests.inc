// Synthetic localhost fixtures only. Isolated native-tests Keychain service.
static int RunTokenRenewal(NSDictionary *fixture) {
    FNClient *client = [FNClient shared];
    __block BOOL done = NO;
    NSString *mode = fixture[@"scenario"];
    void (^finish)(void) = ^{
        Output(@{@"ok":@YES});
        done = YES;
    };
    void (^eraseMemory)(void) = ^{
        [client setValue:nil forKey:@"token"];
        [client setValue:nil forKey:@"longToken"];
        [client setValue:nil forKey:@"secret"];
    };
    [client loginAddress:fixture[@"address"] user:@"fixture-user" password:@"fixture-password"
               remember:YES completion:^(NSDictionary *result, NSError *error) {
        Require(!error && client.authenticated && !result[@"warning"], @"fixture login/save failed");
        NSUInteger generation = client.generation;
        if ([mode isEqual:@"routes"]) {
            NSString *first = fixture[@"address"], *second = fixture[@"secondAddress"];
            NSArray *trusted = @[first,second];
            [client routeToAddress:second trustedAddresses:@[second] completion:^(NSDictionary *r,NSError *e) {
                Require(e && client.authenticated && client.generation==generation,
                        @"untrusted source must not share credentials or change session");
                [client routeToAddress:second trustedAddresses:trusted completion:^(NSDictionary *r,NSError *e) {
                    Require(!e && client.authenticated && client.generation==generation+1 &&
                            [client.baseURL.absoluteString isEqual:[@"http://" stringByAppendingString:second]],
                            @"switch aliases must authenticate and change generation");
                    [client media:[NSString stringWithFormat:@"http://%@/fixture/image",first] completion:^(NSData *data,NSError *e) {
                        Require(!e && data.length,@"absolute trusted media alias must use active origin");
                        [client media:@"http://untrusted.invalid/fixture/image" completion:^(NSData *data,NSError *e) {
                            Require(e && !data,@"foreign media origin accepted");
                            eraseMemory();
                            [client restore:^(NSDictionary *r,NSError *e) {
                                Require(!e && client.authenticated &&
                                        [client.baseURL.absoluteString isEqual:[@"http://" stringByAppendingString:second]],
                                        @"active route and rotated credentials did not persist");
                                [client routeToAddress:first trustedAddresses:trusted completion:^(NSDictionary *r,NSError *e) {
                                    Require(!e && client.authenticated &&
                                            [client.baseURL.absoluteString isEqual:[@"http://" stringByAppendingString:first]],
                                            @"switch back to local alias");
                                    finish();
                                }];
                            }];
                        }];
                    }];
                }];
            }];
            return;
        }
        if ([mode isEqual:@"burst"]) {
            __block NSUInteger pending = 6, cancellations = 0;
            __block BOOL progress = NO;
            __block NSTimer *poll;
            void (^one)(void) = ^{
                Require(pending>0,@"transfer completed more than once");
                if (--pending) return;
                [poll invalidate]; poll=nil;
                Require(progress && cancellations==1, @"retry lost progress or cancellation");
                Require(client.authenticated && client.generation==generation,
                        @"renewal changed NAS account generation");
                eraseMemory();
                [client restore:^(NSDictionary *result, NSError *error) {
                    Require(!error && client.authenticated,@"rotated credentials were not saved");
                    finish();
                }];
            };
            for (NSString *path in @[@"/fixture/a",@"/fixture/late"])
                [client get:path params:@{} completion:^(NSDictionary *result, NSError *error) {
                    Require(!error && [result[@"ok"] boolValue],@"GET did not recover"); one();
                }];
            [client photoDetails:@[@77] completion:^(NSDictionary *result, NSError *error) {
                Require(!error && [result[@"list"] count]==1,@"POST did not recover"); one();
            }];
            [client media:@"/fixture/image" completion:^(NSData *data,NSError *error) {
                Require(!error && [data isEqual:[@"fixture image" dataUsingEncoding:NSUTF8StringEncoding]],
                        @"media did not recover"); one();
            }];
            NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
            FNTransfer *video = [client download:@"/fixture/video" to:file completion:^(NSError *error) {
                Require(!error && [NSData dataWithContentsOfURL:file].length==65536,@"download retry bytes");
                NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
                Require([attrs[NSFilePosixPermissions] integerValue]==0644,@"retry video permissions");
                [NSFileManager.defaultManager removeItemAtURL:file error:nil]; one();
            }];
            poll = [NSTimer scheduledTimerWithTimeInterval:.02 repeats:YES block:^(NSTimer *timer) {
                if (video.countOfBytesReceived>0 && video.countOfBytesReceived<video.countOfBytesExpectedToReceive)
                    progress=YES;
            }];
            NSURL *cancelFile = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
            FNTransfer *cancel = [client download:@"/fixture/cancel" to:cancelFile completion:^(NSError *error) {
                Require(error && ++cancellations==1 && ![NSFileManager.defaultManager fileExistsAtPath:cancelFile.path],
                        @"cancelled retry completed or left a file"); one();
            }];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/20),dispatch_get_main_queue(),^{ [cancel cancel]; });
            return;
        }
        __block NSUInteger calls = 0;
        [client get:@"/fixture/a" params:@{} completion:^(NSDictionary *result, NSError *error) {
            Require(error && ++calls==1,@"rejected request must complete once");
            if ([mode isEqual:@"logout"] || [mode isEqual:@"switch"]) return;
            BOOL terminal = [mode isEqual:@"terminal"];
            Require(terminal ? !client.authenticated : client.authenticated,@"unexpected credential clearing");
            if (terminal) Require([error.domain isEqual:@"WeChatFnAlbum.Auth"] && error.code==401,
                                  @"long-token rejection must require login");
            else Require(client.generation==generation,@"temporary renewal error changed generation");
            eraseMemory();
            [client restore:^(NSDictionary *restored, NSError *restoreError) {
                Require(!restoreError && (terminal ? !client.authenticated : client.authenticated),
                        @"Keychain credentials were not preserved/removed correctly");
                finish();
            }];
        }];
        if ([mode isEqual:@"logout"] || [mode isEqual:@"switch"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/4),dispatch_get_main_queue(),^{
                if ([mode isEqual:@"logout"]) {
                    [client logout];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
                        Require(calls==1 && !client.authenticated,@"late renewal revived logged-out account");
                        [client restore:^(NSDictionary *r,NSError *e) {
                            Require(!e && !client.authenticated,@"logout did not clear Keychain"); finish();
                        }];
                    });
                } else {
                    [client loginAddress:fixture[@"address"] user:@"fixture-other" password:@"other-password"
                               remember:YES completion:^(NSDictionary *r,NSError *e) {
                        Require(!e && [client.username isEqual:@"fixture-other"],@"account switch failed");
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
                            [client get:@"/fixture/new" params:@{} completion:^(NSDictionary *r,NSError *e) {
                                Require(calls==1 && !e && [r[@"ok"] boolValue] && [client.username isEqual:@"fixture-other"],
                                        @"old renewal replaced new account credentials"); finish();
                            }];
                        });
                    }];
                }
            });
        }
    }];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:15];
    while (!done && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Require(done,@"renewal fixture timed out");
    [client logout];
    return 0;
}
