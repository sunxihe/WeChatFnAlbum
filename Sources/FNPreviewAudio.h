#import <AVFoundation/AVFoundation.h>
// A narrow session interface permits tests without changing the simulator's audio device.
@protocol FNPreviewAudioSession <NSObject>
@property(nonatomic, readonly) AVAudioSessionCategory category;
@property(nonatomic, readonly) AVAudioSessionMode mode;
@property(nonatomic, readonly) AVAudioSessionCategoryOptions categoryOptions;
- (BOOL)setCategory:(AVAudioSessionCategory)category mode:(AVAudioSessionMode)mode
            options:(AVAudioSessionCategoryOptions)options error:(NSError **)error;
- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)error;
@end
@interface FNPreviewAudio : NSObject
- (instancetype)initWithSession:(id<FNPreviewAudioSession>)session;
- (BOOL)begin:(NSError **)error;
// Call after pausing the player. Never restore over a new host recording/call configuration.
- (void)end;
@end
