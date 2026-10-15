#import "TNLyrics.h"
#import "TNYTMusic.h"
#import "TNModels.h"
#import "TNHTTPRequest.h"
#import "TNSettings.h"
#import "TNUtils.h"
#import "TNCommon.h"

@implementation TNLyricsResult
@end

@implementation TNLyrics

static NSMutableDictionary *TNLyricsCache(void)
{
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

// "Get Lucky (feat. Pharrell Williams) [Radio Edit]" -> "Get Lucky"
static NSString *TNCleanTitle(NSString *title)
{
    NSMutableString *m = [title ?: @"" mutableCopy];
    for (NSArray *pair in @[ @[ @"(", @")" ], @[ @"[", @"]" ] ]) {
        while (YES) {
            NSRange open = [m rangeOfString:pair[0]];
            if (open.location == NSNotFound || open.location == 0) break;
            NSRange close = [m rangeOfString:pair[1] options:0 range:NSMakeRange(open.location, m.length - open.location)];
            NSUInteger end = close.location == NSNotFound ? m.length : close.location + 1;
            [m deleteCharactersInRange:NSMakeRange(open.location, end - open.location)];
        }
    }
    NSRange dash = [m rangeOfString:@" - "];
    if (dash.location != NSNotFound && dash.location > 0) [m deleteCharactersInRange:NSMakeRange(dash.location, m.length - dash.location)];
    return [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static NSString *TNFirstArtist(NSString *artists)
{
    NSString *s = artists ?: @"";
    for (NSString *sep in @[ @" & ", @", ", @" feat. ", @" x ", @" and " ]) {
        NSRange r = [s rangeOfString:sep];
        if (r.location != NSNotFound && r.location > 0) s = [s substringToIndex:r.location];
    }
    return s;
}

// "[01:02.34]words" (a line may carry several times) -> {ms, text}, in time order
static NSArray *TNParseLRC(NSString *lrc)
{
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *raw in [lrc componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSMutableArray *times = [NSMutableArray array];
        while ([line hasPrefix:@"["]) {
            NSRange close = [line rangeOfString:@"]"];
            if (close.location == NSNotFound) break;
            NSString *stamp = [line substringWithRange:NSMakeRange(1, close.location - 1)];
            NSArray *parts = [stamp componentsSeparatedByString:@":"];
            if (parts.count == 2 && [parts[0] length] && [[parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet decimalDigitCharacterSet]] length] == 0) {
                [times addObject:@((NSInteger)([parts[0] integerValue] * 60000 + [parts[1] doubleValue] * 1000))];
            }
            line = [line substringFromIndex:close.location + 1];
        }
        NSString *text = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        for (NSNumber *ms in times) [lines addObject:@{ @"ms": ms, @"text": [TNUtils displayText:text] ?: @"" }];
    }
    [lines sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"ms"] compare:b[@"ms"]]; }];
    return lines;
}

// One LRCLIB call; a busy server (429, 503) is asked again once after a moment. *failed: no answer at all.
+ (id)lrclibGet:(NSString *)url failed:(BOOL *)failed
{
    for (int attempt = 0; attempt < 2; attempt++) {
        if (attempt) [NSThread sleepForTimeInterval:2.5];
        TNHTTPRequest *r = [[TNHTTPRequest alloc] initWithMethod:@"GET" URL:[NSURL URLWithString:url]];
        r.headers = @{ @"Accept": @"application/json", @"User-Agent": @"Muzika 0.1 (iOS 6 music app; https://github.com/samcejko)" };
        r.connectTimeout = 15;
        r.readTimeout = 20;
        r.verifyTLS = [TNSettings verifyTLS];
        __block NSError *failure = nil;
        r.onComplete = ^(NSError *e) { failure = e; };
        [r runSynchronously];
        if (!failure && r.statusCode == 200) return [TNUtils JSONObjectFromData:r.responseBody];
        if (!failure && r.statusCode == 404) return nil;
        TNLog(@"lrclib: %@", failure ? failure.localizedDescription : [NSString stringWithFormat:@"HTTP %ld", (long)r.statusCode]);
        if (!failure && r.statusCode != 429 && r.statusCode < 500) break;
    }
    if (failed) *failed = YES;
    return nil;
}

