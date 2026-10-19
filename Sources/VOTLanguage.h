#import <Foundation/Foundation.h>

// Same lists as availableLangs / availableTTS in vot.js
FOUNDATION_EXPORT NSArray<NSString *> *VOTRequestLanguages(void);
FOUNDATION_EXPORT NSArray<NSString *> *VOTResponseLanguages(void);

// "en-US" -> "en", "zh-Hans" -> "zh"; nil for empty or undetermined codes
FOUNDATION_EXPORT NSString *VOTNormalizeLanguage(NSString *code);
// Localized language name, e.g. "Английский"
FOUNDATION_EXPORT NSString *VOTLanguageName(NSString *code);

typedef NS_ENUM(NSInteger, VOTLanguageSource) {
    VOTLanguageSourceNone,
    VOTLanguageSourceAudioTrack,   // default audio track of the video
    VOTLanguageSourceCaptions,     // YouTube auto-generated (ASR) captions = spoken language
    VOTLanguageSourceText,         // title and description, recognized on device
    VOTLanguageSourceYandex,       // reported back by the translation API
};

// The order of sources follows the extension's YoutubeHelper.getLanguage():
// audio track, then ASR captions, then text detection.
@interface VOTVideoLanguage : NSObject
@property (nonatomic, copy) NSString *audioTrackLanguage;
@property (nonatomic, copy) NSString *captionsLanguage;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *videoDescription;
@property (nonatomic, readonly) NSString *language;
@property (nonatomic, readonly) VOTLanguageSource source;
// Reads the player response objects of the YouTube app (GPBMessage) through KVC
+ (instancetype)languageFromPlayerResponse:(id)playerResponse;
// Reads an InnerTube /player JSON response
+ (instancetype)languageFromInnerTubeResponse:(NSDictionary *)response;
- (void)mergeMissingFrom:(VOTVideoLanguage *)other;
@end
