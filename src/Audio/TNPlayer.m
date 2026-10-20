#import "TNLegacyCollections.h"
#import "TNPlayer.h"
#import "TNPlaybackEngine.h"
#import "TNModels.h"
#import "TNYTMusic.h"
#import "TNLibrary.h"
#import "TNImageLoader.h"
#import "TNUtils.h"
#import "TNSettings.h"
#import "TNCommon.h"
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>

NSString * const TNPlayerDidChangeNotification = @"TNPlayerDidChangeNotification";
NSString * const TNPlayerDidFailNotification = @"TNPlayerDidFailNotification";

static const NSInteger TNRestartThresholdMs = 3000;    // "previous" after this restarts the song instead
static const NSInteger TNMaxSkipsOnError = 5;

@interface TNPlayer () <TNPlaybackEngineDelegate>
@property (nonatomic, strong) TNTrack *currentTrack;
@property (nonatomic, copy) NSString *currentVideoId;
@property (nonatomic) BOOL playing;
@property (nonatomic) BOOL loading;
@property (nonatomic, copy) NSString *contextURI;
@property (nonatomic, copy) NSString *contextName;
@property (nonatomic, strong) NSMutableArray *queue;          // user queue
@property (nonatomic, strong) NSDate *sleepAt;
@property (nonatomic) BOOL sleepAtEndOfSong;
@end

@implementation TNPlayer {
    NSArray *_contextTracks;
    NSMutableArray *_order;           // indices into _contextTracks, in play order
    NSInteger _orderPos;              // where the current context song is in _order (-1 none)
    BOOL _currentFromQueue;           // the current song came from the user queue
    NSUInteger _loadToken;            // bumps with every load: late answers are dropped
    TNTrack *_preparedTrack;          // the next song the engine got ready (gapless)
    NSUInteger _prepareToken;
    NSInteger _failures;
    TNPlaybackEngine *_engine;
    dispatch_queue_t _loadQueue;
    id _artworkToken;
    NSString *_artworkURL;
    UIImage *_artwork;
    BOOL _fetchingRadio;
    TNWatchQueue *_radio;             // the radio playing as the context (more of it comes when it runs low)
    TNHTTPTask *_radioMore;
    NSTimer *_sleepTimer;
    NSInteger _resumeMs;              // a restored song starts here (the place it was left at)
    BOOL _saveScheduled;
}

+ (instancetype)shared
{
    static TNPlayer *player;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ player = [[TNPlayer alloc] init]; });
    return player;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _queue = [NSMutableArray array];
        _order = [NSMutableArray array];
        _orderPos = -1;
        _loadQueue = dispatch_queue_create("com.samcejko.muzika.load", DISPATCH_QUEUE_CONCURRENT);
        _engine = [TNPlaybackEngine shared];
        _engine.delegate = self;
        [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateNowPlaying) userInfo:nil repeats:YES];
        // (the place in the song, every so often: iOS ends a background app without a word)
        [NSTimer scheduledTimerWithTimeInterval:20.0 target:self selector:@selector(saveWhilePlaying) userInfo:nil repeats:YES];
    }
    return self;
}

- (NSArray *)userQueue { return [self.queue copy]; }
- (BOOL)buffering { return self.loading || _engine.buffering; }
- (NSInteger)positionMs { return _engine.currentItem ? _engine.positionMs : _resumeMs; }
- (NSInteger)durationMs { return _engine.currentItem.durationMs ?: self.currentTrack.durationMs; }
- (NSString *)formatName { return _engine.currentItem.formatName; }

- (BOOL)isCurrent:(TNTrack *)track
{
    TNTrack *c = self.currentTrack;
    if (!c || !track) return NO;
    return c == track || [[c key] isEqualToString:[track key]];
}

- (void)changed
{
    [[NSNotificationCenter defaultCenter] postNotificationName:TNPlayerDidChangeNotification object:self];
    [self updateNowPlaying];
    [self scheduleSave];
}

#pragma mark - Context

