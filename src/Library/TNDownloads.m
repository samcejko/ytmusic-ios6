#import "TNDownloads.h"
#import "TNModels.h"
#import "TNStreams.h"
#import "TNMatcher.h"
#import "TNAudioFile.h"
#import "TNReachability.h"
#import "TNSettings.h"
#import "TNUtils.h"
#import "TNCommon.h"

NSString * const TNDownloadsDidChangeNotification = @"TNDownloadsDidChangeNotification";

@interface TNDownloads ()
@property (nonatomic) NSUInteger waitingCount;
@property (nonatomic) float progress;
@property (nonatomic, copy) NSString *state;
@end

@implementation TNDownloads {
    NSMutableArray *_entries;         // NSDictionary {track (JSON), key, file, videoId, loud, itag, ms, size, date}, newest first
    NSMutableDictionary *_byKey;      // key -> entry (any thread, under @synchronized)
    NSMutableArray *_queue;           // TNTrack waiting
    NSMutableSet *_queuedKeys;
    BOOL _working;
    NSUInteger _done;                 // of the current batch, for "3 of 12"
    TNAudioFile *_current;
}

+ (instancetype)shared
{
    static TNDownloads *downloads;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ downloads = [[TNDownloads alloc] init]; });
    return downloads;
}

+ (NSString *)folder
{
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [[base stringByAppendingPathComponent:@"Muzika"] stringByAppendingPathComponent:@"downloads"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        // (songs can be downloaded again: they stay out of the iCloud backup)
        [[NSURL fileURLWithPath:dir] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
    }
    return dir;
}

+ (NSString *)indexPath { return [[self folder] stringByAppendingPathComponent:@"downloads.json"]; }

static NSString *TNSafeName(NSString *key)
{
    NSMutableString *name = [NSMutableString string];
    for (NSUInteger i = 0; i < key.length; i++) {
        unichar c = [key characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
        [name appendFormat:@"%C", ok ? c : (unichar)'_'];
    }
    return [name stringByAppendingString:@".m4a"];
}

- (instancetype)init
{
    if ((self = [super init])) {
        _queue = [NSMutableArray array];
        _queuedKeys = [NSMutableSet set];
        _byKey = [NSMutableDictionary dictionary];
        _entries = [NSMutableArray array];
        for (id e in TNArr([TNUtils JSONObjectFromData:[NSData dataWithContentsOfFile:[TNDownloads indexPath]]]) ?: @[]) {
            NSDictionary *d = TNDict(e);
            NSString *key = TNStr(d[@"key"]);
            if (!key.length || ![[NSFileManager defaultManager] fileExistsAtPath:[[TNDownloads folder] stringByAppendingPathComponent:TNStr(d[@"file"]) ?: @""]]) continue;
            [_entries addObject:d];
            _byKey[key] = d;
        }
    }
    return self;
}

- (void)save
{
    NSData *data = [TNUtils JSONDataFromObject:[_entries copy]];
    [data writeToFile:[TNDownloads indexPath] atomically:YES];
}

- (void)announce
{
    TNMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName:TNDownloadsDidChangeNotification object:self]; });
}

#pragma mark - Asking

- (NSDictionary *)localFileFor:(TNTrack *)track
{
    if (!track) return nil;
    NSDictionary *e;
    @synchronized (_byKey) { e = _byKey[[track key]]; }
    if (!e) return nil;
    NSMutableDictionary *d = [e mutableCopy];
    d[@"path"] = [[TNDownloads folder] stringByAppendingPathComponent:TNStr(e[@"file"]) ?: @""];
    return d;
}

- (BOOL)isDownloaded:(TNTrack *)track
{
    @synchronized (_byKey) { return track && _byKey[[track key]] != nil; }
}

- (BOOL)isWaiting:(TNTrack *)track { return track && [_queuedKeys containsObject:[track key]]; }

- (NSArray *)downloadedTracks
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *e in _entries) { TNTrack *t = [TNTrack fromJSON:TNDict(e[@"track"])]; if (t) [out addObject:t]; }
    return out;
}

- (unsigned long long)bytesUsed
{
    unsigned long long n = 0;
    for (NSDictionary *e in _entries) n += (unsigned long long)[e[@"size"] longLongValue];
    return n;
}

#pragma mark - Changing

- (void)download:(NSArray *)tracks
{
    NSUInteger added = 0;
    for (TNTrack *t in tracks) {
        if (![t isKindOfClass:[TNTrack class]] || !t.playable) continue;
        NSString *key = [t key];
        if ([self isDownloaded:t] || [_queuedKeys containsObject:key]) continue;
        [_queue addObject:t];
        [_queuedKeys addObject:key];
        added++;
    }
    self.waitingCount = _queue.count + (_working ? 1 : 0);
    [self announce];
    if (added && !_working) [self next];
}

