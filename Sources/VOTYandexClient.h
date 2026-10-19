#import <Foundation/Foundation.h>

// Native port of the Yandex provider from FOSWLY/vot.js (used by ilyhalight/voice-over-translation).
// All methods are synchronous: call them from a background queue.

FOUNDATION_EXPORT NSErrorDomain const VOTErrorDomain;
FOUNDATION_EXPORT NSUInteger const VOTMinChunkSize;

FOUNDATION_EXPORT NSData *VOTPerformRequest(NSURLSession *session, NSURLRequest *request, NSHTTPURLResponse **response, NSError **error);
FOUNDATION_EXPORT NSError *VOTMakeError(NSInteger code, NSString *description);

typedef NS_ENUM(NSInteger, VOTTranslationStatus) {
    VOTTranslationStatusFailed = 0,
    VOTTranslationStatusFinished = 1,
    VOTTranslationStatusWaiting = 2,
    VOTTranslationStatusLongWaiting = 3,
    VOTTranslationStatusPartContent = 5,
    VOTTranslationStatusAudioRequested = 6,
    VOTTranslationStatusSessionRequired = 7,
};

@interface VOTTranslationResponse : NSObject
@property (nonatomic, assign) VOTTranslationStatus status;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) NSInteger remainingTime;
@property (nonatomic, copy) NSString *translationId;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, assign) BOOL shouldRetry;
@property (nonatomic, assign) BOOL isLivelyVoice;
@end

@interface VOTYandexClient : NSObject
- (VOTTranslationResponse *)translateVideoURL:(NSString *)videoURL
                                     duration:(double)duration
                                  requestLang:(NSString *)requestLang
                                 responseLang:(NSString *)responseLang
                                   videoTitle:(NSString *)videoTitle
                                  livelyVoice:(BOOL)livelyVoice
                                   oauthToken:(NSString *)oauthToken
                                        error:(NSError **)error;
- (BOOL)requestFailAudioForVideoURL:(NSString *)videoURL error:(NSError **)error;
- (BOOL)uploadAudio:(NSData *)audio
             fileId:(NSString *)fileId
           videoURL:(NSString *)videoURL
      translationId:(NSString *)translationId
              error:(NSError **)error;
- (BOOL)uploadAudioChunk:(NSData *)chunk
                   index:(NSInteger)index
             partsLength:(NSInteger)partsLength
                  fileId:(NSString *)fileId
                videoURL:(NSString *)videoURL
           translationId:(NSString *)translationId
                   error:(NSError **)error;
@end