static void TNShuffleArray(NSMutableArray *a)
{
    for (NSUInteger i = a.count; i > 1; i--) [a exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((u_int32_t)i)];
}

- (void)buildOrderStartingWith:(NSInteger)first
{
    [_order removeAllObjects];
    for (NSUInteger i = 0; i < _contextTracks.count; i++) [_order addObject:@(i)];
    if (self.shuffle) {
        TNShuffleArray(_order);
        if (first >= 0) {
            [_order removeObject:@(first)];
            [_order insertObject:@(first) atIndex:0];
        }
        _orderPos = first >= 0 ? 0 : -1;
    } else {
        _orderPos = first;
    }
}

- (void)playTracks:(NSArray *)tracks startingAt:(NSUInteger)index contextURI:(NSString *)uri contextName:(NSString *)name
{
    [self playTracks:tracks startingAt:index positionMs:0 paused:NO contextURI:uri contextName:name];
}

- (void)playTracks:(NSArray *)tracks startingAt:(NSUInteger)index positionMs:(NSInteger)positionMs paused:(BOOL)paused
        contextURI:(NSString *)uri contextName:(NSString *)name
{
    if (!tracks.count) return;
    if (![uri hasPrefix:@"radio:"]) { _radio = nil; [_radioMore cancel]; _radioMore = nil; }
    _contextTracks = [tracks copy];
    self.contextURI = uri;
    self.contextName = name;
    NSInteger start = (NSInteger)MIN(index, tracks.count - 1);
    // (a song that cannot play is passed over)
    if (![[tracks objectAtIndex:(NSUInteger)start] playable]) positionMs = 0;
    while (start < (NSInteger)tracks.count && ![[tracks objectAtIndex:(NSUInteger)start] playable]) start++;
    if (start >= (NSInteger)tracks.count) return;
    [self buildOrderStartingWith:start];
    _currentFromQueue = NO;
    _failures = 0;
    [self loadAndPlay:[tracks objectAtIndex:(NSUInteger)start] fromMs:positionMs paused:paused];
}

- (NSArray *)contextTracks { return _contextTracks ?: @[]; }

- (NSInteger)contextIndex
{
    return (_orderPos >= 0 && _orderPos < (NSInteger)_order.count && !_currentFromQueue) ? [[_order objectAtIndex:(NSUInteger)_orderPos] integerValue] : -1;
}

- (NSArray *)previousTracks:(NSUInteger)max
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger p = MAX(0, _orderPos - (NSInteger)max); p < _orderPos && p < (NSInteger)_order.count; p++) {
        [out addObject:[_contextTracks objectAtIndex:[[_order objectAtIndex:(NSUInteger)p] unsignedIntegerValue]]];
    }
    return out;
}

- (void)replaceQueue:(NSArray *)tracks
{
    [self.queue removeAllObjects];
    [self.queue addObjectsFromArray:tracks ?: @[]];
    [self dropPrepared];
    [self changed];
}

- (void)playTracksShuffled:(NSArray *)tracks contextURI:(NSString *)uri contextName:(NSString *)name
{
    if (!tracks.count) return;
    self.shuffle = YES;
    [self playTracks:tracks startingAt:arc4random_uniform((u_int32_t)tracks.count) contextURI:uri contextName:name];
}

- (void)setShuffle:(BOOL)shuffle
{
    if (_shuffle == shuffle) return;
    _shuffle = shuffle;
    // the order changes, the current song stays where it is
    NSInteger current = (_orderPos >= 0 && _orderPos < (NSInteger)_order.count) ? [[_order objectAtIndex:(NSUInteger)_orderPos] integerValue] : -1;
    [self buildOrderStartingWith:current];
    [self dropPrepared];
    [self changed];
}

- (void)setRepeat:(TNRepeatMode)repeat
{
    _repeat = repeat;
    [self dropPrepared];
    [self changed];
}

- (void)addToQueue:(TNTrack *)track
{
    if (!track) return;
    [self.queue addObject:track];
    [self dropPrepared];
    [self changed];
}

- (void)playNext:(TNTrack *)track
{
    if (!track) return;
    [self.queue insertObject:track atIndex:0];
    [self dropPrepared];
    [self changed];
}

