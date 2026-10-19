#import "VOTTranslator.h"
#import "VOTYandexClient.h"
#import "VOTYouTubeAudio.h"
#import "VOTLanguage.h"
#import "VOTLog.h"
#import <stdatomic.h>

// Same limits the extension uses: give up after a while instead of polling forever
static const NSTimeInterval kVOTTranslationTimeout = 20 * 60;
static const NSInteger kVOTRequestRetries = 3;
// A failed Yandex job with shouldRetry is dropped after a few minutes and the next
// request starts a new one, so keep asking for a while before giving up
static const NSInteger kVOTFailedJobRetries = 6;
static const NSTimeInterval kVOTFailedJobRetryDelay = 30;

static NSString *VOTStatusName(VOTTranslationStatus status) {
    switch (status) {
        case VOTTranslationStatusFailed: return @"FAILED";
        case VOTTranslationStatusFinished: return @"FINISHED";
        case VOTTranslationStatusWaiting: return @"WAITING";
        case VOTTranslationStatusLongWaiting: return @"LONG_WAITING";
        case VOTTranslationStatusPartContent: return @"PART_CONTENT";
        case VOTTranslationStatusAudioRequested: return @"AUDIO_REQUESTED";
        case VOTTranslationStatusSessionRequired: return @"SESSION_REQUIRED";
    }
    return [NSString stringWithFormat:@"%ld", (long)status];
}

static NSString *VOTSourceName(VOTLanguageSource source) {
    switch (source) {
        case VOTLanguageSourceAudioTrack: return @"audio track";
        case VOTLanguageSourceCaptions: return @"ASR captions";
        case VOTLanguageSourceText: return @"title/description";
        case VOTLanguageSourceYandex: return @"Yandex";
        default: return @"none";
    }
}

static VOTYandexClient *SharedClient(void) {
    static VOTYandexClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [VOTYandexClient new];
    });
    return client;
}

@implementation VOTTranslator {
    double _duration;
    NSString *_requestLang;
    NSString *_responseLang;
    BOOL _uploadAudio;
    BOOL _livelyVoice;
    BOOL _automatic;
    NSString *_oauthToken;
    VOTVideoLanguage *_videoLanguage;
    NSSet<NSString *> *_skipLanguages;
    NSDictionary *_playerResponse;
    VOTYouTubeAudio *_youtube;
    atomic_bool _cancelled;
}

- (instancetype)initWithVideoID:(NSString *)videoID duration:(double)duration requestLang:(NSString *)requestLang responseLang:(NSString *)responseLang videoLanguage:(VOTVideoLanguage *)videoLanguage skipLanguages:(NSSet<NSString *> *)skipLanguages automatic:(BOOL)automatic livelyVoice:(BOOL)livelyVoice oauthToken:(NSString *)oauthToken uploadAudio:(BOOL)uploadAudio {
    self = [super init];
    if (self) {
        _videoID = [videoID copy];
        _duration = duration;
        _requestLang = [requestLang copy];
        _responseLang = [responseLang copy];
        _videoLanguage = videoLanguage ?: [VOTVideoLanguage new];
        _skipLanguages = [skipLanguages copy] ?: [NSSet set];
        _youtube = [VOTYouTubeAudio new];
        _uploadAudio = uploadAudio;
        _automatic = automatic;
        // Same rule as isLivelyVoiceAllowed() in the extension: Russian voice-over only
        _livelyVoice = livelyVoice && [responseLang isEqualToString:@"ru"];
        _oauthToken = [oauthToken copy];
        atomic_init(&_cancelled, false);
    }
    return self;
}

- (BOOL)isCancelled {
    return atomic_load(&_cancelled);
}

- (void)cancel {
    atomic_store(&_cancelled, true);
}

- (void)start {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self run];
    });
}

- (void)notify:(void (^)(id<VOTTranslatorDelegate> delegate))block {
    dispatch_async(dispatch_get_main_queue(), ^{
        id<VOTTranslatorDelegate> delegate = self.delegate;
        if (!self.isCancelled && delegate) block(delegate);
    });
}

// Returns NO if cancelled while sleeping
- (BOOL)sleep:(NSTimeInterval)seconds {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        if (self.isCancelled) return NO;
        [NSThread sleepForTimeInterval:MIN(0.25, MAX([until timeIntervalSinceNow], 0))];
    }
    return !self.isCancelled;
}

- (NSString *)videoURL {
    return [@"https://youtu.be/" stringByAppendingString:_videoID];
}

