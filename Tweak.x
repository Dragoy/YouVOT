#import <PSHeader/Misc.h>
#import <YouTubeHeader/UIView+YouTube.h>
#import <YouTubeHeader/YTInlinePlayerBarContainerView.h>
#import <YouTubeHeader/YTMainAppControlsOverlayView.h>
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayView.h>
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <YouTubeHeader/YTQTMButton.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <YouTubeHeader/GOOHUDManagerInternal.h>
#import <YouTubeHeader/MLPlayerStickySettings.h>
#import <YouTubeHeader/YTColor.h>
#import <YouTubeHeader/YTHUDMessage.h>
#import <YouTubeHeader/YTIIcon.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTSingleVideoController.h>
#import <YouTubeHeader/YTSingleVideoTime.h>
#import "Sources/VOTAudioPlayer.h"
#import "Sources/VOTLanguage.h"
#import "Sources/VOTSettings.h"
#import "Sources/VOTSettingsViewController.h"
#import "Sources/VOTTranslator.h"

#define TweakKey @"YouVOT"

#define LOC(x) [tweakBundle localizedStringForKey:x value:nil table:nil]
#define OVERLAY_BUTTON_SIZE 24

// Newer YouTube versions group the fullscreen button with other right icons
@interface YTEnterExitFullscreenButtonView : UIView
- (YTQTMButton *)enterExitFullscreenButton;
@end

@interface YTInlinePlayerBarContainerView (YouVOTLayout)
- (YTEnterExitFullscreenButtonView *)enterExitFullscreenButton;
@end

// Settings category id, registered in the "Tweaks" group of YouGroupSettings when it is present
static const NSInteger YouVOTSection = 'yvot';

@interface YTMainAppControlsOverlayView (YouVOT)
- (void)didPressYouVOT:(id)arg;
@end

@interface YTInlinePlayerBarContainerView (YouVOT)
- (void)didPressYouVOT:(id)arg;
@end

@interface YTSettingsGroupData (YouVOT)
+ (NSMutableArray <NSNumber *> *)tweaks;
@end

@interface YTSettingsSectionItemManager (YouVOT)
- (void)updateYouVOTSectionWithEntry:(id)entry;
@end

static NSBundle *tweakBundle = nil;

static NSBundle *YouVOTBundle(void) {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:TweakKey ofType:@"bundle"];
        bundle = [NSBundle bundleWithPath:tweakBundlePath ?: PS_ROOT_PATH_NS(@"/Library/Application Support/" TweakKey ".bundle")];
    });
    return bundle;
}

static void ShowHUD(NSString *text) {
    Class manager = %c(GOOHUDManagerInternal), message = %c(YTHUDMessage);
    if (!manager || !message || !text.length) return;
    [[manager sharedInstance] showMessageMainThread:[message messageWithText:text]];
}

static UIViewController *TopViewController(UIView *view) {
    UIWindow *window = view.window;
    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) window = ((UIWindowScene *)scene).windows.firstObject;
            if (window) break;
        }
    }
    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed)
        presenter = presenter.presentedViewController;
    return presenter;
}

#pragma mark - Original audio ducking

// The YouTube player renders audio through AVSampleBufferAudioRenderer (HAM) or AVPlayer.
// We remember the volume YouTube asked for and scale it while a translation plays.
static float originalVolumeFactor = 1;
static const void *kBaseVolumeKey = &kBaseVolumeKey;

static NSHashTable *OriginalAudioOutputs(void) {
    static NSHashTable *outputs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        outputs = [NSHashTable weakObjectsHashTable];
    });
    return outputs;
}

static void TrackOriginalAudioOutput(id output) {
    if (!output || [VOTAudioPlayer isTranslationPlayer:output]) return;
    NSHashTable *outputs = OriginalAudioOutputs();
    @synchronized (outputs) {
        [outputs addObject:output];
    }
}

static float ScaledOriginalVolume(id output, float volume) {
    objc_setAssociatedObject(output, kBaseVolumeKey, @(volume), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TrackOriginalAudioOutput(output);
    if ([VOTAudioPlayer isTranslationPlayer:output]) return volume;
    return volume * originalVolumeFactor;
}

static void SetOriginalVolumeFactor(float factor) {
    if (fabsf(originalVolumeFactor - factor) < 0.001f) return;
    originalVolumeFactor = factor;
    NSHashTable *outputs = OriginalAudioOutputs();
    NSArray *snapshot;
    @synchronized (outputs) {
        snapshot = outputs.allObjects;
    }
    for (id output in snapshot) {
        if ([VOTAudioPlayer isTranslationPlayer:output] || ![output respondsToSelector:@selector(setVolume:)]) continue;
        NSNumber *base = objc_getAssociatedObject(output, kBaseVolumeKey);
        // Goes through our setVolume: hook, which applies the factor
        [(AVPlayer *)output setVolume:base ? base.floatValue : 1];
    }
}

#pragma mark - Playback rate

static float playbackRate = 1;
static BOOL playbackRateKnown = NO;

static void PlaybackRateDidChange(float rate) {
    if (rate <= 0) return;
    playbackRate = rate;
    playbackRateKnown = YES;
}

static float CurrentPlaybackRate(YTPlayerViewController *player) {
    if (playbackRateKnown) return playbackRate;
    @try {
        float sticky = player.activeVideo.mediaStickySettings.rate;
        if (sticky > 0) return sticky;
    } @catch (id ex) {}
    return 1;
}

#pragma mark - Player helpers

typedef NS_ENUM(NSInteger, YouVOTState) {
    YouVOTStateOff,
    YouVOTStateLoading,
    YouVOTStateOn,
};

static NSString *VideoIDOfPlayer(YTPlayerViewController *player) {
    NSString *videoID = nil;
    if ([player respondsToSelector:@selector(contentVideoID)]) videoID = [player contentVideoID];
    if (!videoID.length && [player respondsToSelector:@selector(currentVideoID)]) videoID = [player currentVideoID];
    return videoID.length ? videoID : nil;
}

static BOOL IsInlinePlayer(YTPlayerViewController *player) {
    return [player respondsToSelector:@selector(isInlinePlaybackActive)] && [player isInlinePlaybackActive];
}

static YTPlayerViewController *PlayerOfView(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:%c(YTPlayerViewController)]) return (YTPlayerViewController *)responder;
    }
    return nil;
}