- (void)removeFromQueueAtIndex:(NSUInteger)index
{
    if (index < self.queue.count) [self.queue removeObjectAtIndex:index];
    [self dropPrepared];
    [self changed];
}

- (void)clearQueue
{
    [self.queue removeAllObjects];
    [self dropPrepared];
    [self changed];
}

- (NSArray *)upcomingTracks:(NSUInteger)max
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger p = _orderPos + 1; p < (NSInteger)_order.count && out.count < max; p++) {
        [out addObject:[_contextTracks objectAtIndex:[[_order objectAtIndex:(NSUInteger)p] unsignedIntegerValue]]];
    }
    return out;
}

// What comes after the current song, without moving there: (track, from queue?, order position)
- (TNTrack *)peekNext:(BOOL *)fromQueue position:(NSInteger *)position
{
    if (self.queue.count) { *fromQueue = YES; *position = _orderPos; return [self.queue objectAtIndex:0]; }
    *fromQueue = NO;
    if (self.repeat == TNRepeatOne && self.currentTrack) { *position = _orderPos; return self.currentTrack; }
    for (NSInteger p = _orderPos + 1; p < (NSInteger)_order.count; p++) {
        TNTrack *t = [_contextTracks objectAtIndex:[[_order objectAtIndex:(NSUInteger)p] unsignedIntegerValue]];
        if (t.playable) { *position = p; return t; }
    }
    if (self.repeat == TNRepeatAll && _order.count) {
        for (NSInteger p = 0; p < (NSInteger)_order.count; p++) {
            TNTrack *t = [_contextTracks objectAtIndex:[[_order objectAtIndex:(NSUInteger)p] unsignedIntegerValue]];
            if (t.playable) { *position = p; return t; }
        }
    }
    return nil;
}

#pragma mark - Radio

- (void)startRadioFor:(TNTrack *)track
{
    NSString *videoId = track.videoId ?: ([self isCurrent:track] ? self.currentVideoId : nil);
    if (!videoId.length) return;
    [_radioMore cancel];
    _radioMore = [TNYTMusic radioFor:videoId playlistId:nil completion:^(TNWatchQueue *queue, NSError *error) {
        NSMutableArray *tracks = [NSMutableArray arrayWithObject:track];
        for (TNTrack *t in queue.tracks) if (![t.videoId isEqualToString:videoId]) [tracks addObject:t];
        if (tracks.count < 2) {
            [[NSNotificationCenter defaultCenter] postNotificationName:TNPlayerDidFailNotification object:self
                                                              userInfo:@{ @"error": error ?: TNMakeError(TNErrorAPI, L(@"No radio for this song.")) }];
            return;
        }
        self.shuffle = NO;
        BOOL same = [self isCurrent:track];
        NSString *name = [NSString stringWithFormat:L(@"%@ Radio"), track.name ?: @""];
        if (same) {
            // (the song goes on where it is; what follows becomes its radio)
            self->_contextTracks = [tracks copy];
            self.contextURI = [@"radio:" stringByAppendingString:videoId];
            self.contextName = name;
            [self buildOrderStartingWith:0];
            self->_currentFromQueue = NO;
            [self dropPrepared];
            [self changed];
        } else {
            [self playTracks:tracks startingAt:0 contextURI:[@"radio:" stringByAppendingString:videoId] contextName:name];
        }
        self->_radio = queue;
    }];
}

// A radio running low gets its next part
- (void)extendRadioIfNeeded
{
    if (!_radio.continuation.length || _radioMore || ![self.contextURI hasPrefix:@"radio:"]) return;
    if ((NSInteger)_order.count - _orderPos > 5) return;
    TNWatchQueue *radio = _radio;
    __weak TNPlayer *weakSelf = self;
    _radioMore = [TNYTMusic radioMore:radio completion:^(NSArray *tracks, NSString *continuation, NSError *error) {
        TNPlayer *me = weakSelf;
        if (!me) return;
        me->_radioMore = nil;
        if (radio != me->_radio || !tracks.count) return;
        radio.continuation = continuation;
        NSMutableSet *have = [NSMutableSet set];
        for (TNTrack *t in me->_contextTracks) if (t.videoId) [have addObject:t.videoId];
        NSMutableArray *all = [me->_contextTracks mutableCopy];
        for (TNTrack *t in tracks) {
            if (!t.videoId || [have containsObject:t.videoId]) continue;
            [all addObject:t];
            [me->_order addObject:@(all.count - 1)];
        }
        me->_contextTracks = all;
        [me changed];
    }];
}

