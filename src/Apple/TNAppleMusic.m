#import "TNAppleMusic.h"
#import "TNHTTPRequest.h"
#import "TNModels.h"
#import "TNLibrary.h"
#import "TNSettings.h"
#import "TNUtils.h"
#import "TNCommon.h"

static NSString * const TNAppleAPI = @"https://amp-api.music.apple.com";
static NSString * const TNAppleWeb = @"https://music.apple.com";
static NSString * const TNAppleUserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
static const NSUInteger TNScriptChunk = 512 * 1024;
static const NSUInteger TNMaxPlaylistSongs = 5000;

static void TNOnMainSync(dispatch_block_t block)
{
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

static NSData *TNBase64URLDecode(NSString *s)
{
    NSMutableString *b = [[s stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
    [b replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, b.length)];
    while (b.length % 4) [b appendString:@"="];
    return [TNUtils base64Decode:b];
}

@interface TNAppleMusic ()
@property (nonatomic) BOOL syncing;
@property (nonatomic, copy) NSString *syncStatus;
@end

@implementation TNAppleMusic {
    dispatch_queue_t _queue;
    NSLock *_tokenLock;
}

+ (instancetype)shared
{
    static TNAppleMusic *apple;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ apple = [[TNAppleMusic alloc] init]; });
    return apple;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.samcejko.muzika.apple", DISPATCH_QUEUE_CONCURRENT);
        _tokenLock = [[NSLock alloc] init];
    }
    return self;
}

- (BOOL)connected { return [TNSettings appleUserToken].length > 0; }

- (void)announce
{
    TNMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName:TNAppleDidChangeNotification object:self]; });
}

#pragma mark - HTTP

// One GET, redirects followed (blocking)
- (NSData *)fetchSync:(NSString *)urlString headers:(NSDictionary *)headers status:(NSInteger *)statusOut error:(NSError **)error
{
    NSURL *url = [NSURL URLWithString:urlString];
    NSError *failure = nil;
    for (int hop = 0; hop < 6 && url; hop++) {
        TNHTTPRequest *r = [[TNHTTPRequest alloc] initWithMethod:@"GET" URL:url];
        NSMutableDictionary *h = [NSMutableDictionary dictionaryWithDictionary:@{ @"User-Agent": TNAppleUserAgent }];
        [h addEntriesFromDictionary:headers ?: @{}];
        r.headers = h;
        r.connectTimeout = 15;
        r.readTimeout = 40;
        r.verifyTLS = [TNSettings verifyTLS];
        __block NSError *requestError = nil;
        r.onComplete = ^(NSError *e) { requestError = e; };
        [r runSynchronously];
        if (requestError) { failure = requestError; break; }
        NSInteger status = r.statusCode;
        if (status >= 300 && status < 400 && r.responseHeaders[@"location"]) {
            url = [[NSURL URLWithString:r.responseHeaders[@"location"] relativeToURL:url] absoluteURL];
            continue;
        }
        if (statusOut) *statusOut = status;
        return r.responseBody ?: [NSData data];
    }
    if (error) *error = failure ?: TNMakeError(TNErrorNetwork, L(@"Apple Music could not be reached."));
    return nil;
}

#pragma mark - The developer token

// The token of the web player sits in its script (a JWT signed by Apple, "iss": "AMPWebPlay", valid about 10 weeks).
// The script is ~3 MB; it is read in pieces until the token turns up.
- (NSString *)developerTokenSync:(NSError **)error
{
    NSString *token = [TNSettings appleDeveloperToken];
    if (token) return token;
    [_tokenLock lock];
    token = [TNSettings appleDeveloperToken];
    NSError *failure = nil;
    if (!token) token = [self fetchDeveloperToken:&failure];
    [_tokenLock unlock];
    if (!token && error) *error = failure ?: TNMakeError(TNErrorAPI, L(@"Apple Music's web player could not be read (it may have changed)."));
    return token;
}

