#import "VOTYandexClient.h"
#import "VOTProtobuf.h"
#import "VOTLog.h"
#import <CommonCrypto/CommonHMAC.h>

NSErrorDomain const VOTErrorDomain = @"YouVOT";
NSUInteger const VOTMinChunkSize = 5295308;

// Keep in sync with FOSWLY/vot.js packages/shared/src/data/config.ts
static NSString *const kVOTHost = @"https://api.browser.yandex.ru";
static NSString *const kVOTUserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 YaBrowser/26.8.0.0 Safari/537.36";
static NSString *const kVOTComponentVersion = @"26.10.0.1796";
static NSString *const kVOTChromiumRevision = @"1796";
static NSString *const kVOTHMACKey = @"bt8xH3VOlb4mqf0nqAibnDOoiPlXsisf";

NSError *VOTMakeError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:VOTErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description ?: @"Unknown error"}];
}

NSData *VOTPerformRequest(NSURLSession *session, NSURLRequest *request, NSHTTPURLResponse **response, NSError **error) {
    __block NSData *result = nil;
    __block NSURLResponse *urlResponse = nil;
    __block NSError *requestError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        result = data;
        urlResponse = res;
        requestError = err;
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    if (response) *response = [urlResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)urlResponse : nil;
    if (error) *error = requestError;
    return result;
}

static NSString *VOTHexString(const uint8_t *bytes, size_t length) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:length * 2];
    for (size_t i = 0; i < length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static NSString *VOTSignature(NSData *body) {
    NSData *key = [kVOTHMACKey dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, body.bytes, body.length, digest);
    return VOTHexString(digest, sizeof(digest));
}

static NSString *VOTRandomUUID(void) {
    static const char hexDigits[] = "0123456789ABCDEF";
    char uuid[33];
    for (int i = 0; i < 32; i++) uuid[i] = hexDigits[arc4random_uniform(16)];
    uuid[32] = 0;
    return [NSString stringWithUTF8String:uuid];
}

@implementation VOTTranslationResponse
@end

@implementation VOTYandexClient {
    NSURLSession *_session;
    NSString *_sessionUUID;
    NSString *_secretKey;
    NSTimeInterval _sessionExpiresAt;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 30;
        configuration.HTTPShouldSetCookies = NO;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (NSMutableURLRequest *)requestWithPath:(NSString *)path method:(NSString *)method body:(NSData *)body {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kVOTHost stringByAppendingString:path]]];
    request.HTTPMethod = method;
    request.HTTPBody = body;
    NSString *shortVersion = [kVOTComponentVersion substringToIndex:MIN((NSUInteger)5, kVOTComponentVersion.length)];
    NSDictionary *headers = @{
        @"User-Agent": kVOTUserAgent,
        @"Accept": @"application/x-protobuf",
        @"Accept-Language": @"en",
        @"Content-Type": @"application/x-protobuf",
        @"Pragma": @"no-cache",
        @"Cache-Control": @"no-cache",
        @"sec-ch-ua": [NSString stringWithFormat:@"\"Not;A=Brand\";v=\"8\", \"Chromium\";v=\"150\", \"YaBrowser\";v=\"%@\", \"Yowser\";v=\"2.5\"", shortVersion],
        @"sec-ch-ua-full-version-list": [NSString stringWithFormat:@"\"Not;A=Brand\";v=\"8.0.0.0\", \"Chromium\";v=\"150.0.7871.%@\", \"YaBrowser\";v=\"%@\", \"Yowser\";v=\"2.5\"", kVOTChromiumRevision, kVOTComponentVersion],
        @"Sec-Fetch-Mode": @"no-cors",
    };
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    return request;
}

- (NSData *)send:(NSURLRequest *)request error:(NSError **)error {
    NSHTTPURLResponse *response = nil;
    NSError *requestError = nil;
    NSData *data = VOTPerformRequest(_session, request, &response, &requestError);
    if (requestError) {
        if (error) *error = requestError;
        return nil;
    }
    if (response.statusCode != 200) {
        if (error) *error = VOTMakeError(response.statusCode, [NSString stringWithFormat:@"Yandex API HTTP %ld (%@)", (long)response.statusCode, request.URL.path]);
        return nil;
    }
    return data ?: [NSData data];
}

- (BOOL)ensureSession:(NSError **)error {
    @synchronized (self) {
        if (_secretKey && [NSDate timeIntervalSinceReferenceDate] < _sessionExpiresAt) return YES;
        NSString *uuid = VOTRandomUUID();
        VOTPBWriter *writer = [VOTPBWriter new];
        [writer writeString:uuid field:1];
        [writer writeString:@"video-translation" field:2];
        NSMutableURLRequest *request = [self requestWithPath:@"/session/create" method:@"POST" body:writer.data];
        [request setValue:VOTSignature(writer.data) forHTTPHeaderField:@"Vtrans-Signature"];
        NSData *data = [self send:request error:error];
        if (!data) return NO;
        VOTPBMessage *message = VOTPBDecode(data);
        NSString *secretKey = VOTPBString(message, 1);
        if (!secretKey.length) {
            if (error) *error = VOTMakeError(-1, @"Yandex session was not created");
            return NO;
        }
        int64_t expires = VOTPBInt(message, 2, 3600);
        _sessionUUID = uuid;
        _secretKey = secretKey;
        // Renew a minute early so a long translation never runs with a stale key
        _sessionExpiresAt = [NSDate timeIntervalSinceReferenceDate] + MAX(expires - 60, 60);
        return YES;
    }
}