#pragma mark - Loading

- (void)loadAndPlay:(TNTrack *)track { [self loadAndPlay:track fromMs:0 paused:NO]; }

- (void)loadAndPlay:(TNTrack *)track fromMs:(NSInteger)startMs paused:(BOOL)paused
{
    NSUInteger token = ++_loadToken;
    [self dropPrepared];
    self.currentTrack = track;
    self.currentVideoId = track.videoId;
    self.loading = YES;
    self.playing = !paused;
    [_engine stop];
    [self changed];
    dispatch_async(_loadQueue, ^{
        NSError *error = nil;
        TNPlaybackItem *item = [TNPlaybackItem loadTrack:track error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self->_loadToken) { [item cancel]; return; }
            self.loading = NO;
            if (!item) {
                [self failed:track error:error];
                return;
            }
            self->_failures = 0;
            NSInteger from = item.durationMs > 0 && startMs >= item.durationMs ? 0 : MAX(0, startMs);
            [self->_engine playItem:item fromMs:from paused:!self.playing];
        });
    });
}

- (void)failed:(TNTrack *)track error:(NSError *)error
{
    TNLog(@"cannot play %@: %@", track.name, error.localizedDescription);
    [[NSNotificationCenter defaultCenter] postNotificationName:TNPlayerDidFailNotification object:self
                                                      userInfo:@{ @"error": error ?: TNMakeError(TNErrorPlayback, L(@"This song cannot be played.")) }];
    // (when YouTube turns the app away no song plays: skipping through the list would only fail on every one)
    if (++_failures >= TNMaxSkipsOnError || error.code == TNErrorRefused) {
        self.playing = NO;
        [self changed];
        return;
    }
    [self advanceAutomatically:NO];
}

#pragma mark - Debug

- (void)debugPlayURL:(NSString *)url durationMs:(NSInteger)durationMs
{
    TNTrack *t = [[TNTrack alloc] init];
    t.name = @"Audio test";
    t.byline = url;
    t.durationMs = durationMs;
    NSUInteger token = ++_loadToken;
    [self dropPrepared];
    self.currentTrack = t;
    self.currentVideoId = nil;
    self.loading = YES;
    self.playing = YES;
    [_engine stop];
    [self changed];
    dispatch_async(_loadQueue, ^{
        NSError *error = nil;
        TNPlaybackItem *item = [TNPlaybackItem itemForTrack:t url:url durationMs:durationMs error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self->_loadToken) { [item cancel]; return; }
            self.loading = NO;
            if (!item) { TNLog(@"audio test failed: %@", error.localizedDescription); self.playing = NO; [self changed]; return; }
            [self->_engine playItem:item fromMs:0 paused:NO];
        });
    });
}

- (void)dropPrepared
{
    _prepareToken++;
    _preparedTrack = nil;
    [_engine queueNextItem:nil];
}

- (void)engineNeedsNextItem
{
    if (self.sleepAtEndOfSong) return;   // (the sleep timer ends with this song: nothing is prepared)
    BOOL fromQueue = NO;
    NSInteger position = -1;
    TNTrack *next = [self peekNext:&fromQueue position:&position];
    if (!next || next == _preparedTrack) return;
    NSUInteger token = ++_prepareToken;
    _preparedTrack = next;
    dispatch_async(_loadQueue, ^{
        TNPlaybackItem *item = [TNPlaybackItem loadTrack:next error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != self->_prepareToken || !item) { [item cancel]; return; }
            [self->_engine queueNextItem:item];
        });
    });
}

