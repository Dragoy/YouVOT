#import "VOTYouTubeAudio.h"
#import "VOTYandexClient.h"
#import "VOTLanguage.h"

// The ANDROID_VR InnerTube client returns plain stream URLs without a PO token,
// which is why yt-dlp uses it as a default client too.
static NSString *const kVOTInnerTubeClientName = @"ANDROID_VR";
static NSString *const kVOTInnerTubeClientId = @"28";
static NSString *const kVOTInnerTubeClientVersion = @"1.65.10";
static NSString *const kVOTInnerTubeUserAgent = @"com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";

@implementation VOTYouTubeAudioFormat
@end

@implementation VOTYouTubeAudio {
    NSURLSession *_session;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 30;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (NSDictionary *)playerResponseForVideoID:(NSString *)videoID error:(NSError **)error {
    NSDictionary *payload = @{
        @"context": @{
            @"client": @{
                @"clientName": kVOTInnerTubeClientName,
                @"clientVersion": kVOTInnerTubeClientVersion,
                @"deviceMake": @"Oculus",
                @"deviceModel": @"Quest 3",
                @"androidSdkVersion": @32,
                @"osName": @"Android",
                @"osVersion": @"12L",
                @"hl": @"en",
            },
        },
        @"videoId": videoID,
        @"contentCheckOk": @YES,
        @"racyCheckOk": @YES,
    };
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:kVOTInnerTubeUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:kVOTInnerTubeClientId forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:kVOTInnerTubeClientVersion forHTTPHeaderField:@"X-YouTube-Client-Version"];

    NSHTTPURLResponse *response = nil;
    NSError *requestError = nil;
    NSData *data = VOTPerformRequest(_session, request, &response, &requestError);
    if (!data || response.statusCode != 200) {
        if (error) *error = requestError ?: VOTMakeError(response.statusCode, @"YouTube player request failed");
        return nil;
    }
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) *error = VOTMakeError(-1, @"YouTube player response is not JSON");
        return nil;
    }
    NSString *playability = json[@"playabilityStatus"][@"status"];
    if (![playability isEqual:@"OK"]) {
        NSString *reason = json[@"playabilityStatus"][@"reason"] ?: playability;
        if (error) *error = VOTMakeError(-1, [NSString stringWithFormat:@"YouTube: %@", reason ?: @"video is not playable"]);
        return nil;
    }
    return json;
}

- (VOTYouTubeAudioFormat *)audioFormatForVideoID:(NSString *)videoID error:(NSError **)error {
    NSDictionary *json = [self playerResponseForVideoID:videoID error:error];
    return json ? [self audioFormatFromPlayerResponse:json error:error] : nil;
}

- (VOTYouTubeAudioFormat *)audioFormatFromPlayerResponse:(NSDictionary *)json error:(NSError **)error {

    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    for (NSDictionary *format in json[@"streamingData"][@"adaptiveFormats"]) {
        if (![format isKindOfClass:[NSDictionary class]]) continue;
        if (![format[@"mimeType"] hasPrefix:@"audio/"] || ![format[@"url"] length]) continue;
        // Skip dynamic range compressed variants, like the extension's isDrcAudioFormat()
        if ([format[@"isDrc"] boolValue] || [format[@"xtags"] containsString:@"drc=1"] || [format[@"url"] containsString:@"drc%3D1"] || [format[@"url"] containsString:@"drc=1"]) continue;
        [candidates addObject:format];
    }
    // Multi-language videos: Yandex must get the original speech, never a dub
    NSArray *original = [candidates filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *format, NSDictionary *bindings) {
        return VOTInnerTubeAudioTrackKind(format) == VOTAudioTrackKindOriginal;
    }]];
    NSArray *notDubbed = [candidates filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *format, NSDictionary *bindings) {
        return VOTInnerTubeAudioTrackKind(format) != VOTAudioTrackKindDubbed;
    }]];
    NSArray *defaults = [notDubbed filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *format, NSDictionary *bindings) {
        return [format[@"audioTrack"][@"audioIsDefault"] boolValue];
    }]];
    if (original.count) candidates = [original mutableCopy];
    else if (defaults.count) candidates = [defaults mutableCopy];
    else if (notDubbed.count) candidates = [notDubbed mutableCopy];
    // Same choice as selectSmallestAudioFormat() in the extension
    NSDictionary *best = nil;
    long long bestLength = LLONG_MAX;
    for (NSDictionary *format in candidates) {
        long long length = [format[@"contentLength"] longLongValue];
        if (length > 0 && length < bestLength) {
            best = format;
            bestLength = length;
        }
    }
    if (!best) {
        if (error) *error = VOTMakeError(-1, @"No downloadable audio stream");
        return nil;
    }
    VOTYouTubeAudioFormat *result = [VOTYouTubeAudioFormat new];
    result.url = best[@"url"];
    result.mimeType = best[@"mimeType"];
    result.itag = [best[@"itag"] integerValue];
    result.contentLength = bestLength;
    return result;
}

- (NSData *)downloadFormat:(VOTYouTubeAudioFormat *)format offset:(long long)offset length:(long long)length error:(NSError **)error {
    // googlevideo throttles plain GETs; ranged requests through the query parameter are served at full speed
    NSString *url = [NSString stringWithFormat:@"%@&range=%lld-%lld", format.url, offset, offset + length - 1];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:kVOTInnerTubeUserAgent forHTTPHeaderField:@"User-Agent"];
    request.timeoutInterval = 60;
    NSHTTPURLResponse *response = nil;
    NSError *requestError = nil;
    NSData *data = VOTPerformRequest(_session, request, &response, &requestError);
    if (!data || response.statusCode >= 300 || (long long)data.length != length) {
        if (error) *error = requestError ?: VOTMakeError(response.statusCode, @"Audio download failed");
        return nil;
    }
    return data;
}

@end
