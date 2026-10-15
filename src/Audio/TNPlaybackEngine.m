#import "TNPlaybackEngine.h"
#import "TNAudioFile.h"
#import "TNAACDecoder.h"
#import "TNAudioOutput.h"
#import "TNStreams.h"
#import "TNMatcher.h"
#import "TNModels.h"
#import "TNCommon.h"

static const NSUInteger TNChunkFrames = 4096;

@interface TNPlaybackItem ()
@property (nonatomic) uint64_t outputStart;     // frames written to the output (since its last flush) before this item's first one
@property (nonatomic) uint64_t baseFrame;       // the decoder frame at outputStart
@property (nonatomic) BOOL askedForNext;
@end

@implementation TNPlaybackItem

+ (TNPlaybackItem *)loadTrack:(TNTrack *)track error:(NSError **)error
{
    NSString *videoId = track.videoId;
    if (!videoId.length && [track isApple]) {
        // an Apple Music song plays as its YouTube twin
        NSError *matchError = nil;
        videoId = [[TNMatcher shared] videoIdForTrackSync:track error:&matchError];
        if (!videoId.length) {
            if (error) *error = matchError ?: TNMakeError(TNErrorNoMatch, L(@"This song was not found on YouTube."));
            return nil;
        }
    }
    if (!videoId.length) {
        if (error) *error = TNMakeError(TNErrorPlayback, L(@"This song cannot be played."));
        return nil;
    }
    TNMatcher *matcher = [TNMatcher shared];
    NSString *known = [matcher knownAlternativeFor:videoId];
    NSString *original = videoId;
    if (known) videoId = known;
    NSError *last = nil;
    NSInteger status = 0, ms = 0;
    TNPlaybackItem *item = [self openVideo:videoId track:track status:&status durationMs:&ms error:&last];
    // YouTube serves some songs' audio in full only with a proof-of-origin token this app lacks (403 on the whole
    // file): another upload of the same recording plays instead, and is remembered for the next time
    if (!item && (status == 403 || status == 404 || status == 410) && last.code != TNErrorRefused) {
        for (NSString *alternative in [matcher alternativesFor:track excluding:videoId durationMs:ms]) {
            NSError *e = nil;
            item = [self openVideo:alternative track:track status:&status durationMs:NULL error:&e];
            if (item) {
                [matcher rememberAlternative:alternative for:original];
                TNLog(@"%@: %@ is not served in full, %@ plays instead", track.name, videoId, alternative);
                break;
            }
            if (e.code == TNErrorRefused) { last = e; break; }
        }
    }
    if (!item) {
        if (error) *error = last ?: TNMakeError(TNErrorPlayback, L(@"The song could not be downloaded."));
        return nil;
    }
    TNLog(@"loaded %@ (%@): %@, %d Hz", track.name, item.videoId, item.formatName, item.decoder.sampleRate);
    return item;
}

// One video's audio: its address from YouTube, the download started, the header read
+ (TNPlaybackItem *)openVideo:(NSString *)videoId track:(TNTrack *)track status:(NSInteger *)status durationMs:(NSInteger *)durationOut error:(NSError **)error
{
    NSInteger ms = 0;
    NSError *e = nil;
    if (status) *status = 0;
    NSString *url = [TNStreams audioURLForVideo:videoId durationMs:&ms error:&e];
    if (durationOut) *durationOut = ms;
    if (!url) {
        if (error) *error = e;
        return nil;
    }
    NSInteger durationMs = ms ?: track.durationMs;
    TNPlaybackItem *item = [self itemForTrack:track url:url durationMs:durationMs error:&e];
    if (!item) {
        NSInteger s = e.code >= 400 ? e.code : 0;
        if (status) *status = s;
        if (s) [TNStreams forget:videoId];
        if (error) *error = e;
        return nil;
    }
    item.videoId = videoId;
    return item;
}
+ (TNPlaybackItem *)itemForTrack:(TNTrack *)track url:(NSString *)url durationMs:(NSInteger)durationMs error:(NSError **)error
{
    TNPlaybackItem *item = [[TNPlaybackItem alloc] init];
    item.track = track;
    item.gain = 1;
    TNAudioFile *file = [[TNAudioFile alloc] initWithURL:url];
    [file start];
    TNAACDecoder *decoder = [[TNAACDecoder alloc] initWithFile:file];
    NSError *e = nil;
    if (![decoder open:&e]) {
        [file cancel];
        if (error) *error = e;
        return nil;
    }
    item.file = file;
    item.decoder = decoder;
    item.durationMs = durationMs ?: track.durationMs;
    int rate = decoder.sampleRate ?: 44100;
    decoder.totalFrames = (uint64_t)item.durationMs * (uint64_t)rate / 1000;
    NSInteger bitrate = decoder.bitrate;
    if (bitrate <= 0 && file.length && item.durationMs > 0) bitrate = (NSInteger)((double)file.length * 8000.0 / (double)item.durationMs);
    item.formatName = bitrate > 0 ? [NSString stringWithFormat:@"AAC %ld kbit/s", (long)((bitrate + 500) / 1000)] : @"AAC";
    return item;
}