#pragma mark - Engine events

- (void)engineDidStartItem:(TNPlaybackItem *)item
{
    if (item.track != self.currentTrack) {
        // the prepared next song went on without a gap: the queue moves along
        [self moveToTrack:item.track];
        self.currentTrack = item.track;
        _preparedTrack = nil;
    }
    self.currentVideoId = item.videoId;
    if (!item.track.videoId.length && item.videoId.length && [item.track isApple]) item.track.videoId = item.videoId;
    self.loading = NO;
    [[TNLibrary shared] addRecent:item.track];
    [self extendRadioIfNeeded];
    [self changed];
}

- (void)engineDidFinishItem:(TNPlaybackItem *)item
{
    if (self.sleepAtEndOfSong) {
        [self setSleepTimerMinutes:0];
        self.playing = NO;
        [_engine stop];
        _resumeMs = 0;
        [self changed];
        return;
    }
    [self advanceAutomatically:YES];
}

- (void)engineDidFailItem:(TNPlaybackItem *)item error:(NSError *)error
{
    [self failed:item.track error:error];
}

// The queue position follows a song that started by itself (gapless)
- (void)moveToTrack:(TNTrack *)track
{
    if (self.queue.count && [self.queue objectAtIndex:0] == track) {
        [self.queue removeObjectAtIndex:0];
        _currentFromQueue = YES;
        return;
    }
    _currentFromQueue = NO;
    if (self.repeat == TNRepeatOne) return;
    for (NSInteger p = _orderPos + 1; p < (NSInteger)_order.count; p++) {
        if ([_contextTracks objectAtIndex:[[_order objectAtIndex:(NSUInteger)p] unsignedIntegerValue]] == track) { _orderPos = p; return; }
    }
    for (NSInteger p = 0; p < (NSInteger)_order.count; p++) {
        if ([_contextTracks objectAtIndex:[[_order objectAtIndex:(NSUInteger)p] unsignedIntegerValue]] == track) { _orderPos = p; return; }
    }
}

- (void)advanceAutomatically:(BOOL)automatic
{
    if (automatic && self.repeat == TNRepeatOne && self.currentTrack) {
        [self loadAndPlay:self.currentTrack];
        return;
    }
    if (self.queue.count) {
        TNTrack *t = [self.queue objectAtIndex:0];
        [self.queue removeObjectAtIndex:0];
        _currentFromQueue = YES;
        [self loadAndPlay:t];
        return;
    }
    for (NSInteger p = _orderPos + 1; p < (NSInteger)_order.count; p++) {
        TNTrack *t = [_contextTracks objectAtIndex:[[_order objectAtIndex:(NSUInteger)p] unsignedIntegerValue]];
        if (!t.playable) continue;
        _orderPos = p;
        _currentFromQueue = NO;
        [self loadAndPlay:t];
        return;
    }
    if (self.repeat == TNRepeatAll && _order.count) {
        if (self.shuffle) TNShuffleArray(_order);
        _orderPos = -1;
        [self advanceAutomatically:NO];
        return;
    }
    NSString *seedId = self.currentVideoId;
    if ([TNSettings autoplay] && seedId.length && !_fetchingRadio) {
        // the end of the context: the radio of the last song follows (YouTube Music's autoplay)
        _fetchingRadio = YES;
        TNTrack *seed = self.currentTrack;
        [TNYTMusic radioFor:seedId playlistId:nil completion:^(TNWatchQueue *queue, NSError *error) {
            self->_fetchingRadio = NO;
            NSMutableArray *tracks = [NSMutableArray array];
            NSMutableSet *played = [NSMutableSet setWithObject:seedId];
            for (TNTrack *t in self->_contextTracks) if (t.videoId) [played addObject:t.videoId];
            for (TNTrack *t in queue.tracks) if (t.videoId && ![played containsObject:t.videoId]) [tracks addObject:t];
            if (!tracks.count) { self.playing = NO; [self->_engine stop]; [self changed]; return; }
            self.shuffle = NO;
            [self playTracks:tracks startingAt:0 contextURI:[@"radio:" stringByAppendingString:seedId]
                 contextName:[NSString stringWithFormat:L(@"%@ Radio"), seed.name ?: @""]];
            self->_radio = queue;
        }];
        return;
    }
    self.playing = NO;
    [_engine stop];
    [self changed];
}