// Returns NO when the video should not be translated
- (BOOL)checkLanguage:(NSString *)language {
    if (!language) return YES;
    [self notify:^(id<VOTTranslatorDelegate> delegate) {
        [delegate translator:self didDetectLanguage:language];
    }];
    if (![_skipLanguages containsObject:language]) return YES;
    [self notify:^(id<VOTTranslatorDelegate> delegate) {
        [delegate translator:self didSkipVideoInLanguage:language];
    }];
    return NO;
}

- (NSString *)detectLanguage {
    VOTLog(@"video %@: app metadata audio=%@ asr=%@ title=%@", _videoID, _videoLanguage.audioTrackLanguage ?: @"-", _videoLanguage.captionsLanguage ?: @"-", _videoLanguage.title.length ? @"yes" : @"no");
    // The YouTube app usually knows the audio track or the ASR captions language already;
    // otherwise ask InnerTube, which has both, before falling back to the title
    if (!_videoLanguage.audioTrackLanguage && !_videoLanguage.captionsLanguage) {
        NSError *error = nil;
        _playerResponse = [_youtube playerResponseForVideoID:_videoID error:&error];
        if (_playerResponse) {
            VOTVideoLanguage *innerTube = [VOTVideoLanguage languageFromInnerTubeResponse:_playerResponse];
            VOTLog(@"InnerTube metadata audio=%@ asr=%@", innerTube.audioTrackLanguage ?: @"-", innerTube.captionsLanguage ?: @"-");
            [_videoLanguage mergeMissingFrom:innerTube];
        } else {
            VOTLog(@"InnerTube metadata unavailable: %@", error.localizedDescription);
        }
    }
    NSString *language = _videoLanguage.language;
    VOTLog(@"detected language: %@ (%@)", language ?: @"unknown", VOTSourceName(_videoLanguage.source));
    return language;
}