- (void)cancel { [self.file cancel]; }

@end

@interface TNPlaybackEngine ()
@property (atomic, strong) TNPlaybackItem *currentItem;
@property (atomic, strong) TNPlaybackItem *nextItem;
@property (atomic) BOOL paused;
@property (atomic) BOOL buffering;
@end

@implementation TNPlaybackEngine {
    NSCondition *_cond;
    TNPlaybackItem *_decodingItem;      // what the thread decodes (the current item, or the next one once it started)
    NSInteger _pendingSeekMs;           // -1 = none
    uint64_t _generation;               // a new play request: the thread starts over
    uint64_t _framesWritten;            // into the output since its last flush
    BOOL _drained;                      // the last item is all decoded; finished once played
    TNAudioOutput *_output;
}

+ (instancetype)shared
{
    static TNPlaybackEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [[TNPlaybackEngine alloc] init]; });
    return engine;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _cond = [[NSCondition alloc] init];
        _pendingSeekMs = -1;
        _output = [TNAudioOutput shared];
        NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(decodeLoop) object:nil];
        t.name = @"TNPlaybackEngine";
        t.threadPriority = 0.9;
        [t start];
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        });
    }
    return self;
}

#pragma mark - Commands (main thread)

- (void)playItem:(TNPlaybackItem *)item fromMs:(NSInteger)startMs paused:(BOOL)paused
{
    TNPlaybackItem *old;
    [_cond lock];
    old = self.currentItem;
    _generation++;
    _decodingItem = item;
    self.currentItem = item;
    TNPlaybackItem *oldNext = self.nextItem;
    self.nextItem = nil;
    _drained = NO;
    _framesWritten = 0;
    _pendingSeekMs = startMs > 0 ? startMs : -1;
    self.paused = paused;
    item.outputStart = 0;
    item.baseFrame = 0;
    [_output stop];            // (inside the lock: the thread cannot write old audio after this)
    [_output prepareForSampleRate:item.decoder.sampleRate ?: 44100];
    [_cond broadcast];
    [_cond unlock];
    if (old != item) [old cancel];
    if (oldNext != item) [oldNext cancel];
    if (!paused) [_output play];
    [self.delegate engineDidStartItem:item];
}

- (void)queueNextItem:(TNPlaybackItem *)item
{
    [_cond lock];
    TNPlaybackItem *old = self.nextItem;
    self.nextItem = item;
    [_cond broadcast];
    [_cond unlock];
    if (old && old != item) [old cancel];
}

- (void)pause
{
    [_cond lock];
    self.paused = YES;
    [_cond unlock];
    [_output pause];
}

- (void)resume
{
    if (!self.currentItem) return;
    [_cond lock];
    self.paused = NO;
    [_cond broadcast];
    [_cond unlock];
    [_output play];
}

- (void)seekToMs:(NSInteger)ms
{
    TNPlaybackItem *dropped = nil;
    [_cond lock];
    if (!self.currentItem) { [_cond unlock]; return; }
    _pendingSeekMs = MAX(0, ms);
    if (_decodingItem && _decodingItem != self.currentItem) {
        // the next song had begun decoding behind this one: it is loaded again when its time comes
        dropped = _decodingItem;
        self.currentItem.askedForNext = NO;
    }
    _decodingItem = self.currentItem;
    _drained = NO;
    [_output flush];                      // wakes a writer waiting for room
    [_cond broadcast];
    [_cond unlock];
    [dropped cancel];
}

- (void)stop
{
    TNPlaybackItem *old, *oldNext;
    [_cond lock];
    _generation++;
    old = self.currentItem;
    oldNext = self.nextItem;
    _decodingItem = nil;
    self.currentItem = nil;
    self.nextItem = nil;
    _drained = NO;
    [_output stop];
    [_cond unlock];
    [old cancel];
    [oldNext cancel];
}

- (NSInteger)positionMs
{
    TNPlaybackItem *item = self.currentItem;
    if (!item) return 0;
    double rate = item.decoder.sampleRate ?: 44100;
    uint64_t played = _output.framesPlayed;
    uint64_t intoItem = played > item.outputStart ? played - item.outputStart : 0;
    // (what is queued in the AudioQueue but not heard yet: about one buffer)
    uint64_t latency = (uint64_t)(0.09 * rate);
    intoItem = intoItem > latency ? intoItem - latency : 0;
    NSInteger ms = (NSInteger)((double)(item.baseFrame + intoItem) * 1000.0 / rate);
    return item.durationMs > 0 ? MIN(ms, item.durationMs) : ms;
}