#pragma mark - Controls

- (void)play
{
    if (!self.currentTrack) return;
    self.playing = YES;
    if (_engine.currentItem) [_engine resume];
    else if (!self.loading) {
        NSInteger from = _resumeMs;
        _resumeMs = 0;
        [self loadAndPlay:self.currentTrack fromMs:from paused:NO];
    }
    [self changed];
}

- (void)pause
{
    self.playing = NO;
    [_engine pause];
    [self changed];
}

- (void)togglePlay
{
    if (self.playing) [self pause];
    else [self play];
}

- (void)next
{
    if (!self.currentTrack) return;
    self.playing = YES;
    [self advanceAutomatically:NO];
}

- (void)previous
{
    if (!self.currentTrack) return;
    if (self.positionMs > TNRestartThresholdMs || _orderPos <= 0 || _currentFromQueue) {
        [self seekToMs:0];
        if (!self.playing) [self play];
        return;
    }
    for (NSInteger p = _orderPos - 1; p >= 0; p--) {
        TNTrack *t = [_contextTracks objectAtIndex:[[_order objectAtIndex:(NSUInteger)p] unsignedIntegerValue]];
        if (!t.playable) continue;
        _orderPos = p;
        self.playing = YES;
        [self loadAndPlay:t];
        return;
    }
    [self seekToMs:0];
}

- (void)seekToMs:(NSInteger)ms
{
    [_engine seekToMs:ms];
    [self changed];
}

#pragma mark - Lock screen, remote controls

- (void)handleRemoteEvent:(UIEvent *)event
{
    if (event.type != UIEventTypeRemoteControl) return;
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlPlay: [self play]; break;
        case UIEventSubtypeRemoteControlPause: [self pause]; break;
        case UIEventSubtypeRemoteControlStop: [self pause]; break;
        case UIEventSubtypeRemoteControlTogglePlayPause: [self togglePlay]; break;
        case UIEventSubtypeRemoteControlNextTrack: [self next]; break;
        case UIEventSubtypeRemoteControlPreviousTrack: [self previous]; break;
        default: break;
    }
}