- (void)run {
    VOTYandexClient *client = SharedClient();
    NSString *detected = [self detectLanguage];
    if (self.isCancelled || ![self checkLanguage:detected]) return;
    // Yandex happily "translates" a Russian video from English into Russian, so auto-translate
    // only starts on solid evidence of the spoken language. The title alone is not enough:
    // it is often in another language, and Shorts rarely have more than a title with hashtags.
    VOTLanguageSource source = _videoLanguage.source;
    // Languages Yandex cannot take as a source would go out as "auto" and come back garbled too
    if (_automatic && [_requestLang isEqualToString:@"auto"] && (!detected || source == VOTLanguageSourceText || ![VOTRequestLanguages() containsObject:detected])) {
        VOTLog(@"auto-translate skipped: the spoken language is not known reliably or not supported");
        [self notify:^(id<VOTTranslatorDelegate> delegate) {
            [delegate translator:self didSkipVideoInLanguage:nil];
        }];
        return;
    }
    // Like the extension: send the detected language. "auto" fails on some new videos,
    // so it is only used when nothing was detected, with English as the fallback.
    NSString *requestLang = _requestLang;
    if ([requestLang isEqualToString:@"auto"] && [VOTRequestLanguages() containsObject:detected]) requestLang = detected;
    BOOL checkedYandexLanguage = detected != nil;
    NSInteger failedJobRetries = kVOTFailedJobRetries;
    NSString *audioSentForTranslationId = nil;
    VOTLog(@"%@ translate %@ -> %@, duration %.0fs, skip %@, voice %@%@", _automatic ? @"auto" : @"manual", requestLang, _responseLang, _duration, [_skipLanguages.allObjects componentsJoinedByString:@","],
           _livelyVoice ? @"lively" : @"regular", _livelyVoice ? (_oauthToken ? @" (signed in)" : @" (no account)") : @"");

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kVOTTranslationTimeout];
    NSString *deliveredURL = nil;
    NSInteger failures = 0;
    VOTTranslationStatus lastStatus = -1;
    BOOL livelyDisabled = !_livelyVoice;

    while (!self.isCancelled) {
        if ([deadline timeIntervalSinceNow] < 0) {
            [self fail:VOTMakeError(-2, @"timeout")];
            return;
        }
        NSError *error = nil;
        // Lively voices need a known source language, "auto" is never sent with them
        BOOL useLively = !livelyDisabled && ![requestLang isEqualToString:@"auto"];
        VOTTranslationResponse *response = [client translateVideoURL:self.videoURL duration:_duration requestLang:requestLang responseLang:_responseLang
                                                          videoTitle:_videoLanguage.title livelyVoice:useLively oauthToken:_oauthToken error:&error];
        if (self.isCancelled) return;
        if (!response && useLively && _oauthToken && (error.code == 401 || error.code == 403)) {
            VOTLog(@"lively voice request rejected (HTTP %ld), using the regular voice", (long)error.code);
            livelyDisabled = YES;
            [self fallBackToStandardVoice:VOTVoiceFallbackAccountExpired];
            continue;
        }
        if (!response) {
            VOTLog(@"translate request failed: %@", error.localizedDescription);
            if (++failures >= kVOTRequestRetries) {
                [self fail:error];
                return;
            }
            if (![self sleep:3 * failures]) return;
            continue;
        }
        failures = 0;
        if (response.status != lastStatus || response.status == VOTTranslationStatusFailed) {
            VOTLog(@"Yandex: %@ remaining=%ld id=%@%@%@", VOTStatusName(response.status), (long)response.remainingTime, response.translationId ?: @"-",
                   response.message.length ? [@" message=" stringByAppendingString:response.message] : @"", response.shouldRetry ? @" shouldRetry" : @"");
            lastStatus = response.status;
        }
        if (useLively) {
            VOTVoiceFallback reason = -1;
            if (response.status == VOTTranslationStatusSessionRequired) reason = _oauthToken ? VOTVoiceFallbackAccountExpired : VOTVoiceFallbackNeedsAccount;
            // The extension's isLivelyVoiceUnavailableError(): "...обычная озвучка..."
            else if ([response.message.lowercaseString containsString:@"обычная озвучка"]) reason = VOTVoiceFallbackUnavailable;
            if (reason != (VOTVoiceFallback)-1) {
                VOTLog(@"lively voice unavailable (%ld), using the regular voice", (long)reason);
                livelyDisabled = YES;
                lastStatus = -1;
                [self fallBackToStandardVoice:reason];
                continue;
            }
        }
        if (!checkedYandexLanguage && response.language.length) {
            checkedYandexLanguage = YES;
            if (![self checkLanguage:VOTNormalizeLanguage(response.language)]) return;
        }

        switch (response.status) {
            case VOTTranslationStatusFinished:
            case VOTTranslationStatusPartContent: {
                BOOL complete = response.status == VOTTranslationStatusFinished && response.remainingTime < 1;
                NSURL *url = response.url.length ? [NSURL URLWithString:response.url] : nil;
                if (!url) {
                    [self fail:VOTMakeError(-1, @"Yandex did not return an audio link")];
                    return;
                }
                if (![response.url isEqualToString:deliveredURL]) {
                    deliveredURL = response.url;
                    BOOL lively = response.isLivelyVoice;
                    VOTLog(@"audio ready (%@ voice)%@", lively ? @"lively" : @"regular", complete ? @"" : @", partial");
                    [self notify:^(id<VOTTranslatorDelegate> delegate) {
                        [delegate translator:self didReceiveAudioURL:url complete:complete livelyVoice:lively];
                    }];
                }
                if (complete) return;
                // PART_CONTENT: ~10 minutes are ready, ask again for the rest later
                if (![self sleep:MIN(MAX(response.remainingTime, 10), 60)]) return;
                break;
            }
            case VOTTranslationStatusWaiting:
            case VOTTranslationStatusLongWaiting: {
                NSInteger remaining = response.remainingTime;
                [self notify:^(id<VOTTranslatorDelegate> delegate) {
                    [delegate translator:self isWaitingWithRemainingTime:remaining];
                }];
                if (![self sleep:MIN(MAX(remaining, 5), 30)]) return;
                break;
            }
            case VOTTranslationStatusAudioRequested: {
                // A new job (after a failed one) needs the audio again
                if ([audioSentForTranslationId isEqualToString:response.translationId]) {
                    if (![self sleep:10]) return;
                    break;
                }
                audioSentForTranslationId = response.translationId;
                [self notify:^(id<VOTTranslatorDelegate> delegate) {
                    [delegate translatorIsUploadingAudio:self];
                }];
                [self sendAudioForTranslationId:response.translationId client:client];
                break;
            }
            case VOTTranslationStatusSessionRequired:
                [self fail:VOTMakeError(VOTTranslationStatusSessionRequired, @"session required")];
                return;
            case VOTTranslationStatusFailed:
                if ([requestLang isEqualToString:@"auto"]) {
                    requestLang = @"en";
                    break;
                }
                if (response.shouldRetry && failedJobRetries-- > 0) {
                    if (![self sleep:kVOTFailedJobRetryDelay]) return;
                    break;
                }
                [self fail:VOTMakeError(VOTTranslationStatusFailed, response.message.length ? response.message : @"Yandex couldn't translate the video")];
                return;
            default:
                [self fail:VOTMakeError(VOTTranslationStatusFailed, response.message.length ? response.message : @"Yandex couldn't translate the video")];
                return;
        }
    }
}