- (NSString *)fetchDeveloperToken:(NSError **)error
{
    NSInteger status = 0;
    NSData *head = [self fetchSync:[TNAppleWeb stringByAppendingString:@"/us/new"] headers:@{ @"Range": @"bytes=0-98303" } status:&status error:error];
    if (!head) return nil;
    NSString *html = [[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding] ?: @"";
    NSRegularExpression *scriptRe = [NSRegularExpression regularExpressionWithPattern:@"/assets/index[^\"']*\\.js" options:0 error:NULL];
    NSTextCheckingResult *m = [scriptRe firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (!m) { TNLog(@"apple: no script in the page (%ld, %lu bytes)", (long)status, (unsigned long)head.length); return nil; }
    NSString *script = [TNAppleWeb stringByAppendingString:[html substringWithRange:m.range]];
    NSRegularExpression *jwtRe = [NSRegularExpression regularExpressionWithPattern:@"eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]{20,}" options:0 error:NULL];
    for (NSUInteger offset = 0; offset < 16 * 1024 * 1024; offset += TNScriptChunk) {
        NSString *range = [NSString stringWithFormat:@"bytes=%lu-%lu", (unsigned long)offset, (unsigned long)(offset + TNScriptChunk + 1023)];
        NSInteger s = 0;
        NSData *chunk = [self fetchSync:script headers:@{ @"Range": range } status:&s error:error];
        if (!chunk) return nil;
        if (s == 416) break;
        NSString *text = [[NSString alloc] initWithData:chunk encoding:NSISOLatin1StringEncoding] ?: @"";
        for (NSTextCheckingResult *r in [jwtRe matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
            NSString *jwt = [text substringWithRange:r.range];
            NSArray *parts = [jwt componentsSeparatedByString:@"."];
            NSDictionary *payload = TNDict([TNUtils JSONObjectFromData:TNBase64URLDecode(parts[1])]);
            if (![TNStr(payload[@"iss"]) isEqualToString:@"AMPWebPlay"]) continue;
            NSDate *expires = [NSDate dateWithTimeIntervalSince1970:TNDbl(payload[@"exp"])];
            if ([expires timeIntervalSinceNow] < 3600) continue;
            [TNSettings setAppleDeveloperToken:jwt expires:expires];
            TNLog(@"apple: web player token found at %lu, valid until %@", (unsigned long)offset, expires);
            return jwt;
        }
        if (s == 200 || chunk.length < TNScriptChunk) break;   // (the whole script came, or its end)
    }
    TNLog(@"apple: no token in %@", script);
    return nil;
}

#pragma mark - The API

- (NSDictionary *)apiGetSync:(NSString *)path user:(BOOL)user error:(NSError **)error
{
    NSString *userToken = [TNSettings appleUserToken];
    if (user && !userToken.length) {
        if (error) *error = TNMakeError(TNErrorNotConnected, L(@"Apple Music is not connected."));
        return nil;
    }
    NSString *url = [path hasPrefix:@"http"] ? path : [TNAppleAPI stringByAppendingString:path];
    for (int attempt = 0; attempt < 2; attempt++) {
        NSString *developer = [self developerTokenSync:error];
        if (!developer) return nil;
        NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:@{
            @"Authorization": [@"Bearer " stringByAppendingString:developer],
            @"Origin": TNAppleWeb, @"Referer": [TNAppleWeb stringByAppendingString:@"/"], @"Accept": @"application/json" }];
        if (user) headers[@"media-user-token"] = userToken;
        NSInteger status = 0;
        NSData *data = [self fetchSync:url headers:headers status:&status error:error];
        if (!data) return nil;
        NSDictionary *json = TNDict([TNUtils JSONObjectFromData:data]);
        if (status == 200 && json) return json;
        if (status == 404) return @{ @"data": @[] };
        if (status == 401 && attempt == 0) {
            // the web player's token went stale: a fresh one, once
            [TNSettings setAppleDeveloperToken:nil expires:nil];
            continue;
        }
        if ((status == 401 || status == 403) && user) {
            if (error) *error = TNMakeError(TNErrorAuth, L(@"Apple Music did not accept the token. Copy a fresh media-user-token from music.apple.com."));
            return nil;
        }
        NSString *message = TNStr(TNDict([TNArr(json[@"errors"]) firstObject])[@"detail"]) ?: TNStr(TNDict([TNArr(json[@"errors"]) firstObject])[@"title"]);
        if (error) *error = TNMakeError(TNErrorAPI, message.length ? [NSString stringWithFormat:L(@"Apple Music: %@"), message]
                                                                   : [NSString stringWithFormat:L(@"Apple Music answered with an error (HTTP %ld)."), (long)status]);
        return nil;
    }
    if (error) *error = TNMakeError(TNErrorAPI, L(@"Apple Music could not be reached."));
    return nil;
}

// Every page of a list ("next" links), up to `max` items
- (NSArray *)allPages:(NSString *)path user:(BOOL)user max:(NSUInteger)max error:(NSError **)error
{
    NSMutableArray *all = [NSMutableArray array];
    NSString *next = path;
    while (next.length && all.count < max) {
        NSDictionary *json = [self apiGetSync:next user:user error:error];
        if (!json) return all.count ? all : nil;
        [all addObjectsFromArray:TNArr(json[@"data"]) ?: @[]];
        NSString *n = TNStr(json[@"next"]);
        if (n.length && [n rangeOfString:@"limit="].location == NSNotFound) n = [n stringByAppendingString:[n rangeOfString:@"?"].location == NSNotFound ? @"?limit=100" : @"&limit=100"];
        next = n;
    }
    return all;
}

#pragma mark - Models

static TNTrack *TNTrackFromApple(NSDictionary *item)
{
    NSDictionary *a = TNDict(item[@"attributes"]);
    NSString *name = TNStr(a[@"name"]);
    if (!name.length) return nil;
    TNTrack *t = [[TNTrack alloc] init];
    t.name = name;
    t.byline = TNStr(a[@"artistName"]);
    TNArtist *artist = [[TNArtist alloc] init];
    artist.name = t.byline;
    if (artist.name.length) t.artists = @[ artist ];
    NSString *albumName = TNStr(a[@"albumName"]);
    if (albumName.length) { TNAlbum *album = [[TNAlbum alloc] init]; album.name = albumName; t.album = album; }
    t.durationMs = TNInt(a[@"durationInMillis"]);
    t.appleArtwork = TNStr(TNDict(a[@"artwork"])[@"url"]);
    t.explicitContent = [TNStr(a[@"contentRating"]) isEqualToString:@"explicit"];
    t.trackNumber = TNInt(a[@"trackNumber"]);
    t.isrc = TNStr(a[@"isrc"]);
    NSString *itemId = TNStr(item[@"id"]);
    NSString *type = TNStr(item[@"type"]) ?: @"";
    NSDictionary *play = TNDict(a[@"playParams"]);
    if ([type hasPrefix:@"library-"]) {
        t.appleId = itemId;
        t.appleCatalogId = TNStr(play[@"catalogId"]);
    } else {
        t.appleCatalogId = itemId;
    }
    if (!t.appleId.length && !t.appleCatalogId.length) t.appleId = [NSString stringWithFormat:@"%@|%@", name, t.byline ?: @""];
    t.isVideo = [type rangeOfString:@"video"].location != NSNotFound;
    return t;
}

static TNPlaylist *TNPlaylistFromApple(NSDictionary *item, BOOL library)
{
    NSDictionary *a = TNDict(item[@"attributes"]);
    TNPlaylist *p = [[TNPlaylist alloc] init];
    p.playlistId = TNStr(item[@"id"]);
    p.name = TNStr(a[@"name"]) ?: L(@"Playlist");
    p.descriptionText = TNStr(TNDict(a[@"description"])[@"standard"]) ?: TNStr(TNDict(a[@"description"])[@"short"]);
    p.appleArtwork = TNStr(TNDict(a[@"artwork"])[@"url"]);
    p.author = TNStr(a[@"curatorName"]) ?: TNStr(a[@"artistName"]);
    p.source = TNSourceApple;
    p.fromLibrary = library;
    p.modified = TNStr(a[@"lastModifiedDate"]) ?: TNStr(a[@"dateAdded"]);
    p.trackCount = TNInt(a[@"trackCount"]);
    return p.playlistId.length ? p : nil;
}

// The ISRCs (and missing artwork) of library songs from the catalog, 300 at a time
- (void)fillCatalogInfo:(NSArray *)tracks storefront:(NSString *)storefront
{
    NSMutableDictionary *byCatalogId = [NSMutableDictionary dictionary];
    for (TNTrack *t in tracks) if (t.appleCatalogId.length && !t.isrc.length) byCatalogId[t.appleCatalogId] = t;
    NSArray *ids = [byCatalogId allKeys];
    for (NSUInteger i = 0; i < ids.count; i += 300) {
        NSArray *batch = [ids subarrayWithRange:NSMakeRange(i, MIN((NSUInteger)300, ids.count - i))];
        NSString *path = [NSString stringWithFormat:@"/v1/catalog/%@/songs?ids=%@", storefront, [batch componentsJoinedByString:@","]];
        NSDictionary *json = [self apiGetSync:path user:NO error:NULL];
        for (id item in TNArr(json[@"data"]) ?: @[]) {
            NSDictionary *a = TNDict(TNDict(item)[@"attributes"]);
            TNTrack *t = byCatalogId[TNStr(TNDict(item)[@"id"]) ?: @""];
            if (!t) continue;
            t.isrc = TNStr(a[@"isrc"]);
            if (!t.appleArtwork.length) t.appleArtwork = TNStr(TNDict(a[@"artwork"])[@"url"]);
            if (!t.durationMs) t.durationMs = TNInt(a[@"durationInMillis"]);
        }
    }
}

- (NSArray *)tracksOfPlaylistSync:(TNPlaylist *)playlist error:(NSError **)error
{
    NSString *storefront = playlist.storefront.length ? playlist.storefront : [TNSettings appleStorefront];
    NSArray *items;
    if (playlist.fromLibrary) {
        items = [self allPages:[NSString stringWithFormat:@"/v1/me/library/playlists/%@/tracks?limit=100", [TNUtils urlEncode:playlist.playlistId]]
                          user:YES max:TNMaxPlaylistSongs error:error];
    } else if ([playlist.playlistId hasPrefix:@"album:"]) {
        items = [self allPages:[NSString stringWithFormat:@"/v1/catalog/%@/albums/%@/tracks?limit=100", storefront, [playlist.playlistId substringFromIndex:6]]
                          user:NO max:TNMaxPlaylistSongs error:error];
    } else {
        items = [self allPages:[NSString stringWithFormat:@"/v1/catalog/%@/playlists/%@/tracks?limit=100", storefront, [TNUtils urlEncode:playlist.playlistId]]
                          user:NO max:TNMaxPlaylistSongs error:error];
    }
    if (!items) return nil;
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in items) { TNTrack *t = TNTrackFromApple(TNDict(item)); if (t) [tracks addObject:t]; }
    if (playlist.fromLibrary) [self fillCatalogInfo:tracks storefront:storefront];
    TNLog(@"apple: %@ has %lu songs", playlist.name, (unsigned long)tracks.count);
    return tracks;
}

#pragma mark - Connecting, syncing

- (void)connectWithToken:(NSString *)token completion:(void (^)(NSError *))completion
{
    NSString *t = [[token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] stringByReplacingOccurrencesOfString:@"\"" withString:@""];
    if ([t hasPrefix:@"media-user-token="]) t = [t substringFromIndex:@"media-user-token=".length];
    if (t.length < 40) { completion(TNMakeError(TNErrorAuth, L(@"This does not look like a media-user-token."))); return; }
    NSString *previous = [TNSettings appleUserToken];
    [TNSettings setAppleUserToken:t];
    dispatch_async(_queue, ^{
        NSError *error = nil;
        NSDictionary *json = [self apiGetSync:@"/v1/me/storefront" user:YES error:&error];
        NSString *storefront = TNStr(TNDict([TNArr(json[@"data"]) firstObject])[@"id"]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!storefront.length) {
                [TNSettings setAppleUserToken:previous];
                completion(error ?: TNMakeError(TNErrorAuth, L(@"Apple Music did not accept the token.")));
                return;
            }
            [TNSettings setAppleStorefront:storefront];
            TNLog(@"apple: connected, storefront %@", storefront);
            [self announce];
            completion(nil);
            [self syncWithCompletion:nil];
        });
    });
}

