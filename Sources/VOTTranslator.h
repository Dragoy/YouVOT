#import <Foundation/Foundation.h>

@class VOTTranslator;
@class VOTVideoLanguage;

typedef NS_ENUM(NSInteger, VOTVoiceFallback) {
    VOTVoiceFallbackNeedsAccount,    // Yandex has no lively voices for this video yet and wants a signed-in account
    VOTVoiceFallbackAccountExpired,  // the saved account token was rejected
    VOTVoiceFallbackUnavailable,     // lively voices are not available for this video or language pair
};

// All delegate callbacks arrive on the main queue and never after -cancel.
@protocol VOTTranslatorDelegate <NSObject>
- (void)translator:(VOTTranslator *)translator didDetectLanguage:(NSString *)language;
// The video is in a language the user does not want translated, or (for auto-translate)
// its language could not be detected reliably (language is nil); the translator has stopped
- (void)translator:(VOTTranslator *)translator didSkipVideoInLanguage:(NSString *)language;
- (void)translator:(VOTTranslator *)translator didReceiveAudioURL:(NSURL *)url complete:(BOOL)complete livelyVoice:(BOOL)livelyVoice;
// Lively voices were requested but the regular voice-over is used instead
- (void)translator:(VOTTranslator *)translator didFallBackToStandardVoice:(VOTVoiceFallback)reason;
- (void)translator:(VOTTranslator *)translator isWaitingWithRemainingTime:(NSInteger)seconds;
- (void)translatorIsUploadingAudio:(VOTTranslator *)translator;
- (void)translator:(VOTTranslator *)translator didFailWithError:(NSError *)error;
@end

@interface VOTTranslator : NSObject
@property (nonatomic, weak) id<VOTTranslatorDelegate> delegate;
@property (nonatomic, readonly, copy) NSString *videoID;
// requestLang is "auto" or a forced source language.
// videoLanguage holds what the YouTube app already knows about the video (may be empty).
// skipLanguages: if the video is detected to be in one of them, nothing is translated.
- (instancetype)initWithVideoID:(NSString *)videoID
                       duration:(double)duration
                    requestLang:(NSString *)requestLang
                   responseLang:(NSString *)responseLang
                  videoLanguage:(VOTVideoLanguage *)videoLanguage
                  skipLanguages:(NSSet<NSString *> *)skipLanguages
                      automatic:(BOOL)automatic
                    livelyVoice:(BOOL)livelyVoice
                     oauthToken:(NSString *)oauthToken
                    uploadAudio:(BOOL)uploadAudio;
- (void)start;
- (void)cancel;
@end