// What the YouTube app itself knows about the video's language (audio tracks, ASR captions, title)
static VOTVideoLanguage *VideoLanguageOfPlayer(YTPlayerViewController *player, NSString *videoID) {
    @try {
        id playerResponse = player.activeVideo.singleVideo.playbackData.playerResponse;
        id details = [playerResponse respondsToSelector:@selector(playerData)] ? [[playerResponse playerData] videoDetails] : nil;
        NSString *responseVideoID = [details respondsToSelector:@selector(videoId)] ? [details videoId] : nil;
        // During ads or right after switching videos the response may belong to another video
        if (responseVideoID.length && ![responseVideoID isEqualToString:videoID]) return nil;
        return [VOTVideoLanguage languageFromPlayerResponse:playerResponse];
    } @catch (id ex) {
        return nil;
    }
}

static NSHashTable *ShortsPlayers(void) {
    static NSHashTable *players;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        players = [NSHashTable weakObjectsHashTable];
    });
    return players;
}

static YTPlayerViewController *PlayerOfReel(UIViewController *reel) {
    id player = nil;
    @try {
        player = [reel respondsToSelector:@selector(player)] ? [reel valueForKey:@"player"] : nil;
    } @catch (id ex) {}
    return [player isKindOfClass:%c(YTPlayerViewController)] ? player : nil;
}

// Shorts pages (YTReelPlayerViewController / YTShortsPlayerViewController) own a regular player
static BOOL IsShortsPlayer(YTPlayerViewController *player) {
    if (!player) return NO;
    if ([ShortsPlayers() containsObject:player]) return YES;
    for (UIViewController *controller = player.parentViewController; controller; controller = controller.parentViewController) {
        NSString *name = NSStringFromClass(controller.class);
        if ([name containsString:@"Reel"] || [name containsString:@"Shorts"]) return YES;
    }
    return NO;
}

static BOOL AutoTranslateAllowed(YTPlayerViewController *player) {
    return VOTAutoTranslate() && (!IsShortsPlayer(player) || VOTShortsAutoTranslate());
}

static void RefreshButtons(void);

#pragma mark - Controller

@interface YouVOTController : NSObject <VOTTranslatorDelegate>
@property (nonatomic, weak) YTPlayerViewController *player;
@property (nonatomic, weak) YTPlayerViewController *mainPlayer;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *dismissedVideoID;
@property (nonatomic, copy) NSString *detectedLanguage;
@property (nonatomic, copy) NSString *detectedLanguageVideoID;
@property (nonatomic, strong) VOTTranslator *translator;
@property (nonatomic, strong) VOTAudioPlayer *audio;
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic, assign) YouVOTState state;
@property (nonatomic, assign) BOOL automatic;
@property (nonatomic, assign) BOOL playingLively;
@property (nonatomic, assign) NSInteger waitingMinutes;
// Why the translation of statusNoteVideoID is off (skipped language or an error), shown in the settings
@property (nonatomic, copy) NSString *statusNote;
@property (nonatomic, copy) NSString *statusNoteVideoID;
@property (nonatomic, assign) BOOL pendingStart;
@property (nonatomic, assign) BOOL announcedWaiting;
@property (nonatomic, assign) BOOL announcedPlaying;
@property (nonatomic, assign) double lastVideoTime;
@property (nonatomic, assign) CFTimeInterval lastTick;
@property (nonatomic, assign) CFTimeInterval lastAdvance;
@property (nonatomic, assign) CFTimeInterval tickInterval;
@end

@implementation YouVOTController

+ (instancetype)shared {
    static YouVOTController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [YouVOTController new];
    });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _audio = [VOTAudioPlayer new];
        _tickInterval = 0.25;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsDidChange:) name:VOTSettingsDidChangeNotification object:nil];
    }
    return self;
}

- (BOOL)isActive {
    return self.state != YouVOTStateOff;
}

- (void)setState:(YouVOTState)state {
    if (_state == state) return;
    _state = state;
    RefreshButtons();
    [self postStateChange];
}

- (void)postStateChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:VOTTranslationStateDidChangeNotification object:nil];
}

- (VOTTranslationState)translationStateForPlayer:(YTPlayerViewController *)player {
    NSString *videoID = VideoIDOfPlayer(player);
    if (!videoID) return VOTTranslationStateNoVideo;
    if (![videoID isEqualToString:self.videoID]) return VOTTranslationStateOff;
    return self.state == YouVOTStateOn ? VOTTranslationStateOn : self.state == YouVOTStateLoading ? VOTTranslationStateLoading : VOTTranslationStateOff;
}

