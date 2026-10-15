#import "TNMatcher.h"
#import "TNModels.h"
#import "TNYTMusic.h"
#import "TNSettings.h"
#import "TNUtils.h"
#import "TNCommon.h"

static const NSTimeInterval TNRetryFailedAfter = 7 * 24 * 3600;
static const NSUInteger TNMaxPending = 4000;

#pragma mark - Comparing names

// Lower case, without accents, punctuation as spaces; `strip`: also without what is in brackets, after " - " and
// after "feat." (versions, remasters, guests)
static NSString *TNNormalize(NSString *s, BOOL strip)
{
    if (!s.length) return @"";
    NSMutableString *m = [[s lowercaseString] mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformStripCombiningMarks, NO);
    if (strip) {
        for (NSArray *pair in @[ @[ @"(", @")" ], @[ @"[", @"]" ] ]) {
            while (YES) {
                NSRange open = [m rangeOfString:pair[0]];
                if (open.location == NSNotFound) break;
                NSRange close = [m rangeOfString:pair[1] options:0 range:NSMakeRange(open.location, m.length - open.location)];
                NSUInteger end = close.location == NSNotFound ? m.length : close.location + 1;
                [m deleteCharactersInRange:NSMakeRange(open.location, end - open.location)];
            }
        }
        for (NSString *cut in @[ @" - ", @" feat. ", @" feat ", @" ft. ", @" featuring " ]) {
            NSRange r = [m rangeOfString:cut];
            if (r.location != NSNotFound && r.location > 0) [m deleteCharactersInRange:NSMakeRange(r.location, m.length - r.location)];
        }
    }
    NSMutableString *out = [NSMutableString stringWithCapacity:m.length];
    BOOL space = YES;
    for (NSUInteger i = 0; i < m.length; i++) {
        unichar c = [m characterAtIndex:i];
        if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c]) { [out appendFormat:@"%C", c]; space = NO; }
        else if (!space) { [out appendString:@" "]; space = YES; }
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

// How alike two normalized names are, 0...1 (shared words; one inside the other counts high)
static double TNSimilarity(NSString *a, NSString *b)
{
    if (!a.length || !b.length) return 0;
    if ([a isEqualToString:b]) return 1;
    NSArray *wa = [a componentsSeparatedByString:@" "], *wb = [b componentsSeparatedByString:@" "];
    NSSet *sa = [NSSet setWithArray:wa], *sb = [NSSet setWithArray:wb];
    NSMutableSet *common = [sa mutableCopy];
    [common intersectSet:sb];
    double dice = 2.0 * common.count / (double)(sa.count + sb.count);
    NSString *shorter = a.length <= b.length ? a : b, *longer = a.length <= b.length ? b : a;
    if (shorter.length >= 3 && [[NSString stringWithFormat:@" %@ ", longer] rangeOfString:[NSString stringWithFormat:@" %@ ", shorter]].location != NSNotFound) dice = MAX(dice, 0.9);
    return dice;
}

// The main artist of "A & B", "A, B", "A feat. B", "A x B"
static NSString *TNPrimaryArtist(NSString *artists)
{
    NSString *s = artists ?: @"";
    for (NSString *sep in @[ @" & ", @", ", @" feat. ", @" feat ", @" ft. ", @" x ", @" X ", @" and ", @" a " ]) {
        NSRange r = [s rangeOfString:sep];
        if (r.location != NSNotFound && r.location > 0) s = [s substringToIndex:r.location];
    }
    return s;
}

static double TNDurationScore(NSInteger a, NSInteger b)
{
    if (a <= 0 || b <= 0) return 0.5;
    NSInteger d = labs((long)(a - b)) / 1000;
    if (d <= 2) return 1;
    if (d <= 5) return 0.85;
    if (d <= 10) return 0.6;
    if (d <= 20) return 0.3;
    return 0;
}

@implementation TNMatcher {
    NSMutableDictionary *_matches;    // key -> {v: videoId, m: manual, f: time it failed}
    NSMutableArray *_pending;         // TNTrack, the newest request first
    NSMutableSet *_pendingKeys;
    BOOL _working;
    BOOL _saveScheduled;
    dispatch_queue_t _queue;
}

+ (instancetype)shared
{
    static TNMatcher *matcher;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ matcher = [[TNMatcher alloc] init]; });
    return matcher;
}

+ (NSString *)path
{
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [base stringByAppendingPathComponent:@"Muzika"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"matches.json"];
}

