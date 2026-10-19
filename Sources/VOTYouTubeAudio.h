#import <Foundation/Foundation.h>

// Finds a direct audio-only stream of a YouTube video so it can be sent to Yandex
// when the server answers AUDIO_REQUESTED (the browser extension does the same in
// src/audioDownloader). Synchronous: call from a background queue.

@interface VOTYouTubeAudioFormat : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *mimeType;
@property (nonatomic, assign) NSInteger itag;
@property (nonatomic, assign) long long contentLength;
@end

@interface VOTYouTubeAudio : NSObject
// InnerTube /player response, only returned when the video is playable
- (NSDictionary *)playerResponseForVideoID:(NSString *)videoID error:(NSError **)error;
- (VOTYouTubeAudioFormat *)audioFormatFromPlayerResponse:(NSDictionary *)response error:(NSError **)error;
- (VOTYouTubeAudioFormat *)audioFormatForVideoID:(NSString *)videoID error:(NSError **)error;
- (NSData *)downloadFormat:(VOTYouTubeAudioFormat *)format offset:(long long)offset length:(long long)length error:(NSError **)error;
@end