- (void)updateNowPlaying
{
    TNTrack *t = self.currentTrack;
    if (!t) {
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
        return;
    }
    NSString *art = [t imageURLForSize:300];
    if (art.length && ![art isEqualToString:_artworkURL]) {
        _artworkURL = art;
        _artwork = nil;
        __weak TNPlayer *weakSelf = self;
        _artworkToken = [[TNImageLoader shared] loadImage:art maxPixels:600 completion:^(UIImage *image) {
            TNPlayer *me = weakSelf;
            if (!me || ![me->_artworkURL isEqualToString:art]) return;
            me->_artwork = image;
            [me updateNowPlaying];
        }];
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    TNLegacyDictionarySet(info, MPMediaItemPropertyTitle, t.name ?: @"");
    TNLegacyDictionarySet(info, MPMediaItemPropertyArtist, [t artistNames] ?: @"");
    if (t.album.name.length) TNLegacyDictionarySet(info, MPMediaItemPropertyAlbumTitle, t.album.name);
    TNLegacyDictionarySet(info, MPMediaItemPropertyPlaybackDuration, @((double)self.durationMs / 1000.0));
    TNLegacyDictionarySet(info, MPNowPlayingInfoPropertyElapsedPlaybackTime, @((double)self.positionMs / 1000.0));
    TNLegacyDictionarySet(info, MPNowPlayingInfoPropertyPlaybackRate, @(self.playing && !self.buffering ? 1.0 : 0.0));
    if (_artwork) TNLegacyDictionarySet(info, MPMediaItemPropertyArtwork, [[MPMediaItemArtwork alloc] initWithImage:_artwork]);
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

- (NSString *)debugState
{
    return [NSString stringWithFormat:@"player: %@ (%@), %@, context %@ (%ld/%lu), queue %lu, shuffle %d, repeat %ld | %@",
            self.currentTrack.name ?: @"-", self.currentVideoId ?: @"-", self.playing ? (self.loading ? @"loading" : @"playing") : @"paused",
            self.contextName ?: @"-", (long)_orderPos, (unsigned long)_order.count, (unsigned long)self.queue.count, self.shuffle, (long)self.repeat,
            [_engine debugState]];
}

- (void)saveWhilePlaying { if (self.playing && _engine.currentItem) [self saveState]; }

#pragma mark - Sleep timer

- (void)setSleepTimerMinutes:(NSInteger)minutes
{
    [_sleepTimer invalidate];
    _sleepTimer = nil;
    self.sleepAt = nil;
    self.sleepAtEndOfSong = minutes < 0;
    if (minutes > 0) {
        self.sleepAt = [NSDate dateWithTimeIntervalSinceNow:minutes * 60];
        _sleepTimer = [NSTimer scheduledTimerWithTimeInterval:minutes * 60 target:self selector:@selector(sleepNow) userInfo:nil repeats:NO];
    }
    if (minutes < 0) [self dropPrepared];
    [self changed];
}

- (void)sleepNow
{
    _sleepTimer = nil;
    self.sleepAt = nil;
    [self pause];
}

#pragma mark - Editing the queue

- (void)moveQueueItemFrom:(NSUInteger)from to:(NSUInteger)to
{
    if (from >= self.queue.count || to >= self.queue.count || from == to) return;
    id t = [self.queue objectAtIndex:from];
    [self.queue removeObjectAtIndex:from];
    [self.queue insertObject:t atIndex:to];
    [self dropPrepared];
    [self changed];
}

- (void)moveUpcomingFrom:(NSUInteger)from to:(NSUInteger)to
{
    NSInteger a = _orderPos + 1 + (NSInteger)from, b = _orderPos + 1 + (NSInteger)to;
    if (a < 0 || b < 0 || a >= (NSInteger)_order.count || b >= (NSInteger)_order.count || a == b) return;
    id x = [_order objectAtIndex:(NSUInteger)a];
    [_order removeObjectAtIndex:(NSUInteger)a];
    [_order insertObject:x atIndex:(NSUInteger)b];
    [self dropPrepared];
    [self changed];
}

- (void)removeUpcomingAtIndex:(NSUInteger)index
{
    NSInteger a = _orderPos + 1 + (NSInteger)index;
    if (a < 0 || a >= (NSInteger)_order.count) return;
    [_order removeObjectAtIndex:(NSUInteger)a];
    [self dropPrepared];
    [self changed];
}

- (void)playNextTracks:(NSArray *)tracks
{
    NSUInteger at = 0;
    for (TNTrack *t in tracks) if ([t isKindOfClass:[TNTrack class]] && t.playable) [self.queue insertObject:t atIndex:at++];
    [self dropPrepared];
    [self changed];
}

- (void)addTracksToQueue:(NSArray *)tracks
{
    for (TNTrack *t in tracks) if ([t isKindOfClass:[TNTrack class]] && t.playable) [self.queue addObject:t];
    [self dropPrepared];
    [self changed];
}

#pragma mark - Where it was left (kept between launches)

+ (NSString *)statePath
{
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [base stringByAppendingPathComponent:@"Muzika"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"queue.json"];
}

static NSArray *TNJSONTracks(NSArray *tracks)
{
    NSMutableArray *out = [NSMutableArray array];
    for (TNTrack *t in tracks) [out addObject:[t toJSON]];
    return out;
}

- (void)scheduleSave
{
    if (_saveScheduled) return;
    _saveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_saveScheduled = NO;
        [self saveState];
    });
}

