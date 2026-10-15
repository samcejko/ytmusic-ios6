#import "TNStreams.h"
#import "TNYTMusic.h"
#import "TNHTTPRequest.h"
#import "TNSettings.h"
#import "TNUtils.h"
#import "TNCommon.h"

static NSString * const TNPlayerURL = @"https://www.youtube.com/youtubei/v1/player?prettyPrint=false";
static NSString * const TNVisionVersion = @"0.1";

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

+ (void)remember:(NSString *)url durationMs:(NSInteger)ms forVideo:(NSString *)videoId
{
    long long expire = [TNQueryValue(url, @"expire") longLongValue];
    NSDate *until = expire > 0 ? [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)expire - 900] : [NSDate dateWithTimeIntervalSinceNow:3600];
    @synchronized (TNStreamCache()) {
        if (TNStreamCache().count > 200) [TNStreamCache() removeAllObjects];
        TNStreamCache()[videoId] = @{ @"url": url, @"ms": @(ms), @"until": until };
    }
}

#pragma mark - Straight from YouTube

// The player API as YouTube's visionOS app: @{url, ms}, or nil. `refused`: YouTube turned the client itself away (a
// bot check, a sign-in, a changed API) rather than this one song.
+ (NSDictionary *)directSync:(NSString *)videoId visitorData:(NSString *)visitorData refused:(BOOL *)refused error:(NSError **)error
{
    *refused = NO;
    NSMutableDictionary *client = [@{ @"clientName": @"VISIONOS", @"clientVersion": TNVisionVersion, @"deviceMake": @"Apple",
                                      @"deviceModel": @"RealityDevice14,1", @"osName": @"visionOS", @"osVersion": @"1.3.21O771",
                                      @"hl": [TNYTMusic language], @"gl": [TNYTMusic region] } mutableCopy];
    if (visitorData.length) client[@"visitorData"] = visitorData;
    NSDictionary *body = @{ @"videoId": videoId, @"context": @{ @"client": client }, @"contentCheckOk": @YES, @"racyCheckOk": @YES };
    NSMutableDictionary *headers = [@{ @"Content-Type": @"application/json", @"Accept": @"application/json",
                                       @"User-Agent": @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                                       @"Origin": @"https://www.youtube.com", @"X-YouTube-Client-Name": @"101",
                                       @"X-YouTube-Client-Version": TNVisionVersion } mutableCopy];
    if (visitorData.length) headers[@"X-Goog-Visitor-Id"] = visitorData;
    TNHTTPRequest *r = [[TNHTTPRequest alloc] initWithMethod:@"POST" URL:[NSURL URLWithString:TNPlayerURL]];
    r.headers = headers;
    r.body = [TNUtils JSONDataFromObject:body];
    r.connectTimeout = 15;
    r.readTimeout = 25;
    r.verifyTLS = [TNSettings verifyTLS];
    r.highPriority = YES;
    __block NSError *requestError = nil;
    r.onComplete = ^(NSError *e) { requestError = e; };
    [r runSynchronously];
    if (requestError) {
        if (error) *error = requestError;
        return nil;
    }
    NSDictionary *json = TNDict([TNUtils JSONObjectFromData:r.responseBody]);
    if (r.statusCode != 200 || !json) {
        *refused = YES;
        if (error) *error = TNMakeError(TNErrorRefused, [NSString stringWithFormat:L(@"YouTube answered with an error (HTTP %ld)."), (long)r.statusCode]);
        return nil;
    }
    NSDictionary *playability = TNDict(json[@"playabilityStatus"]);
    NSString *status = TNStr(playability[@"status"]) ?: @"";
    if (![status isEqualToString:@"OK"]) {
        NSString *reason = TNStr(playability[@"reason"]) ?: status;
        *refused = [status isEqualToString:@"LOGIN_REQUIRED"] || [[reason lowercaseString] rangeOfString:@"bot"].location != NSNotFound;
        if (error) *error = TNMakeError(*refused ? TNErrorRefused : TNErrorRestricted, reason);
        return nil;
    }
    NSDictionary *streaming = TNDict(json[@"streamingData"]);
    for (id f in TNArr(streaming[@"adaptiveFormats"]) ?: @[]) {
        NSDictionary *format = TNDict(f);
        if (TNInt(format[@"itag"]) != 140) continue;
        NSString *url = TNStr(format[@"url"]);
        if (!url.length) continue;   // (a ciphered one: not for this client)
        NSInteger ms = TNInt(format[@"approxDurationMs"]);
        if (!ms) ms = TNInt(TNDict(json[@"videoDetails"])[@"lengthSeconds"]) * 1000;
        return @{ @"url": url, @"ms": @(ms) };
    }
    // no plain address at all: the API changed for this client
    *refused = YES;
    if (error) *error = TNMakeError(TNErrorRefused, L(@"YouTube offers no sound this player knows for this song."));
    return nil;
}

#pragma mark - The address

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
    // (a stale visitor id is renewed once)
    BOOL refused = NO;
    NSError *directError = nil;
    NSString *visitor = [TNYTMusic visitorData] ?: [TNYTMusic freshVisitorDataSync];
    NSDictionary *found = [self directSync:videoId visitorData:visitor refused:&refused error:&directError];
    if (!found && refused) {
        visitor = [TNYTMusic freshVisitorDataSync];
        found = [self directSync:videoId visitorData:visitor refused:&refused error:&directError];
    }
    if (!found) {
        // a reason about this song (removed, region) skips to the next one; YouTube refusing the app altogether stops
        if (error) *error = directError ?: TNMakeError(TNErrorRefused, L(@"YouTube did not give the sound right now. Try again later."));
        return nil;
    }
    NSString *url = found[@"url"];
    NSInteger ms = [found[@"ms"] integerValue];
    [self remember:url durationMs:ms forVideo:videoId];
    if (durationMs) *durationMs = ms;
    TNLog(@"audio of %@: %.0f s", videoId, ms / 1000.0);
    return url;
}

@end
