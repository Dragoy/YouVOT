#import <Foundation/Foundation.h>

// Plays the translated voice track and keeps it aligned with the YouTube player.
// Main thread only.
@interface VOTAudioPlayer : NSObject
@property (nonatomic, assign) float volume;
@property (nonatomic, readonly) BOOL hasAudio;
// YES for the AVPlayer that plays the translation, so volume hooks leave it alone
+ (BOOL)isTranslationPlayer:(id)player;
- (void)loadURL:(NSURL *)url;
- (void)syncWithVideoTime:(double)videoTime rate:(float)rate playing:(BOOL)playing;
- (void)pause;
- (void)stop;
@end