- (void)saveState
{
    TNTrack *current = self.currentTrack;
    if (!current) { [[NSFileManager defaultManager] removeItemAtPath:[TNPlayer statePath] error:NULL]; return; }
    NSArray *context = _contextTracks ?: @[];
    NSArray *order = _order ?: @[];
    NSInteger pos = _orderPos;
    if (context.count > 1500) {
        // (a huge context: the song and what follows in play order are enough)
        NSMutableArray *window = [NSMutableArray array];
        for (NSInteger p = MAX(0, pos); p < (NSInteger)order.count && window.count < 500; p++) [window addObject:[context objectAtIndex:[[order objectAtIndex:(NSUInteger)p] unsignedIntegerValue]]];
        context = window;
        NSMutableArray *o = [NSMutableArray array];
        for (NSUInteger i = 0; i < window.count; i++) [o addObject:@(i)];
        order = o;
        pos = pos >= 0 ? 0 : -1;
    }
    NSInteger position = _engine.currentItem ? self.positionMs : _resumeMs;
    NSDictionary *state = @{ @"context": TNJSONTracks(context), @"order": order, @"pos": @(pos), @"queue": TNJSONTracks(self.queue),
                             @"current": [current toJSON], @"fromQueue": @(_currentFromQueue), @"ms": @(position),
                             @"uri": self.contextURI ?: @"", @"name": self.contextName ?: @"", @"shuffle": @(self.shuffle), @"repeat": @(self.repeat) };
    NSString *path = [TNPlayer statePath];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [[TNUtils JSONDataFromObject:state] writeToFile:path atomically:YES];
    });
}

- (void)restoreState
{
    NSDictionary *s = TNDict([TNUtils JSONObjectFromData:[NSData dataWithContentsOfFile:[TNPlayer statePath]]]);
    TNTrack *current = [TNTrack fromJSON:TNDict([s objectForKey:@"current"])];
    if (!current) return;
    NSMutableArray *context = [NSMutableArray array];
    for (id j in TNArr([s objectForKey:@"context"]) ?: @[]) { TNTrack *t = [TNTrack fromJSON:TNDict(j)]; if (t) [context addObject:t]; }
    NSMutableArray *order = [NSMutableArray array];
    for (id n in TNArr([s objectForKey:@"order"]) ?: @[]) if ([n integerValue] >= 0 && [n unsignedIntegerValue] < context.count) [order addObject:@([n unsignedIntegerValue])];
    if (order.count != context.count) { [order removeAllObjects]; for (NSUInteger i = 0; i < context.count; i++) [order addObject:@(i)]; }
    _contextTracks = context;
    _order = order;
    _orderPos = MIN((NSInteger)order.count - 1, TNInt([s objectForKey:@"pos"]));
    // (the current song is the same object as its place in the context, so the list shows it as playing)
    if (_orderPos >= 0 && !TNBool([s objectForKey:@"fromQueue"])) {
        TNTrack *atPos = [context objectAtIndex:[[order objectAtIndex:(NSUInteger)_orderPos] unsignedIntegerValue]];
        if ([[atPos key] isEqualToString:[current key]]) current = atPos;
    }
    for (id j in TNArr([s objectForKey:@"queue"]) ?: @[]) { TNTrack *t = [TNTrack fromJSON:TNDict(j)]; if (t) [self.queue addObject:t]; }
    _currentFromQueue = TNBool([s objectForKey:@"fromQueue"]);
    _shuffle = TNBool([s objectForKey:@"shuffle"]);
    _repeat = (TNRepeatMode)TNInt([s objectForKey:@"repeat"]);
    self.contextURI = TNStr([s objectForKey:@"uri"]);
    self.contextName = TNStr([s objectForKey:@"name"]);
    self.currentTrack = current;
    self.currentVideoId = current.videoId;
    _resumeMs = TNInt([s objectForKey:@"ms"]);
    self.playing = NO;
    TNLog(@"restored %@ at %.0f s, %lu songs around it", current.name, _resumeMs / 1000.0, (unsigned long)context.count);
    [[NSNotificationCenter defaultCenter] postNotificationName:TNPlayerDidChangeNotification object:self];
    [self updateNowPlaying];
}

- (NSInteger)resumePositionMs { return _resumeMs; }

@end