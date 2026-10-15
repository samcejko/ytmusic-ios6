#import "TNPlayer.h"
#import "TNPlaybackEngine.h"
#import "TNModels.h"
#import "TNYTMusic.h"
#import "TNLibrary.h"
#import "TNImageLoader.h"
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
    }
    return self;
}

- (NSArray *)userQueue { return [self.queue copy]; }
- (BOOL)buffering { return self.loading || _engine.buffering; }
- (NSInteger)positionMs { return _engine.currentItem ? _engine.positionMs : 0; }
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
    if (![tracks[(NSUInteger)start] playable]) positionMs = 0;
    while (start < (NSInteger)tracks.count && ![tracks[(NSUInteger)start] playable]) start++;
    if (start >= (NSInteger)tracks.count) return;
    [self buildOrderStartingWith:start];
    _currentFromQueue = NO;
    _failures = 0;
    [self loadAndPlay:tracks[(NSUInteger)start] fromMs:positionMs paused:paused];
}

- (NSArray *)contextTracks { return _contextTracks ?: @[]; }

- (NSInteger)contextIndex
{
    return (_orderPos >= 0 && _orderPos < (NSInteger)_order.count && !_currentFromQueue) ? [_order[(NSUInteger)_orderPos] integerValue] : -1;
}

- (NSArray *)previousTracks:(NSUInteger)max
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger p = MAX(0, _orderPos - (NSInteger)max); p < _orderPos && p < (NSInteger)_order.count; p++) {
        [out addObject:_contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]]];
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
    NSInteger current = (_orderPos >= 0 && _orderPos < (NSInteger)_order.count) ? [_order[(NSUInteger)_orderPos] integerValue] : -1;
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
        [out addObject:_contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]]];
    }
    return out;
}

// What comes after the current song, without moving there: (track, from queue?, order position)
- (TNTrack *)peekNext:(BOOL *)fromQueue position:(NSInteger *)position
{
    if (self.queue.count) { *fromQueue = YES; *position = _orderPos; return self.queue[0]; }
    *fromQueue = NO;
    if (self.repeat == TNRepeatOne && self.currentTrack) { *position = _orderPos; return self.currentTrack; }
    for (NSInteger p = _orderPos + 1; p < (NSInteger)_order.count; p++) {
        TNTrack *t = _contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]];
        if (t.playable) { *position = p; return t; }
    }
    if (self.repeat == TNRepeatAll && _order.count) {
        for (NSInteger p = 0; p < (NSInteger)_order.count; p++) {
            TNTrack *t = _contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]];
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
    [self advanceAutomatically:YES];
}

- (void)engineDidFailItem:(TNPlaybackItem *)item error:(NSError *)error
{
    [self failed:item.track error:error];
}

// The queue position follows a song that started by itself (gapless)
- (void)moveToTrack:(TNTrack *)track
{
    if (self.queue.count && self.queue[0] == track) {
        [self.queue removeObjectAtIndex:0];
        _currentFromQueue = YES;
        return;
    }
    _currentFromQueue = NO;
    if (self.repeat == TNRepeatOne) return;
    for (NSInteger p = _orderPos + 1; p < (NSInteger)_order.count; p++) {
        if (_contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]] == track) { _orderPos = p; return; }
    }
    for (NSInteger p = 0; p < (NSInteger)_order.count; p++) {
        if (_contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]] == track) { _orderPos = p; return; }
    }
}

- (void)advanceAutomatically:(BOOL)automatic
{
    if (automatic && self.repeat == TNRepeatOne && self.currentTrack) {
        [self loadAndPlay:self.currentTrack];
        return;
    }
    if (self.queue.count) {
        TNTrack *t = self.queue[0];
        [self.queue removeObjectAtIndex:0];
        _currentFromQueue = YES;
        [self loadAndPlay:t];
        return;
    }
    for (NSInteger p = _orderPos + 1; p < (NSInteger)_order.count; p++) {
        TNTrack *t = _contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]];
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
    else if (!self.loading) [self loadAndPlay:self.currentTrack];
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
        TNTrack *t = _contextTracks[[_order[(NSUInteger)p] unsignedIntegerValue]];
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
    info[MPMediaItemPropertyTitle] = t.name ?: @"";
    info[MPMediaItemPropertyArtist] = [t artistNames] ?: @"";
    if (t.album.name.length) info[MPMediaItemPropertyAlbumTitle] = t.album.name;
    info[MPMediaItemPropertyPlaybackDuration] = @((double)self.durationMs / 1000.0);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @((double)self.positionMs / 1000.0);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.playing && !self.buffering ? 1.0 : 0.0);
    if (_artwork) info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithImage:_artwork];
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

- (NSString *)debugState
{
    return [NSString stringWithFormat:@"player: %@ (%@), %@, context %@ (%ld/%lu), queue %lu, shuffle %d, repeat %ld | %@",
            self.currentTrack.name ?: @"-", self.currentVideoId ?: @"-", self.playing ? (self.loading ? @"loading" : @"playing") : @"paused",
            self.contextName ?: @"-", (long)_orderPos, (unsigned long)_order.count, (unsigned long)self.queue.count, self.shuffle, (long)self.repeat,
            [_engine debugState]];
}

@end