// The exact song first (LRCLIB's cached "get" by title, artist and length), else a search
+ (NSArray *)lrclibSearch:(NSString *)title artist:(NSString *)artist durationMs:(NSInteger)ms failed:(BOOL *)failed
{
    if (ms > 0) {
        NSString *get = [NSString stringWithFormat:@"https://lrclib.net/api/get?track_name=%@&artist_name=%@&duration=%ld",
                         [TNUtils urlEncode:title], [TNUtils urlEncode:artist], (long)lround(ms / 1000.0)];
        NSDictionary *exact = TNDict([self lrclibGet:get failed:failed]);
        if (TNStr(exact[@"syncedLyrics"]).length) return @[ exact ];
        if (failed && *failed) return nil;
    }
    NSString *url = [NSString stringWithFormat:@"https://lrclib.net/api/search?track_name=%@&artist_name=%@", [TNUtils urlEncode:title], [TNUtils urlEncode:artist]];
    return TNArr([self lrclibGet:url failed:failed]);
}

+ (TNHTTPTask *)lyricsFor:(TNTrack *)track videoId:(NSString *)videoId durationMs:(NSInteger)durationMs
               completion:(void (^)(TNLyricsResult *, NSError *))completion
{
    TNHTTPTask *task = [[TNHTTPTask alloc] init];
    NSString *key = [track key] ?: videoId ?: @"";
    TNLyricsResult *cached;
    @synchronized (TNLyricsCache()) { cached = TNLyricsCache()[key]; }
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (!task.isCancelled) completion(cached, nil); });
        return task;
    }
    NSString *title = TNCleanTitle(track.name), *artist = TNFirstArtist([track artistNames]);
    NSInteger ms = durationMs ?: track.durationMs;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        TNLyricsResult *result = nil;
        // 1. LRCLIB, the version whose length fits (within 3 s) with lines in time
        BOOL lrclibFailed = NO;
        NSArray *found = title.length ? [self lrclibSearch:title artist:artist durationMs:ms failed:&lrclibFailed] : nil;
        NSDictionary *best = nil, *plain = nil;
        for (id x in found ?: @[]) {
            NSDictionary *d = TNDict(x);
            double length = TNDbl(d[@"duration"]);
            BOOL fits = !ms || fabs(length - ms / 1000.0) <= 3.0;
            if (!fits) continue;
            if (TNStr(d[@"syncedLyrics"]).length) { best = d; break; }
            if (!plain && TNStr(d[@"plainLyrics"]).length) plain = d;
        }
        if (best) {
            result = [[TNLyricsResult alloc] init];
            result.lines = TNParseLRC(TNStr(best[@"syncedLyrics"]));
            result.synced = result.lines.count > 0;
            result.source = @"LRCLIB";
        }
        // 2. YouTube Music's own (plain) text
        if (!result.lines.count && videoId.length) {
            __block NSString *text = nil, *source = nil;
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_main_queue(), ^{
                [TNYTMusic lyricsFor:videoId completion:^(NSString *t, NSString *s, NSError *e) {
                    text = t;
                    source = s;
                    dispatch_semaphore_signal(done);
                }];
            });
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
            if (!text.length && plain) { text = TNStr(plain[@"plainLyrics"]); source = @"LRCLIB"; }
            if (text.length) {
                NSMutableArray *lines = [NSMutableArray array];
                for (NSString *l in [text componentsSeparatedByString:@"\n"]) [lines addObject:@{ @"ms": @0, @"text": [TNUtils displayText:l] ?: @"" }];
                while (lines.count && ![lines.lastObject[@"text"] length]) [lines removeLastObject];
                result = [[TNLyricsResult alloc] init];
                result.lines = lines;
                result.source = [source stringByReplacingOccurrencesOfString:@"Source: " withString:@""];
            }
        }
        // (YouTube's plain text in place of LRCLIB that did not answer is not kept: next time LRCLIB is asked again)
        if (result && (result.synced || !lrclibFailed)) {
            @synchronized (TNLyricsCache()) { TNLyricsCache()[key] = result; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task.isCancelled) return;
            completion(result, result ? nil : TNMakeError(TNErrorAPI, L(@"No lyrics for this song.")));
        });
    });
    return task;
}

@end