- (NSString *)translationStatusForPlayer:(YTPlayerViewController *)player {
    switch ([self translationStateForPlayer:player]) {
        case VOTTranslationStateNoVideo: return LOC(@"NO_VIDEO");
        case VOTTranslationStateOn:
            return [NSString stringWithFormat:@"%@ · %@", LOC(@"STATUS_PLAYING"), LOC(self.playingLively ? @"VOICE_LIVELY" : @"VOICE_STANDARD")];
        case VOTTranslationStateLoading:
            return self.waitingMinutes > 0 ? [NSString stringWithFormat:LOC(@"WAITING_MINUTES"), (long)self.waitingMinutes] : LOC(@"STATUS_LOADING");
        case VOTTranslationStateOff: {
            NSString *videoID = VideoIDOfPlayer(player);
            if (self.statusNote && [videoID isEqualToString:self.statusNoteVideoID]) return self.statusNote;
            return VOTAutoTranslate() ? LOC(@"STATUS_OFF_AUTO") : LOC(@"STATUS_OFF");
        }
    }
    return nil;
}

// The switch in the settings: a manual "off" only applies to this video, auto-translate stays on
- (void)setTranslationOn:(BOOL)on forPlayer:(YTPlayerViewController *)player {
    NSString *videoID = VideoIDOfPlayer(player);
    if (!videoID) return;
    BOOL activeHere = self.isActive && [videoID isEqualToString:self.videoID];
    if (on == activeHere) return;
    if (on) {
        self.dismissedVideoID = nil;
        [self startForPlayer:player videoID:videoID automatic:NO];
    } else {
        self.dismissedVideoID = videoID;
        [self stop];
    }
}

- (void)presentSettingsFromView:(UIView *)view player:(YTPlayerViewController *)player {
    VOTSettingsViewController *settings = [VOTSettingsViewController new];
    __weak YouVOTController *weakSelf = self;
    __weak YTPlayerViewController *weakPlayer = player;
    settings.translationStateProvider = ^VOTTranslationState {
        return [weakSelf translationStateForPlayer:weakPlayer];
    };
    settings.translationStatusProvider = ^NSString * {
        return [weakSelf translationStatusForPlayer:weakPlayer];
    };
    settings.translationToggleHandler = ^(BOOL on) {
        [weakSelf setTranslationOn:on forPlayer:weakPlayer];
    };
    settings.currentVideoLanguageProvider = ^NSString * {
        return weakSelf.currentVideoLanguage;
    };
    [settings presentFromViewController:TopViewController(view)];
}

// Language of the video on screen, if it was detected for that video
- (NSString *)currentVideoLanguage {
    NSString *videoID = VideoIDOfPlayer(self.mainPlayer);
    return videoID && [videoID isEqualToString:self.detectedLanguageVideoID] ? self.detectedLanguage : nil;
}

#pragma mark Lifecycle

- (void)toggleForPlayer:(YTPlayerViewController *)player {
    NSString *videoID = VideoIDOfPlayer(player);
    if (self.isActive && (!videoID || [videoID isEqualToString:self.videoID])) {
        self.dismissedVideoID = self.videoID;
        [self stop];
        ShowHUD(LOC(@"TRANSLATION_DISABLED"));
        return;
    }
    if (!player || !videoID) {
        ShowHUD(LOC(@"NO_VIDEO"));
        return;
    }
    self.dismissedVideoID = nil;
    [self startForPlayer:player videoID:videoID automatic:NO];
}

- (void)startForPlayer:(YTPlayerViewController *)player videoID:(NSString *)videoID automatic:(BOOL)automatic {
    [self stop];
    self.player = player;
    self.videoID = videoID;
    self.automatic = automatic;
    self.playingLively = NO;
    self.waitingMinutes = 0;
    self.statusNote = nil;
    self.announcedWaiting = NO;
    self.announcedPlaying = NO;
    self.state = YouVOTStateLoading;
    [self ensureWatchdog];
    double duration = [player currentVideoTotalMediaTime];
    if (duration > 0) [self launchTranslatorWithDuration:duration];
    else self.pendingStart = YES; // duration is unknown until the video loads
}

- (void)launchTranslatorWithDuration:(double)duration {
    self.pendingStart = NO;
    // Auto-translate stays silent until we know the video is in a foreign language
    if (!self.automatic) ShowHUD(LOC(@"TRANSLATING"));
    // Videos in the user's language are never translated. Auto-translate also skips the
    // extra languages the user understands; a tap on the button still translates them.
    NSMutableSet *skip = [NSMutableSet setWithObject:VOTResponseLang()];
    if (self.automatic) [skip addObjectsFromArray:VOTDontTranslateLanguages()];
    VOTTranslator *translator = [[VOTTranslator alloc] initWithVideoID:self.videoID
                                                              duration:duration
                                                           requestLang:VOTRequestLang()
                                                          responseLang:VOTResponseLang()
                                                         videoLanguage:VideoLanguageOfPlayer(self.player, self.videoID)
                                                         skipLanguages:skip
                                                             automatic:self.automatic
                                                           livelyVoice:VOTLivelyVoice()
                                                            oauthToken:VOTAccountToken()
                                                           uploadAudio:VOTUploadAudio()];
    translator.delegate = self;
    self.translator = translator;
    [translator start];
}

- (void)stop {
    [self.translator cancel];
    self.translator = nil;
    [self.audio stop];
    self.pendingStart = NO;
    self.videoID = nil;
    [self.watchdog invalidate];
    self.watchdog = nil;
    SetOriginalVolumeFactor(1);
    self.state = YouVOTStateOff;
}

- (void)restartIfActive {
    YTPlayerViewController *player = self.player;
    NSString *videoID = self.videoID;
    BOOL automatic = self.automatic;
    if (self.isActive && player && videoID) [self startForPlayer:player videoID:videoID automatic:automatic];
}

- (void)applyVolumes {
    self.audio.volume = VOTTranslationVolume();
    if (self.state == YouVOTStateOn) SetOriginalVolumeFactor(VOTOriginalVolume());
}