- (instancetype)init
{
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.samcejko.muzika.matcher", DISPATCH_QUEUE_SERIAL);
        _pending = [NSMutableArray array];
        _pendingKeys = [NSMutableSet set];
        NSDictionary *json = TNDict([TNUtils JSONObjectFromData:[NSData dataWithContentsOfFile:[TNMatcher path]]]);
        _matches = json ? [json mutableCopy] : [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)scheduleSave
{
    TNMain(^{
        if (self->_saveScheduled) return;
        self->_saveScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_saveScheduled = NO;
            NSDictionary *copy;
            @synchronized (self) { copy = [self->_matches copy]; }
            dispatch_async(self->_queue, ^{
                NSData *data = [TNUtils JSONDataFromObject:copy];
                if (data) [data writeToFile:[TNMatcher path] atomically:YES];
            });
        });
    });
}

- (void)announce:(NSString *)key
{
    TNMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName:TNMatchDidChangeNotification object:self userInfo:key ? @{ @"key": key } : nil]; });
}

#pragma mark - Cache

- (NSDictionary *)entryFor:(TNTrack *)track
{
    NSString *key = [track key];
    @synchronized (self) { return TNDict(_matches[key]); }
}

- (NSString *)cachedVideoIdFor:(TNTrack *)track
{
    NSString *v = TNStr([self entryFor:track][@"v"]);
    return v.length ? v : nil;
}

- (BOOL)hasFailed:(TNTrack *)track
{
    NSDictionary *e = [self entryFor:track];
    return e && !TNStr(e[@"v"]).length && TNDbl(e[@"f"]) > 0;
}

- (BOOL)recentlyFailed:(TNTrack *)track
{
    NSDictionary *e = [self entryFor:track];
    double f = TNDbl(e[@"f"]);
    return !TNStr(e[@"v"]).length && f > 0 && [[NSDate date] timeIntervalSince1970] - f < TNRetryFailedAfter;
}

- (void)applyTo:(NSArray *)tracks
{
    for (TNTrack *t in tracks) {
        if (![t isKindOfClass:[TNTrack class]] || ![t isApple]) continue;
        NSString *v = [self cachedVideoIdFor:t];
        if (v) { t.videoId = v; t.matchFailed = NO; }
        else t.matchFailed = [self recentlyFailed:t];
    }
}

- (void)record:(NSString *)videoId forTrack:(TNTrack *)track manual:(BOOL)manual
{
    NSString *key = [track key];
    @synchronized (self) {
        NSDictionary *old = TNDict(_matches[key]);
        if (!manual && TNBool(old[@"m"])) return;   // (the user's choice stays)
        if (videoId.length) _matches[key] = manual ? @{ @"v": videoId, @"m": @YES } : @{ @"v": videoId };
        else _matches[key] = @{ @"f": @([[NSDate date] timeIntervalSince1970]) };
    }
    [self scheduleSave];
    [self announce:key];
}

- (void)setVideoId:(NSString *)videoId forTrack:(TNTrack *)track
{
    if (!videoId.length || !track) return;
    track.videoId = videoId;
    track.matchFailed = NO;
    [self record:videoId forTrack:track manual:YES];
}

- (void)forget:(TNTrack *)track
{
    @synchronized (self) { [_matches removeObjectForKey:[track key]]; }
    if ([track isApple]) track.videoId = nil;
    track.matchFailed = NO;
    [self scheduleSave];
    [self announce:[track key]];
}

- (NSUInteger)matchCount
{
    NSUInteger n = 0;
    @synchronized (self) {
        for (NSString *key in _matches) if (![key hasPrefix:@"alt:"] && TNStr(TNDict(_matches[key])[@"v"]).length) n++;
    }
    return n;
}

- (void)forgetAll
{
    @synchronized (self) { [_matches removeAllObjects]; }
    [self scheduleSave];
    [self announce:nil];
}

#pragma mark - Searching

