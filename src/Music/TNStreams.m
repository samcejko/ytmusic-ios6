#import "TNStreams.h"
#import "TNHTTPRequest.h"
#import "TNSettings.h"
#import "TNUtils.h"
#import "TNCommon.h"

@implementation TNStreams

static NSMutableDictionary *TNStreamCache(void)
{
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

// A parameter of a googlevideo address ("expire", "dur")
static NSString *TNQueryValue(NSString *url, NSString *name)
{
    NSRange q = [url rangeOfString:@"?"];
    if (q.location == NSNotFound) return nil;
    for (NSString *pair in [[url substringFromIndex:q.location + 1] componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location != NSNotFound && [[pair substringToIndex:eq.location] isEqualToString:name]) return [pair substringFromIndex:eq.location + 1];
    }
    return nil;
}

+ (void)forget:(NSString *)videoId
{
    if (!videoId) return;
    @synchronized (TNStreamCache()) { [TNStreamCache() removeObjectForKey:videoId]; }
}

+ (NSString *)audioURLForVideo:(NSString *)videoId durationMs:(NSInteger *)durationMs error:(NSError **)error
{
    if (!videoId.length) {
        if (error) *error = TNMakeError(TNErrorPlayback, L(@"This song cannot be played."));
        return nil;
    }
    NSDictionary *cached;
    @synchronized (TNStreamCache()) { cached = TNStreamCache()[videoId]; }
    if (cached && [cached[@"until"] timeIntervalSinceNow] > 0) {
        if (durationMs) *durationMs = [cached[@"ms"] integerValue];
        return cached[@"url"];
    }
    NSString *base = [TNSettings resolverBase];
    if (!base.length) {
        if (error) *error = TNMakeError(TNErrorPlayback, L(@"No audio helper is set (Settings). Without it YouTube plays only the first minute."));
        return nil;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/resolve?id=%@", base, [TNUtils urlEncode:videoId]]];
    NSError *failure = nil;
    NSDictionary *json = nil;
    for (int attempt = 0; attempt < 2 && !json; attempt++) {
        TNHTTPRequest *r = [[TNHTTPRequest alloc] initWithMethod:@"GET" URL:url];
        r.headers = @{ @"Accept": @"application/json" };
        r.connectTimeout = 15;
        r.readTimeout = 45;   // (the helper asks YouTube itself: a few seconds)
        r.verifyTLS = [TNSettings verifyTLS];
        r.highPriority = YES;
        __block NSError *requestError = nil;
        r.onComplete = ^(NSError *e) { requestError = e; };
        [r runSynchronously];
        if (requestError) {
            failure = TNMakeError(TNErrorHelper, [NSString stringWithFormat:@"%@ (%@)", L(@"The audio helper could not be reached."), requestError.localizedDescription]);
            usleep(300000);
            continue;
        }
        NSDictionary *j = TNDict([TNUtils JSONObjectFromData:r.responseBody]);
        if (r.statusCode == 200 && j) { json = j; break; }
        NSString *message = TNStr(j[@"error"]) ?: TNStr(j[@"detail"]);
        // (the helper or its tunnel down: no song will play; an answer about this one song: the next may)
        BOOL helperDown = r.statusCode >= 500 || !j;
        failure = TNMakeError(helperDown ? TNErrorHelper : TNErrorPlayback,
                              message.length ? [NSString stringWithFormat:L(@"The audio helper: %@"), message]
                                             : [NSString stringWithFormat:L(@"The audio helper answered with HTTP %ld."), (long)r.statusCode]);
        if (!helperDown) break;
    }
    if (!json) {
        if (error) *error = failure ?: TNMakeError(TNErrorHelper, L(@"The audio helper could not be reached."));
        return nil;
    }
    NSDictionary *formats = TNDict(json[@"formats"]);
    NSString *audio = TNStr(formats[@"140"]);
    if (!audio.length) {
        if (error) *error = TNMakeError(TNErrorPlayback, L(@"YouTube offers no sound this player knows for this song."));
        return nil;
    }
    NSInteger ms = (NSInteger)(TNDbl(json[@"duration"]) * 1000);
    if (!ms) ms = (NSInteger)([TNQueryValue(audio, @"dur") doubleValue] * 1000);
    long long expire = [TNQueryValue(audio, @"expire") longLongValue];
    NSDate *until = expire > 0 ? [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)expire - 900] : [NSDate dateWithTimeIntervalSinceNow:3600];
    @synchronized (TNStreamCache()) {
        if (TNStreamCache().count > 200) [TNStreamCache() removeAllObjects];
        TNStreamCache()[videoId] = @{ @"url": audio, @"ms": @(ms), @"until": until };
    }
    if (durationMs) *durationMs = ms;
    TNLog(@"resolved %@: %.0f s", videoId, ms / 1000.0);
    return audio;
}

@end