- (void)settingsDidChange:(NSNotification *)notification {
    NSString *key = notification.userInfo[VOTChangedKey];
    if ([key isEqualToString:VOTOriginalVolumeKey] || [key isEqualToString:VOTTranslationVolumeKey]) {
        [self applyVolumes];
    } else if ([key isEqualToString:VOTResponseLangKey] || [key isEqualToString:VOTRequestLangKey] || [key isEqualToString:VOTVoiceTypeKey] || [key isEqualToString:VOTAccountKey]) {
        [self restartIfActive];
    } else if ([key isEqualToString:VOTShortsButtonKey] || [key isEqualToString:VOTButtonPositionKey]) {
        RefreshButtons();
    } else if (([key isEqualToString:VOTAutoTranslateKey] || [key isEqualToString:VOTShortsAutoTranslateKey]) && !self.isActive && AutoTranslateAllowed(self.mainPlayer)) {
        YTPlayerViewController *player = self.mainPlayer;
        NSString *videoID = VideoIDOfPlayer(player);
        if (videoID && ![videoID isEqualToString:self.dismissedVideoID]) [self startForPlayer:player videoID:videoID automatic:YES];
    }
}

#pragma mark Player events

- (void)playerDidActivateVideo:(YTPlayerViewController *)player {
    if (IsInlinePlayer(player)) return;
    self.mainPlayer = player;
    NSString *videoID = VideoIDOfPlayer(player);
    if (!videoID) return;
    if (self.isActive && [videoID isEqualToString:self.videoID]) {
        self.player = player;
        return;
    }
    if (self.isActive) [self stop];
    // A manual "off" (or a skip because of the language) only sticks while the same video stays open
    if (![videoID isEqualToString:self.dismissedVideoID]) self.dismissedVideoID = nil;
    if (AutoTranslateAllowed(player) && !self.dismissedVideoID)
        [self startForPlayer:player videoID:videoID automatic:YES];
}

- (void)player:(YTPlayerViewController *)player timeDidChange:(double)time {
    if (!self.isActive) return;
    if (player != self.player) {
        // The overlay may have resolved another controller instance for the same video
        if (IsInlinePlayer(player) || ![VideoIDOfPlayer(player) isEqualToString:self.videoID]) return;
        self.player = player;
    }
    if (player.isPlayingAd) {
        [self.audio pause];
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastTick > 0) self.tickInterval = self.tickInterval * 0.8 + MIN(now - self.lastTick, 2.0) * 0.2;
    self.lastTick = now;
    if (fabs(time - self.lastVideoTime) > 0.001) self.lastAdvance = now;
    self.lastVideoTime = time;
    if (self.pendingStart) {
        double duration = [player currentVideoTotalMediaTime];
        if (duration > 0) [self launchTranslatorWithDuration:duration];
    }
    [self syncAudio];
}

- (void)ensureWatchdog {
    if (self.watchdog) return;
    __weak YouVOTController *weakSelf = self;
    self.watchdog = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        [weakSelf syncAudio];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.watchdog forMode:NSRunLoopCommonModes];
}

- (void)syncAudio {
    YTPlayerViewController *player = self.player;
    if (!player) {
        // The player was closed
        if (self.isActive) [self stop];
        return;
    }
    if (self.state != YouVOTStateOn) return;
    CFTimeInterval now = CACurrentMediaTime();
    // Time callbacks stop (or repeat the same value) while the video is paused or buffering
    BOOL playing = !player.isPlayingAd && self.lastAdvance > 0 && now - self.lastAdvance < MAX(0.6, self.tickInterval * 2.5);
    float rate = CurrentPlaybackRate(player);
    double videoTime = self.lastVideoTime + (playing ? (now - self.lastTick) * rate : 0);
    [self.audio syncWithVideoTime:videoTime rate:rate playing:playing];
}

#pragma mark VOTTranslatorDelegate

- (void)translator:(VOTTranslator *)translator didDetectLanguage:(NSString *)language {
    if (translator != self.translator) return;
    self.detectedLanguage = language;
    self.detectedLanguageVideoID = translator.videoID;
    [self postStateChange];
}

- (void)translator:(VOTTranslator *)translator didSkipVideoInLanguage:(NSString *)language {
    if (translator != self.translator) return;
    BOOL automatic = self.automatic;
    self.dismissedVideoID = translator.videoID;
    [self stop];
    // A nil language means auto-translate could not tell the spoken language for sure
    self.statusNote = language ? [NSString stringWithFormat:LOC(@"ALREADY_IN_LANGUAGE"), VOTLanguageName(language)] : LOC(@"SKIPPED_UNKNOWN_LANGUAGE");
    self.statusNoteVideoID = translator.videoID;
    [self postStateChange];
    if (!automatic) ShowHUD(self.statusNote);
}

- (void)translator:(VOTTranslator *)translator didReceiveAudioURL:(NSURL *)url complete:(BOOL)complete livelyVoice:(BOOL)livelyVoice {
    if (translator != self.translator) return;
    [self.audio loadURL:url];
    self.playingLively = livelyVoice;
    self.state = YouVOTStateOn;
    [self postStateChange];
    [self applyVolumes];
    if (!self.announcedPlaying) {
        self.announcedPlaying = YES;
        NSString *message = LOC(complete ? @"TRANSLATION_ENABLED" : @"TRANSLATION_PARTIAL");
        if (livelyVoice) message = [NSString stringWithFormat:@"%@ · %@", message, LOC(@"LIVELY_ON")];
        ShowHUD(message);
    }
    [self syncAudio];
}

- (void)translator:(VOTTranslator *)translator didFallBackToStandardVoice:(VOTVoiceFallback)reason {
    if (translator != self.translator) return;
    switch (reason) {
        case VOTVoiceFallbackNeedsAccount: ShowHUD(LOC(@"LIVELY_NEEDS_ACCOUNT")); break;
        case VOTVoiceFallbackAccountExpired: ShowHUD(LOC(@"LIVELY_ACCOUNT_EXPIRED")); break;
        case VOTVoiceFallbackUnavailable: ShowHUD(LOC(@"LIVELY_UNAVAILABLE")); break;
    }
}