// The best of a list of candidates and its score
- (TNTrack *)bestOf:(NSArray *)items for:(TNTrack *)track score:(double *)bestScore titleScore:(double *)bestTitle durationScore:(double *)bestDuration
{
    NSString *title = TNNormalize(track.name, YES), *fullTitle = TNNormalize(track.name, NO);
    NSString *artists = TNNormalize([track artistNames], NO), *primary = TNNormalize(TNPrimaryArtist([track artistNames]), NO);
    TNTrack *best = nil;
    double top = -1, topTitle = 0, topDuration = 0;
    for (id item in items) {
        if (![item isKindOfClass:[TNTrack class]]) continue;
        TNTrack *c = item;
        if (!c.videoId.length) continue;
        double t = MAX(TNSimilarity(title, TNNormalize(c.name, YES)), TNSimilarity(fullTitle, TNNormalize(c.name, NO)));
        NSString *by = TNNormalize([c artistNames], NO);
        double a = TNSimilarity(artists, by);
        if (primary.length >= 2 && [[NSString stringWithFormat:@" %@ ", by] rangeOfString:[NSString stringWithFormat:@" %@ ", primary]].location != NSNotFound) a = MAX(a, 1.0);
        // (a music video often has the artist in its title: "Artist - Song (Official Video)")
        if (c.isVideo && a < 0.5 && primary.length >= 2 && [TNNormalize(c.name, NO) rangeOfString:primary].location != NSNotFound) a = 0.8;
        double d = TNDurationScore(track.durationMs, c.durationMs);
        double score = 0.45 * t + 0.3 * a + 0.25 * d - (c.isVideo ? 0.08 : 0);
        if (score > top) { top = score; best = c; topTitle = t; topDuration = d; }
    }
    if (bestScore) *bestScore = top;
    if (bestTitle) *bestTitle = topTitle;
    if (bestDuration) *bestDuration = topDuration;
    return best;
}

- (NSString *)searchFor:(TNTrack *)track error:(NSError **)error
{
    NSError *last = nil;
    double score = 0, title = 0, duration = 0;
    // 1. the recording's own code
    if (track.isrc.length) {
        NSError *e = nil;
        NSArray *items = [TNYTMusic searchSync:track.isrc filter:TNSearchSongs error:&e];
        if (!items) last = e;
        TNTrack *best = [self bestOf:items for:track score:&score titleScore:&title durationScore:&duration];
        if (best && title >= 0.5 && (duration >= 0.6 || score >= 0.6)) {
            TNLog(@"match %@ by ISRC: %@ (%.2f)", track.name, best.videoId, score);
            return best.videoId;
        }
    }
    // 2. title and artist among the songs, 3. among the videos
    NSString *query = [NSString stringWithFormat:@"%@ %@", track.name ?: @"", TNPrimaryArtist([track artistNames])];
    NSMutableArray *filters = [NSMutableArray arrayWithObject:@(TNSearchSongs)];
    if ([TNSettings allowVideosForApple]) [filters addObject:@(TNSearchVideos)];
    for (NSNumber *f in filters) {
        NSError *e = nil;
        NSArray *items = [TNYTMusic searchSync:query filter:(TNSearchFilter)[f integerValue] error:&e];
        if (!items) { last = e; continue; }
        TNTrack *best = [self bestOf:items for:track score:&score titleScore:&title durationScore:&duration];
        double needed = [f integerValue] == TNSearchSongs ? 0.62 : 0.66;
        if (best && score >= needed && title >= 0.5) {
            TNLog(@"match %@ by name (%@): %@ (%.2f)", track.name, [f integerValue] == TNSearchSongs ? @"songs" : @"videos", best.videoId, score);
            return best.videoId;
        }
    }
    TNLog(@"match %@ (%@): nothing fitted", track.name, [track artistNames]);
    if (error) *error = last ?: TNMakeError(TNErrorNoMatch, [NSString stringWithFormat:L(@"\"%@\" was not found on YouTube."), track.name ?: @""]);
    return nil;
}

#pragma mark - Other versions

- (NSString *)knownAlternativeFor:(NSString *)videoId
{
    if (!videoId.length) return nil;
    @synchronized (self) {
        NSString *v = TNStr(TNDict(_matches[[@"alt:" stringByAppendingString:videoId]])[@"v"]);
        return v.length ? v : nil;
    }
}

- (void)rememberAlternative:(NSString *)alternative for:(NSString *)videoId
{
    if (!videoId.length || !alternative.length) return;
    @synchronized (self) { _matches[[@"alt:" stringByAppendingString:videoId]] = @{ @"v": alternative }; }
    [self scheduleSave];
}

