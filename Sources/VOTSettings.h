#import <Foundation/Foundation.h>

#define VOTAutoTranslateKey @"YouVOTAutoTranslate"
#define VOTUploadAudioKey @"YouVOTUploadAudio"
#define VOTRequestLangKey @"YouVOTRequestLang"
#define VOTResponseLangKey @"YouVOTResponseLang"
#define VOTDontTranslateKey @"YouVOTDontTranslateLanguages"
#define VOTOriginalVolumeKey @"YouVOTOriginalVolume"
#define VOTTranslationVolumeKey @"YouVOTTranslationVolume"
#define VOTVoiceTypeKey @"YouVOTVoiceType"
#define VOTShortsAutoTranslateKey @"YouVOTShortsAutoTranslate"
#define VOTShortsButtonKey @"YouVOTShortsButton"
// Posted through VOTSettingsDidChangeNotification when the user signs in or out
#define VOTAccountKey @"YouVOTAccount"

// Posted on the main queue; userInfo[VOTChangedKey] is the key that changed
FOUNDATION_EXPORT NSNotificationName const VOTSettingsDidChangeNotification;
FOUNDATION_EXPORT NSString *const VOTChangedKey;
// Posted on the main queue when the translation of the current video starts, becomes ready or stops
FOUNDATION_EXPORT NSNotificationName const VOTTranslationStateDidChangeNotification;

FOUNDATION_EXPORT void VOTRegisterDefaults(void);
FOUNDATION_EXPORT void VOTSetSetting(NSString *key, id value);

FOUNDATION_EXPORT BOOL VOTAutoTranslate(void);
FOUNDATION_EXPORT BOOL VOTUploadAudio(void);
// "auto" or a language from VOTRequestLanguages()
FOUNDATION_EXPORT NSString *VOTRequestLang(void);
// The user's language: what videos are translated to and never translated from
FOUNDATION_EXPORT NSString *VOTResponseLang(void);
// Extra languages the user understands; auto-translate skips them too
FOUNDATION_EXPORT NSArray<NSString *> *VOTDontTranslateLanguages(void);
FOUNDATION_EXPORT float VOTOriginalVolume(void);
FOUNDATION_EXPORT float VOTTranslationVolume(void);
// "Lively voices" (живые голоса): only for translations into Russian
FOUNDATION_EXPORT BOOL VOTLivelyVoice(void);
// Shorts are only auto-translated when this is on (off by default)
FOUNDATION_EXPORT BOOL VOTShortsAutoTranslate(void);
FOUNDATION_EXPORT BOOL VOTShortsButton(void);

// Yandex account (OAuth token from the same login flow as the extension), kept in the keychain
FOUNDATION_EXPORT NSString *VOTAccountToken(void); // nil when signed out or expired
FOUNDATION_EXPORT NSDate *VOTAccountExpiration(void);
FOUNDATION_EXPORT void VOTSetAccountToken(NSString *token, NSTimeInterval expiresIn);
FOUNDATION_EXPORT void VOTSignOut(void);

FOUNDATION_EXPORT void VOTSetLocalizationBundle(NSBundle *bundle);
FOUNDATION_EXPORT NSString *VOTLocalized(NSString *key);