- (void)translator:(VOTTranslator *)translator isWaitingWithRemainingTime:(NSInteger)seconds {
    if (translator != self.translator) return;
    NSInteger minutes = seconds > 0 ? MAX(1, (seconds + 59) / 60) : 0;
    if (minutes != self.waitingMinutes) {
        self.waitingMinutes = minutes;
        [self postStateChange];
    }
    if (self.announcedWaiting) return;
    self.announcedWaiting = YES;
    if (seconds > 0) {
        ShowHUD([NSString stringWithFormat:LOC(@"WAITING_MINUTES"), (long)minutes]);
    } else {
        ShowHUD(LOC(@"WAITING"));
    }
}

- (void)translatorIsUploadingAudio:(VOTTranslator *)translator {
    if (translator != self.translator) return;
    ShowHUD(LOC(@"UPLOADING_AUDIO"));
}

- (void)translator:(VOTTranslator *)translator didFailWithError:(NSError *)error {
    if (translator != self.translator) return;
    NSString *reason;
    BOOL ownError = [error.domain isEqualToString:@"YouVOT"];
    if (ownError && error.code == -2) reason = LOC(@"ERROR_TIMEOUT");
    else if (ownError && error.code == 7) reason = LOC(@"ERROR_SESSION_REQUIRED");
    else reason = error.localizedDescription;
    [self stop];
    self.statusNote = [NSString stringWithFormat:LOC(@"ERROR_FORMAT"), reason];
    self.statusNoteVideoID = translator.videoID;
    [self postStateChange];
    ShowHUD(self.statusNote);
}

#pragma mark Settings

// Long press on the player button turns the translation on or off without opening the settings
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    [self toggleForPlayer:PlayerOfView(gesture.view) ?: self.mainPlayer];
}

@end

#pragma mark - Overlay buttons

@interface YouVOTShortsButton : UIButton
@property (nonatomic, weak) UIViewController *reel;
@end

@implementation YouVOTShortsButton
@end

@interface YouVOTController (Shorts)
- (void)shortsButtonTapped:(YouVOTShortsButton *)button;
- (void)shortsButtonLongPressed:(UILongPressGestureRecognizer *)gesture;
@end

@implementation YouVOTController (Shorts)

- (void)shortsButtonTapped:(YouVOTShortsButton *)button {
    [self presentSettingsFromView:button player:PlayerOfReel(button.reel)];
}

- (void)shortsButtonLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    YouVOTShortsButton *button = (YouVOTShortsButton *)gesture.view;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    [self toggleForPlayer:PlayerOfReel(button.reel)];
}

@end

static NSHashTable *ButtonHosts(void) {
    static NSHashTable *hosts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hosts = [NSHashTable weakObjectsHashTable];
    });
    return hosts;
}

static UIImage *ButtonImageForState(YouVOTState state, CGFloat pointSize) {
    UIColor *color;
    switch (state) {
        case YouVOTStateOn:
            color = [UIColor colorWithRed:0.24 green:0.62 blue:1 alpha:1];
            break;
        case YouVOTStateLoading:
            color = [UIColor systemOrangeColor];
            break;
        default:
            color = [%c(YTColor) white1] ?: [UIColor whiteColor];
            break;
    }
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightMedium];
    UIImage *image = [UIImage systemImageNamed:@"translate" withConfiguration:configuration]
        ?: [UIImage systemImageNamed:@"character.bubble" withConfiguration:configuration];
    return [image imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
}

static UIImage *ButtonImage(void) {
    return ButtonImageForState([YouVOTController shared].state, OVERLAY_BUTTON_SIZE - 6);
}

#pragma mark Shorts button

static const void *kShortsButtonKey = &kShortsButtonKey;

static NSHashTable *ShortsButtons(void) {
    static NSHashTable *buttons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        buttons = [NSHashTable weakObjectsHashTable];
    });
    return buttons;
}

static void UpdateShortsButton(YouVOTShortsButton *button) {
    button.hidden = !VOTShortsButton();
    YouVOTState state = YouVOTStateOff;
    switch ([[YouVOTController shared] translationStateForPlayer:PlayerOfReel(button.reel)]) {
        case VOTTranslationStateOn: state = YouVOTStateOn; break;
        case VOTTranslationStateLoading: state = YouVOTStateLoading; break;
        default: break;
    }
    [button setImage:ButtonImageForState(state, 20) forState:UIControlStateNormal];
}

