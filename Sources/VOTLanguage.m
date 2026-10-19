#import "VOTLanguage.h"
#import <NaturalLanguage/NaturalLanguage.h>

NSArray<NSString *> *VOTRequestLanguages(void) {
    return @[@"en", @"ru", @"zh", @"ko", @"ar", @"fr", @"it", @"es", @"de", @"ja"];
}

NSArray<NSString *> *VOTResponseLanguages(void) {
    return @[@"ru", @"en", @"kk"];
}

NSString *VOTNormalizeLanguage(NSString *code) {
    if (![code isKindOfClass:[NSString class]]) return nil;
    NSString *primary = [[code.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@"-"] componentsSeparatedByString:@"-"].firstObject;
    primary = [primary stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (primary.length < 2 || primary.length > 3 || [primary isEqualToString:@"und"]) return nil;
    return primary;
}

NSString *VOTLanguageName(NSString *code) {
    NSLocale *locale = [NSLocale currentLocale];
    NSString *name = [locale localizedStringForLanguageCode:code];
    return name.length ? [name capitalizedStringWithLocale:locale] : code;
}

// Safe KVC for the YouTube app's protobuf objects, whose layout changes between versions
static id VOTValue(id object, NSString *key) {
    if (!object || ![object respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (id exception) {
        return nil;
    }
}

static id VOTPath(id object, NSArray<NSString *> *keys) {
    for (NSString *key in keys) object = VOTValue(object, key);
    return object;
}

static NSString *VOTString(id value);

static BOOL VOTIsProtobufMessage(id object) {
    return object && [[object class] respondsToSelector:NSSelectorFromString(@"descriptor")];
}

// Walks a GPBMessage tree looking for an auto-generated (ASR) caption track. The property
// names of the app's protobuf classes are not stable, so the field list comes from the
// message descriptor instead of a fixed path.
static NSString *VOTFindASRLanguage(id object, NSInteger depth, NSInteger *budget) {
    if (depth < 0 || --(*budget) < 0 || !object) return nil;
    if ([object isKindOfClass:[NSArray class]]) {
        for (id item in object) {
            NSString *language = VOTFindASRLanguage(item, depth, budget);
            if (language) return language;
        }
        return nil;
    }
    if (!VOTIsProtobufMessage(object)) return nil;
    NSString *kind = VOTString(VOTValue(object, @"kind"));
    NSString *vssId = VOTString(VOTValue(object, @"vssId"));
    NSString *languageCode = VOTString(VOTValue(object, @"languageCode"));
    if (languageCode && ([kind isEqualToString:@"asr"] || [vssId hasPrefix:@"a."])) return VOTNormalizeLanguage(languageCode);
    NSArray *fields = nil;
    @try {
        fields = [[[object class] valueForKey:@"descriptor"] valueForKey:@"fields"];
    } @catch (id exception) {
        return nil;
    }
    for (id field in [fields isKindOfClass:[NSArray class]] ? fields : @[]) {
        NSString *name = nil;
        @try {
            name = [field valueForKey:@"name"];
        } @catch (id exception) {
            continue;
        }
        if (![name isKindOfClass:[NSString class]]) continue;
        // Unset message fields are created on access; ask has<Field> first where it exists
        NSString *hasKey = [NSString stringWithFormat:@"has%@%@", [[name substringToIndex:1] uppercaseString], [name substringFromIndex:1]];
        id has = VOTValue(object, hasKey);
        if (has && ![has boolValue]) continue;
        id value = VOTValue(object, name);
        if (![value isKindOfClass:[NSArray class]] && !VOTIsProtobufMessage(value)) continue;
        NSString *language = VOTFindASRLanguage(value, depth - 1, budget);
        if (language) return language;
    }
    return nil;
}

static NSString *VOTString(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

// "en.4" / "en-US.3" -> "en"
static NSString *VOTAudioTrackIdLanguage(NSString *trackId) {
    return VOTNormalizeLanguage([VOTString(trackId) componentsSeparatedByString:@"."].firstObject);
}

static NSString *VOTXtagsLanguage(NSString *url) {
    NSURLComponents *components = [NSURLComponents componentsWithString:url ?: @""];
    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isEqualToString:@"xtags"]) continue;
        for (NSString *tag in [item.value componentsSeparatedByString:@":"]) {
            if ([tag hasPrefix:@"lang="]) return VOTNormalizeLanguage([tag substringFromIndex:5]);
        }
    }
    return nil;
}

static NSString *VOTTextLanguage(NSString *text) {
    if (text.length < 12) return nil;
    NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
    [recognizer processString:text];
    NSDictionary<NLLanguage, NSNumber *> *hypotheses = [recognizer languageHypothesesWithMaximum:1];
    NLLanguage language = hypotheses.allKeys.firstObject;
    // Titles are often written in another language than the speech, so only trust a clear result
    if (!language || hypotheses[language].doubleValue < 0.8) return nil;
    return VOTNormalizeLanguage(language);
}

@implementation VOTVideoLanguage

+ (instancetype)languageFromPlayerResponse:(id)playerResponse {
    VOTVideoLanguage *result = [VOTVideoLanguage new];
    id playerData = VOTValue(playerResponse, @"playerData") ?: playerResponse;

    NSArray *formats = VOTPath(playerData, @[@"streamingData", @"adaptiveFormatsArray"]);
    if ([formats isKindOfClass:[NSArray class]]) {
        for (id format in formats) {
            if (VOTValue(format, @"hasAudioTrack") && ![VOTValue(format, @"hasAudioTrack") boolValue]) continue;
            id track = VOTValue(format, @"audioTrack");
            NSString *language = VOTAudioTrackIdLanguage(VOTValue(track, @"id_p"));
            if (!language) continue;
            if ([VOTValue(track, @"audioIsDefault") boolValue] || !result.audioTrackLanguage) result.audioTrackLanguage = language;
            if ([VOTValue(track, @"audioIsDefault") boolValue]) break;
        }
    }

    NSInteger budget = 400;
    id captions = VOTValue(playerData, @"captions");
    result.captionsLanguage = VOTFindASRLanguage(captions ?: playerData, captions ? 4 : 5, &budget);

    id details = VOTValue(playerData, @"videoDetails");
    result.title = VOTString(VOTValue(details, @"title"));
    result.videoDescription = VOTString(VOTValue(details, @"shortDescription"));
    return result;
}

+ (instancetype)languageFromInnerTubeResponse:(NSDictionary *)response {
    VOTVideoLanguage *result = [VOTVideoLanguage new];
    if (![response isKindOfClass:[NSDictionary class]]) return result;

    NSArray *formats = response[@"streamingData"][@"adaptiveFormats"];
    for (NSDictionary *format in [formats isKindOfClass:[NSArray class]] ? formats : @[]) {
        if (![format isKindOfClass:[NSDictionary class]] || ![format[@"mimeType"] hasPrefix:@"audio/"]) continue;
        NSDictionary *track = format[@"audioTrack"];
        NSString *language = [track isKindOfClass:[NSDictionary class]] ? VOTAudioTrackIdLanguage(track[@"id"]) : nil;
        language = language ?: VOTXtagsLanguage(format[@"url"]);
        if (!language) continue;
        BOOL isDefault = [track isKindOfClass:[NSDictionary class]] && [track[@"audioIsDefault"] boolValue];
        if (isDefault || !result.audioTrackLanguage) result.audioTrackLanguage = language;
        if (isDefault) break;
    }

    NSArray *captionTracks = response[@"captions"][@"playerCaptionsTracklistRenderer"][@"captionTracks"];
    for (NSDictionary *track in [captionTracks isKindOfClass:[NSArray class]] ? captionTracks : @[]) {
        if ([track isKindOfClass:[NSDictionary class]] && [track[@"kind"] isEqual:@"asr"]) {
            result.captionsLanguage = VOTNormalizeLanguage(track[@"languageCode"]);
            if (result.captionsLanguage) break;
        }
    }

    NSDictionary *details = response[@"videoDetails"];
    if ([details isKindOfClass:[NSDictionary class]]) {
        result.title = VOTString(details[@"title"]);
        result.videoDescription = VOTString(details[@"shortDescription"]);
    }
    return result;
}

- (void)mergeMissingFrom:(VOTVideoLanguage *)other {
    if (!self.audioTrackLanguage) self.audioTrackLanguage = other.audioTrackLanguage;
    if (!self.captionsLanguage) self.captionsLanguage = other.captionsLanguage;
    if (!self.title) self.title = other.title;
    if (!self.videoDescription) self.videoDescription = other.videoDescription;
}

- (VOTLanguageSource)source {
    if (self.audioTrackLanguage) return VOTLanguageSourceAudioTrack;
    if (self.captionsLanguage) return VOTLanguageSourceCaptions;
    if (self.textLanguage) return VOTLanguageSourceText;
    return VOTLanguageSourceNone;
}

- (NSString *)textLanguage {
    NSMutableArray *parts = [NSMutableArray array];
    if (self.title) [parts addObject:self.title];
    // The description adds context, but long ones are mostly links and hashtags
    if (self.videoDescription) [parts addObject:[self.videoDescription substringToIndex:MIN((NSUInteger)500, self.videoDescription.length)]];
    return VOTTextLanguage([parts componentsJoinedByString:@"\n"]);
}

- (NSString *)language {
    return self.audioTrackLanguage ?: self.captionsLanguage ?: self.textLanguage;
}

@end