- (void)sendAudioForTranslationId:(NSString *)translationId client:(VOTYandexClient *)client {
    if (_uploadAudio && [self uploadRealAudioForTranslationId:translationId client:client]) return;
    if (self.isCancelled) return;
    VOTLog(@"using the fallback without audio (the translation may take long)");
    // Fallback the extension also uses: tell Yandex we could not get the audio,
    // then the server fetches it on its own (slower, a few minutes).
    NSError *error = nil;
    [client requestFailAudioForVideoURL:self.videoURL error:&error];
    NSString *fileId = [@"fallback-empty-audio:video-translation:" stringByAppendingString:_videoID];
    [client uploadAudio:[NSData data] fileId:fileId videoURL:self.videoURL translationId:translationId error:&error];
}

- (BOOL)uploadRealAudioForTranslationId:(NSString *)translationId client:(VOTYandexClient *)client {
    VOTYouTubeAudio *youtube = _youtube;
    NSError *error = nil;
    VOTYouTubeAudioFormat *format = _playerResponse ? [youtube audioFormatFromPlayerResponse:_playerResponse error:&error] : nil;
    if (!format) format = [youtube audioFormatForVideoID:_videoID error:&error];
    if (!format) {
        VOTLog(@"audio source unavailable: %@", error.localizedDescription);
        return NO;
    }
    long long total = format.contentLength;
    // Typical audio is a few MB; refuse absurd sizes instead of filling memory
    VOTLog(@"audio itag %ld %@, %lld bytes", (long)format.itag, format.mimeType, total);
    if (total <= 0 || total > 200ll * 1024 * 1024) return NO;
    long long chunkSize = VOTMinChunkSize;
    NSInteger parts = (NSInteger)MAX(1, (total + chunkSize - 1) / chunkSize);

    // Download everything first, so a broken download never leaves a half-sent file
    // on the Yandex side mixed with the fallback request
    NSMutableArray<NSData *> *chunks = [NSMutableArray arrayWithCapacity:parts];
    for (NSInteger index = 0; index < parts; index++) {
        long long offset = index * chunkSize;
        long long length = MIN(chunkSize, total - offset);
        NSData *chunk = nil;
        for (NSInteger attempt = 0; attempt < kVOTRequestRetries && !chunk; attempt++) {
            if (self.isCancelled) return NO;
            if (attempt && ![self sleep:1.5 * attempt]) return NO;
            chunk = [youtube downloadFormat:format offset:offset length:length error:&error];
        }
        if (!chunk) {
            VOTLog(@"audio download failed at part %ld/%ld: %@", (long)index + 1, (long)parts, error.localizedDescription);
            return NO;
        }
        [chunks addObject:chunk];
    }

    NSString *fileId = [@"random-android_api-" stringByAppendingString:[NSUUID UUID].UUIDString.lowercaseString];
    for (NSInteger index = 0; index < parts; index++) {
        BOOL uploaded = NO;
        for (NSInteger attempt = 0; attempt < 5 && !uploaded; attempt++) {
            if (self.isCancelled) return NO;
            if (attempt && ![self sleep:1.5 * attempt]) return NO;
            // audioPartsLength is only sent with the last chunk, like the extension does
            uploaded = [client uploadAudioChunk:chunks[index] index:index partsLength:index == parts - 1 ? parts : 0 fileId:fileId videoURL:self.videoURL translationId:translationId error:&error];
        }
        VOTLog(@"audio part %ld/%ld (%lu bytes): %@", (long)index + 1, (long)parts, (unsigned long)chunks[index].length, uploaded ? @"sent" : error.localizedDescription);
        if (!uploaded) {
            // Some parts are already on the server: do not mix them with the fallback
            return YES;
        }
    }
    return YES;
}

- (void)fallBackToStandardVoice:(VOTVoiceFallback)reason {
    [self notify:^(id<VOTTranslatorDelegate> delegate) {
        [delegate translator:self didFallBackToStandardVoice:reason];
    }];
}

- (void)fail:(NSError *)error {
    NSError *reported = error ?: VOTMakeError(-1, @"Unknown error");
    VOTLog(@"failed: %@", reported.localizedDescription);
    [self notify:^(id<VOTTranslatorDelegate> delegate) {
        [delegate translator:self didFailWithError:reported];
    }];
}

@end