// Shorts have no player controls overlay, so add our own button under the top bar of each Shorts page
static void EnsureShortsButton(UIViewController *reel) {
    YTPlayerViewController *player = PlayerOfReel(reel);
    if (player) [ShortsPlayers() addObject:player];
    YouVOTShortsButton *button = objc_getAssociatedObject(reel, kShortsButtonKey);
    if (!button) {
        if (!VOTShortsButton() || !reel.isViewLoaded) return;
        button = [YouVOTShortsButton buttonWithType:UIButtonTypeCustom];
        button.reel = reel;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        button.layer.cornerRadius = 21;
        button.accessibilityLabel = @"Voice-over translation";
        [button addTarget:[YouVOTController shared] action:@selector(shortsButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [button addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:[YouVOTController shared] action:@selector(shortsButtonLongPressed:)]];
        UIView *view = reel.view;
        [view addSubview:button];
        [NSLayoutConstraint activateConstraints:@[
            [button.widthAnchor constraintEqualToConstant:42],
            [button.heightAnchor constraintEqualToConstant:42],
            [button.trailingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.trailingAnchor constant:-10],
            [button.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:64],
        ]];
        objc_setAssociatedObject(reel, kShortsButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [ShortsButtons() addObject:button];
    }
    if (button.superview) [button.superview bringSubviewToFront:button];
    UpdateShortsButton(button);
}

static const void *kLongPressKey = &kLongPressKey;
static const void *kOverlayButtonKey = &kOverlayButtonKey;

static void PrepareButton(UIButton *button) {
    if (!button || objc_getAssociatedObject(button, kLongPressKey)) return;
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:[YouVOTController shared] action:@selector(handleLongPress:)];
    [button addGestureRecognizer:longPress];
    objc_setAssociatedObject(button, kLongPressKey, longPress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark Player button

// Our own button in the player controls (the approach follows PoomSmart's YTVideoOverlay,
// MIT): top row of YTMainAppControlsOverlayView or next to the fullscreen button of
// YTInlinePlayerBarContainerView. Kept in an associated object so it coexists with
// builds that also ship YTVideoOverlay.
static YTQTMButton *OverlayButton(UIView *host) {
    return objc_getAssociatedObject(host, kOverlayButtonKey);
}

static void SetOverlayButton(UIView *host, YTQTMButton *button) {
    objc_setAssociatedObject(host, kOverlayButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ButtonHosts() addObject:host];
    PrepareButton(button);
}

static BOOL IsTopHost(UIView *host) {
    return [host isKindOfClass:%c(YTMainAppControlsOverlayView)];
}

static BOOL HostUsesButton(UIView *host) {
    return IsTopHost(host) ? VOTButtonOnTop() : !VOTButtonOnTop();
}

static void CreateTopButton(YTMainAppControlsOverlayView *self) {
    if (OverlayButton(self)) return;
    CGFloat padding = [[self class] respondsToSelector:@selector(topButtonAdditionalPadding)] ? [[self class] topButtonAdditionalPadding] : 0;
    YTQTMButton *button = [self buttonWithImage:ButtonImage() accessibilityLabel:@"Voice-over translation" verticalContentPadding:padding];
    button.hidden = YES;
    button.alpha = 0;
    [button addTarget:self action:@selector(didPressYouVOT:) forControlEvents:UIControlEventTouchUpInside];
    @try {
        [[self valueForKey:@"_topControlsAccessibilityContainerView"] addSubview:button];
    } @catch (id ex) {
        [self addSubview:button];
    }
    SetOverlayButton(self, button);
}

static void CreateBottomButton(YTInlinePlayerBarContainerView *self) {
    if (OverlayButton(self)) return;
    YTQTMButton *button = [%c(YTQTMButton) iconButton];
    [button setImage:ButtonImage() forState:UIControlStateNormal];
    [button sizeToFit];
    button.hidden = YES;
    button.alpha = 0;
    button.exclusiveTouch = YES;
    button.minHitTargetSize = 60;
    button.accessibilityLabel = @"Voice-over translation";
    [button addTarget:self action:@selector(didPressYouVOT:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:button];
    SetOverlayButton(self, button);
}

static NSMutableArray *InsertTopButton(YTMainAppControlsOverlayView *self, NSMutableArray *controls) {
    YTQTMButton *button = OverlayButton(self);
    if (!button || !VOTButtonOnTop() || [controls containsObject:button]) return controls;
    if (![controls isKindOfClass:[NSMutableArray class]]) controls = [controls mutableCopy] ?: [NSMutableArray array];
    [controls insertObject:button atIndex:0];
    return controls;
}

static void SetBottomButtonAlpha(YTInlinePlayerBarContainerView *self, CGFloat alpha) {
    if (!VOTButtonOnTop()) OverlayButton(self).alpha = alpha;
}

static void RefreshButtons(void) {
    UIImage *image = ButtonImage();
    for (UIView *host in ButtonHosts().allObjects) {
        YTQTMButton *button = OverlayButton(host);
        [button setImage:image forState:UIControlStateNormal];
        if (!HostUsesButton(host)) button.hidden = YES;
        [host setNeedsLayout];
    }
    for (YouVOTShortsButton *button in ShortsButtons().allObjects) UpdateShortsButton(button);
}

%group Shorts

%hook YTReelPlayerViewController

- (void)viewDidLayoutSubviews {
    %orig;
    EnsureShortsButton((UIViewController *)(id)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    EnsureShortsButton((UIViewController *)(id)self);
}

%end

%end

%group Top

%hook YTMainAppControlsOverlayView

- (id)initWithDelegate:(id)delegate {
    self = %orig;
    CreateTopButton(self);
    return self;
}

- (id)initWithDelegate:(id)delegate autoplaySwitchEnabled:(BOOL)autoplaySwitchEnabled {
    self = %orig;
    CreateTopButton(self);
    return self;
}

- (NSMutableArray *)topButtonControls {
    NSMutableArray *controls = %orig;
    return InsertTopButton(self, controls);
}

- (NSMutableArray *)topControls {
    NSMutableArray *controls = %orig;
    return InsertTopButton(self, controls);
}

- (void)setTopOverlayVisible:(BOOL)visible isAutonavCanceledState:(BOOL)canceledState {
    YTQTMButton *button = OverlayButton(self);
    button.alpha = VOTButtonOnTop() && visible && !canceledState ? 1 : 0;
    [button setImage:ButtonImage() forState:UIControlStateNormal];
    %orig;
}

%new(v@:@)
- (void)didPressYouVOT:(id)arg {
    [[YouVOTController shared] presentSettingsFromView:self player:PlayerOfView(self) ?: [YouVOTController shared].mainPlayer];
}

%end

%hook YTMainAppVideoPlayerOverlayViewController

- (void)updateTopRightButtonAvailability {
    %orig;
    YTMainAppControlsOverlayView *controls = nil;
    @try {
        controls = [[self videoPlayerOverlayView] valueForKey:@"_controlsOverlayView"];
    } @catch (id ex) {}
    OverlayButton(controls).hidden = !VOTButtonOnTop();
    [controls setNeedsLayout];
}

%end

%end

%group Bottom

%hook YTInlinePlayerBarContainerView

- (id)init {
    self = %orig;
    CreateBottomButton(self);
    return self;
}

- (NSMutableArray *)rightIcons {
    NSMutableArray *icons = %orig;
    YTQTMButton *button = OverlayButton(self);
    if (!button || VOTButtonOnTop() || [icons containsObject:button]) return icons;
    if (![icons isKindOfClass:[NSMutableArray class]]) icons = [icons mutableCopy] ?: [NSMutableArray array];
    [icons insertObject:button atIndex:0];
    return icons;
}

- (void)updateIconVisibility {
    %orig;
    YTQTMButton *button = OverlayButton(self);
    button.hidden = VOTButtonOnTop();
    [button setImage:ButtonImage() forState:UIControlStateNormal];
}

- (void)updateIconsHiddenAttribute {
    %orig;
    YTQTMButton *button = OverlayButton(self);
    button.hidden = VOTButtonOnTop();
    [button setImage:ButtonImage() forState:UIControlStateNormal];
}

- (void)hideScrubber {
    %orig;
    SetBottomButtonAlpha(self, 0);
}

- (void)setPeekableViewVisible:(BOOL)visible {
    %orig;
    SetBottomButtonAlpha(self, visible ? 1 : 0);
}

- (void)setPeekableViewVisible:(BOOL)visible fullscreenButtonVisibleShouldMatchPeekableView:(BOOL)match {
    %orig;
    SetBottomButtonAlpha(self, visible ? 1 : 0);
}

- (void)peekWithShowScrubber:(BOOL)scrubber setControlsAbovePlayerBarVisible:(BOOL)visible {
    %orig;
    SetBottomButtonAlpha(self, visible ? 1 : 0);
}

// Place the button left of the fullscreen button
- (void)layoutSubviews {
    %orig;
    YTQTMButton *button = OverlayButton(self);
    if (!button || VOTButtonOnTop()) return;
    UIView *peekableView = [self respondsToSelector:@selector(peekableView)] ? [self peekableView] : nil;
    BOOL fullscreenLayout = [self respondsToSelector:@selector(layout)] && self.layout == 3;
    // In fullscreen the right icons live in peekableView
    UIView *host = fullscreenLayout && peekableView ? peekableView : self;
    if (button.superview != host) {
        [button removeFromSuperview];
        [host addSubview:button];
    }
    CGFloat multiFeedWidth = [self respondsToSelector:@selector(multiFeedElementView)] ? [self multiFeedElementView].frame.size.width : 0;
    YTQTMButton *enter = [self respondsToSelector:@selector(enterFullscreenButton)] ? [self enterFullscreenButton] : nil;
    YTQTMButton *exit = [self respondsToSelector:@selector(exitFullscreenButton)] ? [self exitFullscreenButton] : nil;
    CGRect frame = CGRectZero;
    CGFloat buttonWidth = 0, imageWidth = 0, cornerRadius = 0;
    BOOL grouped = NO;
    if ([enter yt_isVisible]) {
        frame = enter.frame;
        imageWidth = enter.currentImage.size.width;
        cornerRadius = enter.layer.cornerRadius;
    } else if ([exit yt_isVisible]) {
        frame = exit.frame;
        imageWidth = exit.currentImage.size.width;
        cornerRadius = exit.layer.cornerRadius;
    } else if ([self respondsToSelector:@selector(enterExitFullscreenButton)]) {
        YTEnterExitFullscreenButtonView *enterExit = [self enterExitFullscreenButton];
        UIView *group = enterExit.superview;
        if (group && [enterExit yt_isVisible]) {
            grouped = YES;
            frame = [group convertRect:enterExit.frame toView:host];
            CGRect groupFrame = [group.superview convertRect:group.frame toView:host];
            imageWidth = [enterExit enterExitFullscreenButton].currentImage.size.width;
            cornerRadius = enterExit.layer.cornerRadius;
            multiFeedWidth = CGRectGetMinX(frame) - CGRectGetMinX(groupFrame);
        }
    }
    // The group may sit above the container's top edge
    if (CGRectIsEmpty(frame) || frame.origin.x <= 0 || (!grouped && frame.origin.y < -4)) return;
    buttonWidth = frame.size.width;
    CGFloat gap = buttonWidth > imageWidth ? 12 : buttonWidth;
    frame.origin.x = MAX(0, frame.origin.x - gap - multiFeedWidth - buttonWidth);
    // Builds that also ship YTVideoOverlay put its bottom buttons in the same spot; stay left of them
    NSDictionary *others = nil;
    if ([self respondsToSelector:NSSelectorFromString(@"overlayButtons")]) {
        @try {
            others = [self valueForKey:@"overlayButtons"];
        } @catch (id ex) {}
    }
    if ([others isKindOfClass:[NSDictionary class]]) {
        for (UIView *other in others.allValues) {
            if (![other isKindOfClass:[UIView class]] || other == button || other.hidden || other.superview != host) continue;
            if (fabs(CGRectGetMidY(other.frame) - CGRectGetMidY(frame)) > frame.size.height) continue;
            if (CGRectGetMinX(other.frame) - gap < CGRectGetMaxX(frame))
                frame.origin.x = MAX(0, MIN(frame.origin.x, CGRectGetMinX(other.frame) - gap - frame.size.width));
        }
    }
    button.layer.cornerRadius = cornerRadius;
    button.frame = frame;
}

%new(v@:@)
- (void)didPressYouVOT:(id)arg {
    [[YouVOTController shared] presentSettingsFromView:self player:PlayerOfView(self) ?: [YouVOTController shared].mainPlayer];
}

%end

%end

#pragma mark - YouTube settings

%group Settings

%hook YTSettingsGroupData

// Added by YouGroupSettings: put YouVOT into its "Tweaks" group
+ (NSMutableArray <NSNumber *> *)tweaks {
    NSMutableArray <NSNumber *> *tweaks = %orig;
    if (![tweaks containsObject:@(YouVOTSection)]) [tweaks addObject:@(YouVOTSection)];
    return tweaks;
}

// Without YouGroupSettings, show the section in the general settings group
- (NSArray <NSNumber *> *)orderedCategories {
    if (self.type != 1 || class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks)))
        return %orig;
    NSArray *original = %orig;
    NSMutableArray *categories = [original mutableCopy];
    if (![categories containsObject:@(YouVOTSection)]) [categories insertObject:@(YouVOTSection) atIndex:0];
    return categories.copy;
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray <NSNumber *> *)settingsCategoryOrder {
    NSArray <NSNumber *> *order = %orig;
    if ([order containsObject:@(YouVOTSection)]) return order;
    NSUInteger insertIndex = [order indexOfObject:@(1)];
    if (insertIndex == NSNotFound) return order;
    NSMutableArray <NSNumber *> *mutableOrder = [order mutableCopy];
    [mutableOrder insertObject:@(YouVOTSection) atIndex:insertIndex + 1];
    return mutableOrder.copy;
}

%end

%hook YTSettingsSectionItemManager

%new(v@:@)
- (void)updateYouVOTSectionWithEntry:(id)entry {
    YTSettingsViewController *settingsViewController = [self valueForKey:@"_settingsViewControllerDelegate"];
    Class itemClass = %c(YTSettingsSectionItem);
    NSMutableArray *items = [NSMutableArray array];
    BOOL (^openSettings)(YTSettingsCell *, NSUInteger) = ^BOOL (YTSettingsCell *cell, NSUInteger arg) {
        [VOTSettingsViewController presentFromViewController:settingsViewController currentVideoLanguage:[YouVOTController shared].currentVideoLanguage];
        return YES;
    };
    [items addObject:[itemClass itemWithTitle:LOC(@"MY_LANGUAGE")
                             titleDescription:nil
                      accessibilityIdentifier:nil
                              detailTextBlock:^NSString *{ return VOTLanguageName(VOTResponseLang()); }
                                  selectBlock:openSettings]];
    [items addObject:[itemClass switchItemWithTitle:LOC(@"AUTO_TRANSLATE")
                                   titleDescription:LOC(@"BEHAVIOR_FOOTER")
                            accessibilityIdentifier:nil
                                           switchOn:VOTAutoTranslate()
                                        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
                                            VOTSetSetting(VOTAutoTranslateKey, @(enabled));
                                            return YES;
                                        }
                                      settingItemId:0]];
    [items addObject:[itemClass itemWithTitle:LOC(@"OPEN_SETTINGS")
                             titleDescription:LOC(@"OPEN_SETTINGS_DESC")
                      accessibilityIdentifier:nil
                              detailTextBlock:nil
                                  selectBlock:openSettings]];
    NSString *title = LOC(@"SETTINGS_TITLE");
    if ([settingsViewController respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
        YTIIcon *icon = [%c(YTIIcon) new];
        icon.iconType = YT_TRANSLATE;
        [settingsViewController setSectionItems:items forCategory:YouVOTSection title:title icon:icon titleDescription:nil headerHidden:NO];
    } else {
        [settingsViewController setSectionItems:items forCategory:YouVOTSection title:title titleDescription:nil headerHidden:NO];
    }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == YouVOTSection) {
        [self updateYouVOTSectionWithEntry:entry];
        return;
    }
    %orig;
}

%end

%end

#pragma mark - Player hooks

%group Player

%hook YTPlayerViewController

- (void)playbackController:(id)controller didActivateVideo:(id)video withPlaybackData:(id)playbackData {
    %orig;
    [[YouVOTController shared] playerDidActivateVideo:self];
}

- (void)singleVideo:(id)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;
    [[YouVOTController shared] player:self timeDidChange:time.time];
}

- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;
    [[YouVOTController shared] player:self timeDidChange:time.time];
}

%end

%hook MLHAMQueuePlayer

- (void)setRate:(float)rate {
    %orig;
    PlaybackRateDidChange(rate);
}

%end

%hook MLAVPlayer

- (void)setRate:(float)rate {
    %orig;
    PlaybackRateDidChange(rate);
}

%end

%end

%group Ducking

%hook AVSampleBufferAudioRenderer

- (instancetype)init {
    self = %orig;
    TrackOriginalAudioOutput(self);
    if (self && originalVolumeFactor != 1) [self setVolume:1];
    return self;
}

- (void)setVolume:(float)volume {
    %orig(ScaledOriginalVolume(self, volume));
}

%end

%hook AVPlayer

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item {
    self = %orig;
    TrackOriginalAudioOutput(self);
    return self;
}

- (void)setVolume:(float)volume {
    %orig(ScaledOriginalVolume(self, volume));
}

%end

%end

%ctor {
    tweakBundle = YouVOTBundle();
    VOTSetLocalizationBundle(tweakBundle);
    VOTRegisterDefaults();
    %init(Top);
    %init(Bottom);
    %init(Settings);
    %init(Shorts);
    %init(Player);
    %init(Ducking);
}