- (NSMutableURLRequest *)signedRequestWithPath:(NSString *)path method:(NSString *)method body:(NSData *)body error:(NSError **)error {
    if (![self ensureSession:error]) return nil;
    NSMutableURLRequest *request = [self requestWithPath:path method:method body:body];
    // https://github.com/FOSWLY/vot.js/issues/36
    NSString *token = [NSString stringWithFormat:@"%@:%@:%@", _sessionUUID, path, kVOTComponentVersion];
    NSString *tokenSign = VOTSignature([token dataUsingEncoding:NSUTF8StringEncoding]);
    [request setValue:VOTSignature(body) forHTTPHeaderField:@"Vtrans-Signature"];
    [request setValue:_secretKey forHTTPHeaderField:@"Sec-Vtrans-Sk"];
    [request setValue:[NSString stringWithFormat:@"%@:%@", tokenSign, token] forHTTPHeaderField:@"Sec-Vtrans-Token"];
    return request;
}

- (VOTTranslationResponse *)translateVideoURL:(NSString *)videoURL duration:(double)duration requestLang:(NSString *)requestLang responseLang:(NSString *)responseLang videoTitle:(NSString *)videoTitle livelyVoice:(BOOL)livelyVoice oauthToken:(NSString *)oauthToken error:(NSError **)error {
    VOTPBWriter *writer = [VOTPBWriter new];
    [writer writeString:videoURL field:3];
    [writer writeBool:YES field:5]; // firstRequest
    [writer writeDouble:duration > 0 ? duration : 310 field:6];
    [writer writeBool:YES field:7]; // unknown0
    [writer writeString:requestLang field:8];
    [writer writeString:responseLang field:14];
    [writer writeBool:YES field:15]; // unknown2
    [writer writeVarint:2 field:16]; // configVersion
    if (livelyVoice) [writer writeBool:YES field:18]; // useLivelyVoice
    if (videoTitle.length) [writer writeString:videoTitle field:19];
    NSMutableURLRequest *request = [self signedRequestWithPath:@"/video-translation/translate" method:@"POST" body:writer.data error:error];
    if (!request) return nil;
    // Like vot.js, the account token is only sent for lively voice requests
    if (livelyVoice && oauthToken.length) [request setValue:[@"OAuth " stringByAppendingString:oauthToken] forHTTPHeaderField:@"Authorization"];
    NSData *data = [self send:request error:error];
    if (!data) return nil;
    VOTPBMessage *message = VOTPBDecode(data);
    VOTTranslationResponse *response = [VOTTranslationResponse new];
    response.url = VOTPBString(message, 1);
    response.duration = VOTPBDouble(message, 2, 0);
    response.status = (VOTTranslationStatus)VOTPBInt(message, 4, VOTTranslationStatusFailed);
    response.remainingTime = (NSInteger)VOTPBInt(message, 5, -1);
    response.translationId = VOTPBString(message, 7);
    response.language = VOTPBString(message, 8);
    response.message = VOTPBString(message, 9);
    response.shouldRetry = VOTPBInt(message, 12, 0) == 1;
    response.isLivelyVoice = VOTPBInt(message, 10, 0) == 1;
    return response;
}

- (BOOL)requestFailAudioForVideoURL:(NSString *)videoURL error:(NSError **)error {
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"video_url": videoURL} options:0 error:nil];
    NSMutableURLRequest *request = [self requestWithPath:@"/video-translation/fail-audio-js" method:@"PUT" body:body];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSData *data = [self send:request error:error];
    if (!data) return NO;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]] || [json[@"status"] integerValue] != 1) {
        if (error) *error = VOTMakeError(-1, @"fail-audio-js request was rejected");
        return NO;
    }
    return YES;
}

- (BOOL)sendAudioRequest:(VOTPBWriter *)writer error:(NSError **)error {
    NSMutableURLRequest *request = [self signedRequestWithPath:@"/video-translation/audio" method:@"PUT" body:writer.data error:error];
    if (!request) return NO;
    request.timeoutInterval = 60;
    NSData *data = [self send:request error:error];
    if (!data) return NO;
    VOTPBMessage *message = VOTPBDecode(data);
    VOTLog(@"audio upload accepted: status=%lld remainingChunks=%lu", VOTPBInt(message, 1, -1), (unsigned long)VOTPBStrings(message, 2).count);
    return YES;
}

- (BOOL)uploadAudio:(NSData *)audio fileId:(NSString *)fileId videoURL:(NSString *)videoURL translationId:(NSString *)translationId error:(NSError **)error {
    VOTPBWriter *audioInfo = [VOTPBWriter new];
    [audioInfo writeString:fileId field:1];
    if (audio.length) [audioInfo writeBytes:audio field:2];
    VOTPBWriter *writer = [VOTPBWriter new];
    [writer writeString:translationId field:1];
    [writer writeString:videoURL field:2];
    [writer writeMessage:audioInfo field:6];
    return [self sendAudioRequest:writer error:error];
}

- (BOOL)uploadAudioChunk:(NSData *)chunk index:(NSInteger)index partsLength:(NSInteger)partsLength fileId:(NSString *)fileId videoURL:(NSString *)videoURL translationId:(NSString *)translationId error:(NSError **)error {
    VOTPBWriter *audioBuffer = [VOTPBWriter new];
    if (index) [audioBuffer writeVarint:index field:1];
    [audioBuffer writeBytes:chunk field:2];
    VOTPBWriter *partialAudio = [VOTPBWriter new];
    [partialAudio writeMessage:audioBuffer field:1];
    if (partsLength) [partialAudio writeVarint:partsLength field:2];
    [partialAudio writeString:fileId field:3];
    [partialAudio writeVarint:1 field:4]; // version
    VOTPBWriter *writer = [VOTPBWriter new];
    [writer writeString:translationId field:1];
    [writer writeString:videoURL field:2];
    [writer writeMessage:partialAudio field:4];
    return [self sendAudioRequest:writer error:error];
}

@end