#pragma mark - Main-thread bookkeeping

- (void)tick
{
    TNPlaybackItem *current = self.currentItem;
    if (!current) return;
    uint64_t played = _output.framesPlayed;
    TNPlaybackItem *decoding;
    BOOL drained;
    uint64_t written;
    [_cond lock];
    decoding = _decodingItem;
    drained = _drained;
    written = _framesWritten;
    [_cond unlock];
    // the gapless next item became audible
    if (decoding && decoding != current && played >= decoding.outputStart) {
        self.currentItem = decoding;
        [current cancel];
        [self.delegate engineDidStartItem:decoding];
        return;
    }
    if (drained && played >= written && !self.paused) {
        [_cond lock];
        _drained = NO;
        _decodingItem = nil;
        [_cond unlock];
        [_output stop];
        [self.delegate engineDidFinishItem:current];
        return;
    }
    BOOL buffering = !self.paused && _output.underrun && current.decoder.starved;
    if (buffering != self.buffering) self.buffering = buffering;
    if (!current.decoder.starved) _output.underrun = NO;
}

#pragma mark - The decoding thread

- (void)decodeLoop
{
    int16_t *buffer = malloc(TNChunkFrames * 4);
    while (YES) {
        @autoreleasepool {
            [_cond lock];
            while (!_decodingItem || ((self.paused || _drained) && _pendingSeekMs < 0)) [_cond wait];
            TNPlaybackItem *item = _decodingItem;
            NSInteger seekMs = _pendingSeekMs;
            _pendingSeekMs = -1;
            uint64_t generation = _generation;
            uint64_t outputGeneration = _output.generation;
            [_cond unlock];

            if (seekMs >= 0) {
                double rate = item.decoder.sampleRate ?: 44100;
                [_output stop];
                [item.decoder seekToFrame:(uint64_t)((double)seekMs * rate / 1000.0)];
                [_cond lock];
                BOOL current = generation == _generation;
                if (current) {
                    _framesWritten = 0;
                    item.outputStart = 0;
                    item.baseFrame = item.decoder.frame;
                }
                BOOL play = current && !self.paused;
                [_cond unlock];
                if (play) [_output play];
                continue;
            }

            NSInteger n = [item.decoder readFrames:buffer max:TNChunkFrames gain:item.gain];
            if (n > 0) {
                NSUInteger written = [_output write:buffer count:(NSUInteger)n generation:outputGeneration];
                [_cond lock];
                if (generation == _generation && outputGeneration == _output.generation) _framesWritten += written;
                [_cond unlock];
            }
            if (!item.askedForNext && (item.file.finished || item.decoder.atEnd)) {
                item.askedForNext = YES;
                dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate engineNeedsNextItem]; });
            }
            if (n < 0) {
                NSError *error = item.file.error ?: TNMakeError(TNErrorPlayback, L(@"The song could not be decoded."));
                [_cond lock];
                BOOL current = generation == _generation && _decodingItem == item;
                if (current) _decodingItem = nil;
                [_cond unlock];
                if (current) dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate engineDidFailItem:item error:error]; });
                continue;
            }
            if (item.decoder.atEnd) {
                [_cond lock];
                if (generation == _generation && _decodingItem == item) {
                    TNPlaybackItem *next = self.nextItem;
                    if (next && next.decoder.sampleRate == item.decoder.sampleRate) {
                        // gapless: the next song's frames follow right behind
                        self.nextItem = nil;
                        next.outputStart = _framesWritten;
                        next.baseFrame = next.decoder.frame;
                        _decodingItem = next;
                    } else {
                        _drained = YES;
                    }
                }
                [_cond unlock];
                continue;
            }
            if (n == 0 && item.decoder.starved) usleep(20000);
        }
    }
}

- (NSString *)debugState
{
    TNPlaybackItem *item = self.currentItem;
    return [NSString stringWithFormat:@"engine: %@ %@, %ld/%ld ms, %@, buffered %lu frames, file %lu/%lu%@%@",
            item ? item.track.name : @"idle", item.formatName ?: @"", (long)self.positionMs, (long)item.durationMs,
            self.paused ? @"paused" : (self.buffering ? @"buffering" : @"playing"), (unsigned long)_output.framesBuffered,
            (unsigned long)item.file.available, (unsigned long)item.file.length, self.nextItem ? @", next ready" : @"",
            item.file.error ? [NSString stringWithFormat:@", download error %@", item.file.error.localizedDescription] : @""];
}

@end