- (void)remove:(TNTrack *)track
{
    NSString *key = [track key];
    NSDictionary *e;
    @synchronized (_byKey) { e = _byKey[key]; [_byKey removeObjectForKey:key]; }
    if (!e) return;
    [_entries removeObject:e];
    [[NSFileManager defaultManager] removeItemAtPath:[[TNDownloads folder] stringByAppendingPathComponent:TNStr(e[@"file"]) ?: @""] error:NULL];
    [self save];
    [self announce];
}

- (void)removeAll
{
    [self cancelPending];
    for (NSDictionary *e in [_entries copy]) [[NSFileManager defaultManager] removeItemAtPath:[[TNDownloads folder] stringByAppendingPathComponent:TNStr(e[@"file"]) ?: @""] error:NULL];
    [_entries removeAllObjects];
    @synchronized (_byKey) { [_byKey removeAllObjects]; }
    [self save];
    [self announce];
}

- (void)cancelPending
{
    [_queue removeAllObjects];
    [_queuedKeys removeAllObjects];
    [_current cancel];
    self.waitingCount = _working ? 1 : 0;
    [self announce];
}

#pragma mark - The work

- (void)next
{
    if (!_queue.count) {
        _working = NO;
        _done = 0;
        self.state = nil;
        self.waitingCount = 0;
        [self announce];
        return;
    }
    if ([TNSettings downloadOnWiFiOnly] && [TNReachability onCellular]) {
        // only mobile data: a look again in a while
        _working = YES;
        self.state = L(@"Waiting for Wi-Fi");
        [self announce];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self next]; });
        return;
    }
    _working = YES;
    TNTrack *t = _queue[0];
    [_queue removeObjectAtIndex:0];
    self.waitingCount = _queue.count + 1;
    self.progress = 0;
    self.state = [NSString stringWithFormat:L(@"Downloading %lu of %lu"), (unsigned long)_done + 1, (unsigned long)(_done + _queue.count + 1)];
    [self announce];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSError *error = nil;
        NSDictionary *entry = [self fetch:t error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_queuedKeys removeObject:[t key]];
            self->_done++;
            if (entry) {
                [self->_entries insertObject:entry atIndex:0];
                @synchronized (self->_byKey) { self->_byKey[entry[@"key"]] = entry; }
                [self save];
            } else {
                TNLog(@"download of %@ failed: %@", t.name, error.localizedDescription);
            }
            [self next];
        });
    });
}

// One song into its file (blocking)
- (NSDictionary *)fetch:(TNTrack *)track error:(NSError **)error
{
    NSString *videoId = track.videoId;
    if (!videoId.length && [track isApple]) videoId = [[TNMatcher shared] videoIdForTrackSync:track error:error];
    if (!videoId.length) return nil;
    NSString *known = [[TNMatcher shared] knownAlternativeFor:videoId];
    if (known) videoId = known;
    TNAudioSource *source = [TNStreams audioForVideo:videoId lowQuality:NO error:error];
    if (!source.url.length) return nil;
    TNAudioFile *file = [[TNAudioFile alloc] initWithURL:source.url];
    TNMain(^{ self->_current = file; });
    [file start];
    while (!file.finished) {
        [file waitForBytes:file.length ?: 1 timeout:0.5];
        float p = file.length ? (float)file.available / (float)file.length : 0;
        if (p - self.progress > 0.05f || file.finished) {
            TNMain(^{ self.progress = p; [self announce]; });
        }
    }
    TNMain(^{ self->_current = nil; });
    if (file.error || !file.length || file.available < file.length) {
        if (error) *error = file.error ?: TNMakeError(TNErrorPlayback, L(@"The song could not be downloaded."));
        return nil;
    }
    NSString *key = [track key];
    NSString *name = TNSafeName(key);
    NSData *data = [NSData dataWithBytes:file.bytes length:file.length];
    if (![data writeToFile:[[TNDownloads folder] stringByAppendingPathComponent:name] atomically:YES]) {
        if (error) *error = TNMakeError(TNErrorPlayback, L(@"There is no room left on the device."));
        return nil;
    }
    TNTrack *copy = [TNTrack fromJSON:[track toJSON]] ?: track;
    if (!copy.durationMs) copy.durationMs = source.durationMs;
    TNLog(@"downloaded %@ (%@), %lu bytes", track.name, videoId, (unsigned long)file.length);
    return @{ @"track": [copy toJSON], @"key": key, @"file": name, @"videoId": videoId, @"loud": @(source.loudnessDb),
              @"itag": @(source.itag), @"ms": @(source.durationMs), @"size": @(file.length), @"date": @([[NSDate date] timeIntervalSince1970]) };
}

@end