- (NSArray *)alternativesFor:(TNTrack *)track excluding:(NSString *)videoId durationMs:(NSInteger)durationMs
{
    TNTrack *wanted = track;
    if (durationMs > 0 && !track.durationMs) {
        wanted = [TNTrack fromJSON:[track toJSON]] ?: track;
        wanted.durationMs = durationMs;
    }
    NSString *query = [NSString stringWithFormat:@"%@ %@", track.name ?: @"", TNPrimaryArtist([track artistNames])];
    NSMutableArray *scored = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet setWithObject:videoId ?: @""];
    for (NSNumber *f in @[ @(TNSearchSongs), @(TNSearchVideos) ]) {
        NSArray *items = [TNYTMusic searchSync:query filter:(TNSearchFilter)[f integerValue] error:NULL];
        for (id item in items) {
            if (![item isKindOfClass:[TNTrack class]]) continue;
            TNTrack *c = item;
            if (!c.videoId.length || [seen containsObject:c.videoId]) continue;
            [seen addObject:c.videoId];
            double score = 0, title = 0, duration = 0;
            [self bestOf:@[ c ] for:wanted score:&score titleScore:&title durationScore:&duration];
            // (another version of the same recording: the title fits and so does the length, closely)
            if (title >= 0.5 && duration >= 0.6 && score >= 0.55) [scored addObject:@[ @(score), c.videoId ]];
        }
    }
    [scored sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    NSMutableArray *ids = [NSMutableArray array];
    for (NSArray *s in scored) if (ids.count < 4) [ids addObject:s[1]];
    TNLog(@"alternatives for %@ (%@): %@", track.name, videoId, [ids componentsJoinedByString:@", "]);
    return ids;
}

- (NSString *)videoIdForTrackSync:(TNTrack *)track error:(NSError **)error
{
    NSString *cached = [self cachedVideoIdFor:track];
    if (cached) return cached;
    NSError *e = nil;
    NSString *v = [self searchFor:track error:&e];
    // (a network failure is not remembered as "not found")
    if (v || e.code == TNErrorNoMatch) [self record:v forTrack:track manual:NO];
    if (!v && error) *error = e;
    return v;
}

#pragma mark - In the background

- (NSUInteger)pendingCount
{
    @synchronized (self) { return _pending.count; }
}

- (void)matchTracks:(NSArray *)tracks
{
    NSMutableArray *wanted = [NSMutableArray array];
    for (TNTrack *t in tracks) {
        if (![t isKindOfClass:[TNTrack class]] || ![t isApple] || t.videoId.length) continue;
        if ([self cachedVideoIdFor:t] || [self recentlyFailed:t]) continue;
        [wanted addObject:t];
    }
    if (!wanted.count) return;
    BOOL start = NO;
    @synchronized (self) {
        // the newest request goes first (the list on screen), in its own order
        NSUInteger at = 0;
        for (TNTrack *t in wanted) {
            NSString *key = [t key];
            if ([_pendingKeys containsObject:key]) {
                NSUInteger i = [_pending indexOfObjectPassingTest:^BOOL(TNTrack *x, NSUInteger idx, BOOL *stop) { return [[x key] isEqualToString:key]; }];
                if (i != NSNotFound) [_pending removeObjectAtIndex:i];
            }
            [_pending insertObject:t atIndex:MIN(at, _pending.count)];
            [_pendingKeys addObject:key];
            at++;
        }
        while (_pending.count > TNMaxPending) { [_pendingKeys removeObject:[[_pending lastObject] key]]; [_pending removeLastObject]; }
        if (!_working) { _working = YES; start = YES; }
    }
    if (start) dispatch_async(_queue, ^{ [self work]; });
}

- (void)work
{
    while (YES) {
        TNTrack *t = nil;
        @synchronized (self) {
            if (!_pending.count) { _working = NO; break; }
            t = _pending[0];
            [_pending removeObjectAtIndex:0];
            [_pendingKeys removeObject:[t key]];
        }
        @autoreleasepool {
            if (![self cachedVideoIdFor:t]) {
                NSError *e = nil;
                NSString *v = [self searchFor:t error:&e];
                if (v || e.code == TNErrorNoMatch) [self record:v forTrack:t manual:NO];
                else usleep(2000000);   // (the network is down: a pause before the next one)
                NSString *found = v;
                TNMain(^{
                    if (found) { if (!t.videoId.length) t.videoId = found; t.matchFailed = NO; }
                    else if (e.code == TNErrorNoMatch) t.matchFailed = YES;
                });
            }
        }
        usleep(150000);
    }
}

@end