- (void)disconnect
{
    [TNSettings setAppleUserToken:nil];
    [TNSettings setAppleLastSync:nil];
    [[TNLibrary shared] forgetApple];
    [self announce];
}

- (void)setStatus:(NSString *)status
{
    TNMain(^{
        self.syncStatus = status;
        [[NSNotificationCenter defaultCenter] postNotificationName:TNAppleDidChangeNotification object:self];
    });
}

- (void)syncWithCompletion:(void (^)(NSError *))completion
{
    if (self.syncing || ![self connected]) {
        if (completion) completion(self.syncing ? nil : TNMakeError(TNErrorNotConnected, L(@"Apple Music is not connected.")));
        return;
    }
    self.syncing = YES;
    [self setStatus:L(@"Loading your playlists…")];
    NSMutableDictionary *old = [NSMutableDictionary dictionary];
    for (TNPlaylist *p in [[TNLibrary shared] applePlaylists]) old[p.playlistId] = p;
    dispatch_async(_queue, ^{
        NSError *error = nil;
        NSArray *items = [self allPages:@"/v1/me/library/playlists?limit=100" user:YES max:2000 error:&error];
        NSMutableArray *playlists = [NSMutableArray array];
        for (id item in items ?: @[]) {
            TNPlaylist *p = TNPlaylistFromApple(TNDict(item), YES);
            if (!p) continue;
            p.storefront = [TNSettings appleStorefront];
            TNPlaylist *was = old[p.playlistId];
            if (!p.trackCount) p.trackCount = was.trackCount;
            [playlists addObject:p];
        }
        if (items) TNOnMainSync(^{ [[TNLibrary shared] setApplePlaylists:playlists]; });
        NSUInteger n = 0;
        for (TNPlaylist *p in items ? playlists : @[]) {
            n++;
            TNPlaylist *was = old[p.playlistId];
            __block BOOL have = NO;
            TNOnMainSync(^{ have = [[TNLibrary shared] tracksOfPlaylist:p] != nil; });
            if (have && was && [was.modified isEqualToString:p.modified ?: @""]) continue;
            [self setStatus:[NSString stringWithFormat:L(@"Playlist %lu of %lu: %@"), (unsigned long)n, (unsigned long)playlists.count, p.name ?: @""]];
            NSError *e = nil;
            NSArray *tracks = [self tracksOfPlaylistSync:p error:&e];
            if (!tracks) { if (!error) error = e; continue; }
            TNOnMainSync(^{
                p.trackCount = (NSInteger)tracks.count;
                [[TNLibrary shared] setTracks:tracks ofPlaylist:p];
                [[TNLibrary shared] setApplePlaylists:[[TNLibrary shared] applePlaylists]];
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.syncing = NO;
            if (items) [TNSettings setAppleLastSync:[NSDate date]];
            [self setStatus:error ? error.localizedDescription : nil];
            TNLog(@"apple: sync done, %lu playlists%@", (unsigned long)playlists.count, error ? [@", " stringByAppendingString:error.localizedDescription] : @"");
            if (completion) completion(error);
        });
    });
}

- (TNHTTPTask *)tracksOf:(TNPlaylist *)playlist completion:(void (^)(NSArray *, NSError *))completion
{
    TNHTTPTask *task = [[TNHTTPTask alloc] init];
    dispatch_async(_queue, ^{
        NSError *error = nil;
        NSArray *tracks = [self tracksOfPlaylistSync:playlist error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task.isCancelled) return;
            if (tracks) {
                playlist.trackCount = (NSInteger)tracks.count;
                [[TNLibrary shared] setTracks:tracks ofPlaylist:playlist];
            }
            completion(tracks, error);
        });
    });
    return task;
}

