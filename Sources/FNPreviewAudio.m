#import "FNPreviewAudio.h"
@interface FNPreviewAudio ()
@property(nonatomic) id<FNPreviewAudioSession> session;
@property(nonatomic) NSString *previousCategory;
@property(nonatomic) NSString *previousMode;
@property(nonatomic) AVAudioSessionCategoryOptions previousOptions;
@property(nonatomic) BOOL owned;
@end
@implementation FNPreviewAudio
- (instancetype)init {
    return [self initWithSession:(id<FNPreviewAudioSession>)AVAudioSession.sharedInstance];
}
- (instancetype)initWithSession:(id<FNPreviewAudioSession>)session {
    if ((self = [super init])) _session = session;
    return self;
}
- (BOOL)matchesPlayback {
    return [self.session.category isEqual:AVAudioSessionCategoryPlayback] &&
        [self.session.mode isEqual:AVAudioSessionModeMoviePlayback] && self.session.categoryOptions == 0;
}
- (BOOL)begin:(NSError **)error {
    // A host takeover ends our ownership; do not replace its new configuration on exit.
    if (self.owned && ![self matchesPlayback]) self.owned = NO;
    if ([self.session.category isEqual:AVAudioSessionCategoryRecord] ||
        [@[AVAudioSessionModeVoiceChat,AVAudioSessionModeVideoChat,AVAudioSessionModeGameChat]
            containsObject:self.session.mode]) {
        if (error) *error = [NSError errorWithDomain:@"WeChatFnAlbum.Audio" code:1 userInfo:
            @{NSLocalizedDescriptionKey:@"微信正在使用录音或通话音频，请结束后再播放预览。"}];
        return NO;
    }
    if (!self.owned) {
        self.previousCategory = self.session.category;
        self.previousMode = self.session.mode;
        self.previousOptions = self.session.categoryOptions;
        if (![self.session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback
                               options:0 error:error]) return NO;
        self.owned = YES;
    }
    if (![self.session setActive:YES withOptions:0 error:error]) {
        // Activation never succeeded, so do not deactivate a host audio session.
        if ([self matchesPlayback])
            [self.session setCategory:self.previousCategory mode:self.previousMode options:self.previousOptions error:nil];
        self.owned = NO;
        return NO;
    }
    return YES;
}
- (void)end {
    if (!self.owned) return;
    self.owned = NO;
    if (![self matchesPlayback]) return;
    [self.session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    [self.session setCategory:self.previousCategory mode:self.previousMode options:self.previousOptions error:nil];
}
- (void)dealloc { [self end]; }
@end
