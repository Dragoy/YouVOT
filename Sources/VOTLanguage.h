#import <Foundation/Foundation.h>

// Same lists as availableLangs / availableTTS in vot.js
FOUNDATION_EXPORT NSArray<NSString *> *VOTRequestLanguages(void);
FOUNDATION_EXPORT NSArray<NSString *> *VOTResponseLanguages(void);

// "en-US" -> "en", "zh-Hans" -> "zh"; nil for empty or undetermined codes
FOUNDATION_EXPORT NSString *VOTNormalizeLanguage(NSString *code);
// Localized language name, e.g. "Английский"
FOUNDATION_EXPORT NSString *VOTLanguageName(NSString *code);

typedef NS_ENUM(NSInteger, VOTAudioTrackKind) {
    VOTAudioTrackKindDubbed = -1,   // dubbed, auto-dubbed or audio description
    VOTAudioTrackKindUnknown = 0,
    VOTAudioTrackKindOriginal = 1,
};

// Classifies a YouTube audio track by the "acont" xtag (plain "acont=original:lang=en"
// or base64 protobuf), the isAutoDubbed flag and the display name
FOUNDATION_EXPORT VOTAudioTrackKind VOTClassifyAudioTrack(NSString *xtags, NSString *url, NSString *displayName, BOOL isAutoDubbed);
// Kind of an InnerTube adaptiveFormats entry
FOUNDATION_EXPORT VOTAudioTrackKind VOTInnerTubeAudioTrackKind(NSDictionary *format);

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
// Language of the original audio track; nil when several tracks exist and none is marked original
@property (nonatomic, copy) NSString *audioTrackLanguage;
// Human readable list of the audio tracks, for the log
@property (nonatomic, copy) NSString *audioTracksSummary;
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
