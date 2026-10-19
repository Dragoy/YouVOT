#import "VOTSettings.h"
#import "VOTLanguage.h"
#import <Security/Security.h>

NSNotificationName const VOTSettingsDidChangeNotification = @"YouVOTSettingsDidChange";
NSString *const VOTChangedKey = @"key";
NSNotificationName const VOTTranslationStateDidChangeNotification = @"YouVOTTranslationStateDidChange";

static NSUserDefaults *Defaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

void VOTRegisterDefaults(void) {
    NSString *preferred = VOTNormalizeLanguage([NSLocale preferredLanguages].firstObject);
    [Defaults() registerDefaults:@{
        VOTUploadAudioKey: @YES,
        VOTAutoTranslateKey: @NO,
        VOTRequestLangKey: @"auto",
        VOTResponseLangKey: [VOTResponseLanguages() containsObject:preferred] ? preferred : @"ru",
        VOTDontTranslateKey: @[],
        VOTOriginalVolumeKey: @0.2f,
        VOTTranslationVolumeKey: @1.0f,
        VOTVoiceTypeKey: @"standard",
        VOTShortsAutoTranslateKey: @NO,
        VOTShortsButtonKey: @YES,
    }];
}

void VOTSetSetting(NSString *key, id value) {
    [Defaults() setObject:value forKey:key];
    [[NSNotificationCenter defaultCenter] postNotificationName:VOTSettingsDidChangeNotification object:nil userInfo:@{VOTChangedKey: key}];
}

BOOL VOTAutoTranslate(void) {
    return [Defaults() boolForKey:VOTAutoTranslateKey];
}

BOOL VOTUploadAudio(void) {
    return [Defaults() boolForKey:VOTUploadAudioKey];
}

NSString *VOTRequestLang(void) {
    NSString *lang = [Defaults() stringForKey:VOTRequestLangKey];
    return [VOTRequestLanguages() containsObject:lang] ? lang : @"auto";
}

NSString *VOTResponseLang(void) {
    NSString *lang = [Defaults() stringForKey:VOTResponseLangKey];
    return [VOTResponseLanguages() containsObject:lang] ? lang : @"ru";
}

NSArray<NSString *> *VOTDontTranslateLanguages(void) {
    NSArray *languages = [Defaults() arrayForKey:VOTDontTranslateKey];
    NSMutableArray *result = [NSMutableArray array];
    for (id language in languages) {
        if ([language isKindOfClass:[NSString class]]) [result addObject:language];
    }
    return result;
}

float VOTOriginalVolume(void) {
    return [Defaults() floatForKey:VOTOriginalVolumeKey];
}

float VOTTranslationVolume(void) {
    return [Defaults() floatForKey:VOTTranslationVolumeKey];
}

BOOL VOTLivelyVoice(void) {
    return [[Defaults() stringForKey:VOTVoiceTypeKey] isEqualToString:@"lively"];
}

BOOL VOTShortsAutoTranslate(void) {
    return [Defaults() boolForKey:VOTShortsAutoTranslateKey];
}

BOOL VOTShortsButton(void) {
    return [Defaults() boolForKey:VOTShortsButtonKey];
}

#pragma mark Account

static NSString *const kVOTKeychainService = @"YouVOT";
static NSString *const kVOTKeychainAccount = @"yandex-oauth";
static NSString *const kVOTAccountExpiresKey = @"YouVOTAccountExpires";

static NSDictionary *KeychainQuery(void) {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kVOTKeychainService,
        (__bridge id)kSecAttrAccount: kVOTKeychainAccount,
    };
}

NSDate *VOTAccountExpiration(void) {
    double expires = [Defaults() doubleForKey:kVOTAccountExpiresKey];
    return expires > 0 ? [NSDate dateWithTimeIntervalSince1970:expires] : nil;
}

NSString *VOTAccountToken(void) {
    NSDate *expiration = VOTAccountExpiration();
    if (!expiration || [expiration timeIntervalSinceNow] <= 0) return nil;
    NSMutableDictionary *query = [KeychainQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
    NSData *data = (__bridge_transfer NSData *)result;
    NSString *token = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return token.length ? token : nil;
}

void VOTSetAccountToken(NSString *token, NSTimeInterval expiresIn) {
    SecItemDelete((__bridge CFDictionaryRef)KeychainQuery());
    NSMutableDictionary *item = [KeychainQuery() mutableCopy];
    item[(__bridge id)kSecValueData] = [token dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    [Defaults() setDouble:[[NSDate date] timeIntervalSince1970] + expiresIn forKey:kVOTAccountExpiresKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:VOTSettingsDidChangeNotification object:nil userInfo:@{VOTChangedKey: VOTAccountKey}];
}

void VOTSignOut(void) {
    SecItemDelete((__bridge CFDictionaryRef)KeychainQuery());
    [Defaults() removeObjectForKey:kVOTAccountExpiresKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:VOTSettingsDidChangeNotification object:nil userInfo:@{VOTChangedKey: VOTAccountKey}];
}

static NSBundle *localizationBundle;

void VOTSetLocalizationBundle(NSBundle *bundle) {
    localizationBundle = bundle;
}

NSString *VOTLocalized(NSString *key) {
    return [localizationBundle localizedStringForKey:key value:nil table:nil] ?: key;
}
