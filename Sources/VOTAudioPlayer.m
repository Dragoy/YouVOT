#import "VOTAudioPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

// How far the voice track may drift from the video before we seek it back.
static const double kVOTMaxDrift = 0.6;

static NSHashTable *TranslationPlayers(void) {
    static NSHashTable *players;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        players = [NSHashTable weakObjectsHashTable];
    });
    return players;
}

@implementation VOTAudioPlayer {
    AVPlayer *_player;
    BOOL _needsSeek;
    BOOL _seeking;
    double _seekLatency;
}

+ (BOOL)isTranslationPlayer:(id)player {
    NSHashTable *players = TranslationPlayers();
    @synchronized (players) {
        return [players containsObject:player];
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _player = [AVPlayer new];
        NSHashTable *players = TranslationPlayers();
        @synchronized (players) {
            [players addObject:_player];
        }
        _player.automaticallyWaitsToMinimizeStalling = YES;
        _player.allowsExternalPlayback = NO;
        _volume = 1;
        _seekLatency = 0.25;
    }
    return self;
}

- (BOOL)hasAudio {
    return _player.currentItem != nil;
}

- (void)setVolume:(float)volume {
    _volume = volume;
    _player.volume = volume;
}

- (void)loadURL:(NSURL *)url {
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    // Keeps speech intelligible when the video is sped up or slowed down
    item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmTimeDomain;
    [_player pause];
    [_player replaceCurrentItemWithPlayerItem:item];
    _player.volume = _volume;
    _needsSeek = YES;
    _seeking = NO;
}

- (void)syncWithVideoTime:(double)videoTime rate:(float)rate playing:(BOOL)playing {
    AVPlayerItem *item = _player.currentItem;
    if (!item) return;
    if (!playing || rate <= 0) {
        [self pause];
        return;
    }
    if (item.status != AVPlayerItemStatusReadyToPlay || _seeking) return;

    double duration = CMTimeGetSeconds(item.duration);
    if (isfinite(duration) && duration > 0 && videoTime >= duration - 0.05) {
        // Partial translations (PART_CONTENT) end before the video does
        [self pause];
        return;
    }

    double drift = CMTimeGetSeconds(_player.currentTime) - videoTime;
    if (_needsSeek || fabs(drift) > kVOTMaxDrift * MAX(rate, 1.0f)) {
        _needsSeek = NO;
        _seeking = YES;
        double target = videoTime + _seekLatency * rate;
        CFTimeInterval started = CACurrentMediaTime();
        __weak VOTAudioPlayer *weakSelf = self;
        [_player seekToTime:CMTimeMakeWithSeconds(target, 600)
            toleranceBefore:CMTimeMakeWithSeconds(0.05, 600)
             toleranceAfter:CMTimeMakeWithSeconds(0.05, 600)
          completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                VOTAudioPlayer *strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf->_seeking = NO;
                if (finished) {
                    // Remember how long seeks take so the next one lands where the video will be
                    double latency = CACurrentMediaTime() - started;
                    strongSelf->_seekLatency = MIN(MAX(strongSelf->_seekLatency * 0.5 + latency * 0.5, 0.05), 1.5);
                }
            });
        }];
    }

    if (fabsf(_player.rate - rate) > 0.01f) {
        [_player playImmediatelyAtRate:rate];
    }
}

- (void)pause {
    if (_player.rate != 0) [_player pause];
}

- (void)stop {
    [_player pause];
    [_player replaceCurrentItemWithPlayerItem:nil];
    _needsSeek = NO;
    _seeking = NO;
}

@end