#pragma mark - Links

+ (BOOL)isAppleMusicLink:(NSString *)text
{
    return [text rangeOfString:@"music.apple.com/"].location != NSNotFound || [text rangeOfString:@"itunes.apple.com/"].location != NSNotFound;
}

- (TNHTTPTask *)importLink:(NSString *)link completion:(void (^)(TNPlaylist *, NSArray *, NSError *))completion
{
    // https://music.apple.com/cz/playlist/name/pl.u-xxxx?l=en, https://music.apple.com/us/album/name/123456?i=789
    NSString *s = [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRange host = [s rangeOfString:@".apple.com/"];
    NSString *path = host.location != NSNotFound ? [s substringFromIndex:host.location + host.length] : @"";
    path = [[path componentsSeparatedByString:@"?"] firstObject];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *p in [path componentsSeparatedByString:@"/"]) if (p.length) [parts addObject:p];
    TNHTTPTask *task = [[TNHTTPTask alloc] init];
    NSString *storefront = parts.count >= 3 && [parts[0] length] == 2 ? [parts[0] lowercaseString] : [TNSettings appleStorefront];
    if (parts.count >= 1 && [parts[0] length] == 2) [parts removeObjectAtIndex:0];
    NSString *type = parts.count ? parts[0] : @"";
    NSString *identifier = parts.count >= 2 ? [parts lastObject] : @"";
    if (!([type isEqualToString:@"playlist"] || [type isEqualToString:@"album"]) || !identifier.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, nil, TNMakeError(TNErrorAPI, L(@"This is no link to an Apple Music playlist or album.")));
        });
        return task;
    }
    BOOL album = [type isEqualToString:@"album"];
    dispatch_async(_queue, ^{
        NSError *error = nil;
        NSString *infoPath = [NSString stringWithFormat:@"/v1/catalog/%@/%@/%@", storefront, album ? @"albums" : @"playlists", [TNUtils urlEncode:identifier]];
        NSDictionary *json = [self apiGetSync:infoPath user:NO error:&error];
        NSDictionary *item = TNDict([TNArr(json[@"data"]) firstObject]);
        TNPlaylist *playlist = item ? TNPlaylistFromApple(item, NO) : nil;
        NSArray *tracks = nil;
        if (playlist) {
            playlist.storefront = storefront;
            if (album) playlist.playlistId = [@"album:" stringByAppendingString:playlist.playlistId];
            tracks = [self tracksOfPlaylistSync:playlist error:&error];
            playlist.trackCount = (NSInteger)tracks.count;
        } else if (!error) {
            error = TNMakeError(TNErrorAPI, L(@"Apple Music does not know this link (a private playlist cannot be imported)."));
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task.isCancelled) return;
            if (playlist && tracks) [[TNLibrary shared] setTracks:tracks ofPlaylist:playlist];
            completion(tracks ? playlist : nil, tracks, tracks ? nil : error);
        });
    });
    return task;
}

- (NSString *)debugState
{
    return [NSString stringWithFormat:@"apple: %@, storefront %@, developer token %@, %lu playlists, %@%@",
            [self connected] ? @"connected" : @"not connected", [TNSettings appleStorefront], [TNSettings appleDeveloperToken] ? @"valid" : @"none",
            (unsigned long)[[TNLibrary shared] applePlaylists].count, self.syncing ? @"syncing" : @"idle",
            self.syncStatus.length ? [@": " stringByAppendingString:self.syncStatus] : @""];
}

@end
