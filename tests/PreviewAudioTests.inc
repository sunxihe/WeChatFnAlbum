// Audio device substitute: exercise ownership/failure paths without disturbing system audio.
@interface FNFixtureAudioSession : NSObject <FNPreviewAudioSession>
@property(nonatomic) AVAudioSessionCategory category;
@property(nonatomic) AVAudioSessionMode mode;
@property(nonatomic) AVAudioSessionCategoryOptions categoryOptions;
@property(nonatomic) BOOL failActivation;
@property(nonatomic) NSUInteger deactivations;
@end
@implementation FNFixtureAudioSession
- (instancetype)init {
    if ((self=[super init])) { _category=AVAudioSessionCategoryAmbient; _mode=AVAudioSessionModeDefault; }
    return self;
}
- (BOOL)setCategory:(AVAudioSessionCategory)category mode:(AVAudioSessionMode)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)error {
    self.category=category; self.mode=mode; self.categoryOptions=options; return YES;
}
- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)error {
    if (!active) self.deactivations++;
    if (active && self.failActivation) {
        if (error) *error=[NSError errorWithDomain:@"fixture" code:1 userInfo:nil];
        return NO;
    }
    return YES;
}
@end
static NSDictionary *PreviewAudioChecks(void) {
    NSMutableDictionary *checks=[NSMutableDictionary dictionary];
    FNFixtureAudioSession *session=[FNFixtureAudioSession new];
    FNPreviewAudio *scope=[[FNPreviewAudio alloc] initWithSession:session];
    checks[@"previewConfiguresAudiblePlayback"]=@([scope begin:nil] &&
        [session.category isEqual:AVAudioSessionCategoryPlayback] && [session.mode isEqual:AVAudioSessionModeMoviePlayback]);
    [scope begin:nil]; [scope end]; [scope end];
    checks[@"previewRestoresHostAudioOnce"]=@([session.category isEqual:AVAudioSessionCategoryAmbient] &&
        [session.mode isEqual:AVAudioSessionModeDefault] && session.deactivations==1);
    [scope begin:nil];
    session.category=AVAudioSessionCategoryPlayAndRecord; session.mode=AVAudioSessionModeVoiceChat;
    [scope end];
    checks[@"previewDoesNotOverwriteHostCall"]=@([session.category isEqual:AVAudioSessionCategoryPlayAndRecord] &&
        [session.mode isEqual:AVAudioSessionModeVoiceChat] && session.deactivations==1);
    NSError *error=nil;
    checks[@"previewRefusesCallTakeover"]=@(![scope begin:&error] && error &&
        [session.mode isEqual:AVAudioSessionModeVoiceChat]);
    session.category=AVAudioSessionCategoryAmbient; session.mode=AVAudioSessionModeDefault; session.failActivation=YES;
    error=nil;
    checks[@"previewActivationFailureRestoresHost"]=@(![scope begin:&error] && error &&
        [session.category isEqual:AVAudioSessionCategoryAmbient] && session.deactivations==1);
    session.failActivation=NO;
    @autoreleasepool {
        FNPreviewAudio *temporary=[[FNPreviewAudio alloc] initWithSession:session];
        [temporary begin:nil];
    }
    checks[@"previewAudioReleasedOnDestruction"]=@([session.category isEqual:AVAudioSessionCategoryAmbient] && session.deactivations==2);
    return checks;
}
