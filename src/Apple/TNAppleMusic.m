#import "TNLegacyCollections.h"
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
static const NSUInteger TNMaxLibrarySongs = 8000;
static const NSUInteger TNMaxRatingLookups = 3000;

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
    return [self fetchSync:urlString method:@"GET" body:nil headers:headers status:statusOut error:error];
}

- (NSData *)fetchSync:(NSString *)urlString method:(NSString *)method body:(NSData *)body headers:(NSDictionary *)headers
               status:(NSInteger *)statusOut error:(NSError **)error
{
    NSURL *url = [NSURL URLWithString:urlString];
    NSError *failure = nil;
    for (int hop = 0; hop < 6 && url; hop++) {
        TNHTTPRequest *r = [[TNHTTPRequest alloc] initWithMethod:hop ? @"GET" : method URL:url];
        if (!hop && body) r.body = body;
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
        if (status >= 300 && status < 400 && [r.responseHeaders objectForKey:@"location"]) {
            url = [[NSURL URLWithString:[r.responseHeaders objectForKey:@"location"] relativeToURL:url] absoluteURL];
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
            NSDictionary *payload = TNDict([TNUtils JSONObjectFromData:TNBase64URLDecode([parts objectAtIndex:1])]);
            if (![TNStr([payload objectForKey:@"iss"]) isEqualToString:@"AMPWebPlay"]) continue;
            NSDate *expires = [NSDate dateWithTimeIntervalSince1970:TNDbl([payload objectForKey:@"exp"])];
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
    return [self apiSync:@"GET" path:path body:nil user:user error:error];
}

// Any call: a JSON body for POST and PUT; an answer without a body (204) is an empty dictionary
- (NSDictionary *)apiSync:(NSString *)method path:(NSString *)path body:(id)bodyJSON user:(BOOL)user error:(NSError **)error
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
        if (user) TNLegacyDictionarySet(headers, @"media-user-token", userToken);
        NSData *body = bodyJSON ? [TNUtils JSONDataFromObject:bodyJSON] : nil;
        if (body) TNLegacyDictionarySet(headers, @"Content-Type", @"application/json");
        NSInteger status = 0;
        NSData *data = [self fetchSync:url method:method body:body headers:headers status:&status error:error];
        if (!data) return nil;
        NSDictionary *json = TNDict([TNUtils JSONObjectFromData:data]);
        if (status == 200 && json) return json;
        if (![method isEqualToString:@"GET"] && status >= 200 && status < 300) return json ?: @{};
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
        NSString *message = TNStr([TNDict([TNArr([json objectForKey:@"errors"]) firstObject]) objectForKey:@"detail"]) ?: TNStr([TNDict([TNArr([json objectForKey:@"errors"]) firstObject]) objectForKey:@"title"]);
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
        [all addObjectsFromArray:TNArr([json objectForKey:@"data"]) ?: @[]];
        NSString *n = TNStr([json objectForKey:@"next"]);
        if (n.length && [n rangeOfString:@"limit="].location == NSNotFound) n = [n stringByAppendingString:[n rangeOfString:@"?"].location == NSNotFound ? @"?limit=100" : @"&limit=100"];
        next = n;
    }
    return all;
}

#pragma mark - Models

static TNTrack *TNTrackFromApple(NSDictionary *item)
{
    NSDictionary *a = TNDict([item objectForKey:@"attributes"]);
    NSString *name = TNStr([a objectForKey:@"name"]);
    if (!name.length) return nil;
    TNTrack *t = [[TNTrack alloc] init];
    t.name = name;
    t.byline = TNStr([a objectForKey:@"artistName"]);
    TNArtist *artist = [[TNArtist alloc] init];
    artist.name = t.byline;
    if (artist.name.length) t.artists = @[ artist ];
    NSString *albumName = TNStr([a objectForKey:@"albumName"]);
    if (albumName.length) { TNAlbum *album = [[TNAlbum alloc] init]; album.name = albumName; t.album = album; }
    t.durationMs = TNInt([a objectForKey:@"durationInMillis"]);
    t.appleArtwork = TNStr([TNDict([a objectForKey:@"artwork"]) objectForKey:@"url"]);
    t.explicitContent = [TNStr([a objectForKey:@"contentRating"]) isEqualToString:@"explicit"];
    t.trackNumber = TNInt([a objectForKey:@"trackNumber"]);
    t.isrc = TNStr([a objectForKey:@"isrc"]);
    NSString *itemId = TNStr([item objectForKey:@"id"]);
    NSString *type = TNStr([item objectForKey:@"type"]) ?: @"";
    NSDictionary *play = TNDict([a objectForKey:@"playParams"]);
    if ([type hasPrefix:@"library-"]) {
        t.appleId = itemId;
        t.appleCatalogId = TNStr([play objectForKey:@"catalogId"]);
    } else {
        t.appleCatalogId = itemId;
    }
    if (!t.appleId.length && !t.appleCatalogId.length) t.appleId = [NSString stringWithFormat:@"%@|%@", name, t.byline ?: @""];
    t.isVideo = [type rangeOfString:@"video"].location != NSNotFound;
    return t;
}

static TNPlaylist *TNPlaylistFromApple(NSDictionary *item, BOOL library)
{
    NSDictionary *a = TNDict([item objectForKey:@"attributes"]);
    TNPlaylist *p = [[TNPlaylist alloc] init];
    p.playlistId = TNStr([item objectForKey:@"id"]);
    p.name = TNStr([a objectForKey:@"name"]) ?: L(@"Playlist");
    p.descriptionText = TNStr([TNDict([a objectForKey:@"description"]) objectForKey:@"standard"]) ?: TNStr([TNDict([a objectForKey:@"description"]) objectForKey:@"short"]);
    p.appleArtwork = TNStr([TNDict([a objectForKey:@"artwork"]) objectForKey:@"url"]);
    p.author = TNStr([a objectForKey:@"curatorName"]) ?: TNStr([a objectForKey:@"artistName"]);
    p.source = TNSourceApple;
    p.fromLibrary = library;
    p.modified = TNStr([a objectForKey:@"lastModifiedDate"]) ?: TNStr([a objectForKey:@"dateAdded"]);
    p.trackCount = TNInt([a objectForKey:@"trackCount"]);
    p.canEdit = library && TNBool([a objectForKey:@"canEdit"]);
    return p.playlistId.length ? p : nil;
}

// The ISRCs (and missing artwork) of library songs from the catalog, 300 at a time
- (void)fillCatalogInfo:(NSArray *)tracks storefront:(NSString *)storefront
{
    NSMutableDictionary *byCatalogId = [NSMutableDictionary dictionary];
    for (TNTrack *t in tracks) if (t.appleCatalogId.length && !t.isrc.length) TNLegacyDictionarySet(byCatalogId, t.appleCatalogId, t);
    NSArray *ids = [byCatalogId allKeys];
    for (NSUInteger i = 0; i < ids.count; i += 300) {
        NSArray *batch = [ids subarrayWithRange:NSMakeRange(i, MIN((NSUInteger)300, ids.count - i))];
        NSString *path = [NSString stringWithFormat:@"/v1/catalog/%@/songs?ids=%@", storefront, [batch componentsJoinedByString:@","]];
        NSDictionary *json = [self apiGetSync:path user:NO error:NULL];
        for (id item in TNArr([json objectForKey:@"data"]) ?: @[]) {
            NSDictionary *a = TNDict([TNDict(item) objectForKey:@"attributes"]);
            TNTrack *t = [byCatalogId objectForKey:TNStr([TNDict(item) objectForKey:@"id"]) ?: @""];
            if (!t) continue;
            t.isrc = TNStr([a objectForKey:@"isrc"]);
            if (!t.appleArtwork.length) t.appleArtwork = TNStr([TNDict([a objectForKey:@"artwork"]) objectForKey:@"url"]);
            if (!t.durationMs) t.durationMs = TNInt([a objectForKey:@"durationInMillis"]);
        }
    }
}

- (NSArray *)tracksOfPlaylistSync:(TNPlaylist *)playlist error:(NSError **)error
{
    NSString *storefront = playlist.storefront.length ? playlist.storefront : [TNSettings appleStorefront];
    NSArray *items;
    if ([playlist.playlistId hasPrefix:@"libalbum:"]) {
        items = [self allPages:[NSString stringWithFormat:@"/v1/me/library/albums/%@/tracks?limit=100", [TNUtils urlEncode:[playlist.playlistId substringFromIndex:9]]]
                          user:YES max:TNMaxPlaylistSongs error:error];
    } else if (playlist.fromLibrary) {
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
        NSString *storefront = TNStr([TNDict([TNArr([json objectForKey:@"data"]) firstObject]) objectForKey:@"id"]);
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
    for (TNPlaylist *p in [[TNLibrary shared] applePlaylists]) TNLegacyDictionarySet(old, p.playlistId, p);
    dispatch_async(_queue, ^{
        NSError *error = nil;
        NSArray *items = [self allPages:@"/v1/me/library/playlists?limit=100" user:YES max:2000 error:&error];
        NSMutableArray *playlists = [NSMutableArray array];
        for (id item in items ?: @[]) {
            TNPlaylist *p = TNPlaylistFromApple(TNDict(item), YES);
            if (!p) continue;
            p.storefront = [TNSettings appleStorefront];
            TNPlaylist *was = [old objectForKey:p.playlistId];
            if (!p.trackCount) p.trackCount = was.trackCount;
            [playlists addObject:p];
        }
        if (items) TNOnMainSync(^{ [[TNLibrary shared] setApplePlaylists:playlists]; });
        NSUInteger n = 0;
        for (TNPlaylist *p in items ? playlists : @[]) {
            n++;
            TNPlaylist *was = [old objectForKey:p.playlistId];
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
        if (items) [self syncWholeLibrary:&error];
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
    NSString *storefront = parts.count >= 3 && [[parts objectAtIndex:0] length] == 2 ? [[parts objectAtIndex:0] lowercaseString] : [TNSettings appleStorefront];
    if (parts.count >= 1 && [[parts objectAtIndex:0] length] == 2) [parts removeObjectAtIndex:0];
    NSString *type = parts.count ? [parts objectAtIndex:0] : @"";
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
        NSDictionary *item = TNDict([TNArr([json objectForKey:@"data"]) firstObject]);
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

#pragma mark - The whole library

// Every song of the library (albums and artists are made from them here), what was added lately, and the songs the
// user loves in Apple Music (they become liked songs in Muzika). Sync thread.
- (void)syncWholeLibrary:(NSError **)error
{
    NSString *storefront = [TNSettings appleStorefront];
    [self setStatus:L(@"Loading your songs…")];
    NSError *e = nil;
    NSArray *items = [self allPages:@"/v1/me/library/songs?limit=100" user:YES max:TNMaxLibrarySongs error:&e];
    if (items) {
        NSMutableArray *songs = [NSMutableArray array];
        for (id item in items) { TNTrack *t = TNTrackFromApple(TNDict(item)); if (t) [songs addObject:t]; }
        [self setStatus:[NSString stringWithFormat:L(@"Reading %lu songs…"), (unsigned long)songs.count]];
        // (the ISRCs of songs already known stay; only new ones are asked for)
        __block NSArray *old = nil;
        TNOnMainSync(^{ old = [[TNLibrary shared] appleSongs]; });
        NSMutableDictionary *known = [NSMutableDictionary dictionary];
        for (TNTrack *t in old) if (t.appleCatalogId.length && t.isrc.length) TNLegacyDictionarySet(known, t.appleCatalogId, t.isrc);
        for (TNTrack *t in songs) if (t.appleCatalogId.length && [known objectForKey:t.appleCatalogId]) t.isrc = [known objectForKey:t.appleCatalogId];
        [self fillCatalogInfo:songs storefront:storefront];
        TNOnMainSync(^{ [[TNLibrary shared] setAppleSongs:songs]; });
        TNLog(@"apple: %lu library songs", (unsigned long)songs.count);
        [self pullLovedSongs:songs];
    } else if (error && !*error) {
        *error = e;
    }
    NSArray *recent = [self allPages:@"/v1/me/library/recently-added?limit=10" user:YES max:50 error:NULL];
    if (recent) {
        NSMutableArray *out = [NSMutableArray array];
        for (id x in recent) {
            NSDictionary *item = TNDict(x);
            NSString *type = TNStr([item objectForKey:@"type"]) ?: @"";
            BOOL library = [type hasPrefix:@"library-"];
            TNPlaylist *p = TNPlaylistFromApple(item, library);
            if (!p) continue;
            p.storefront = storefront;
            if ([type hasSuffix:@"albums"]) p.playlistId = [(library ? @"libalbum:" : @"album:") stringByAppendingString:p.playlistId];
            else if (![type hasSuffix:@"playlists"]) continue;
            [out addObject:p];
        }
        TNOnMainSync(^{ [[TNLibrary shared] setAppleRecentlyAdded:out]; });
    }
}

// Apple's ratings of the library's songs, 100 at a time (a "love" is the value 1)
- (void)pullLovedSongs:(NSArray *)songs
{
    if (![TNSettings syncAppleLikes]) return;
    NSMutableDictionary *byId = [NSMutableDictionary dictionary];
    for (TNTrack *t in songs) if (t.appleCatalogId.length) TNLegacyDictionarySet(byId, t.appleCatalogId, t);
    NSArray *ids = [byId allKeys];
    if (ids.count > TNMaxRatingLookups) ids = [ids subarrayWithRange:NSMakeRange(0, TNMaxRatingLookups)];
    NSMutableArray *loved = [NSMutableArray array];
    for (NSUInteger i = 0; i < ids.count; i += 100) {
        NSArray *batch = [ids subarrayWithRange:NSMakeRange(i, MIN((NSUInteger)100, ids.count - i))];
        [self setStatus:[NSString stringWithFormat:L(@"Loved songs: %lu of %lu"), (unsigned long)i, (unsigned long)ids.count]];
        NSDictionary *json = [self apiGetSync:[@"/v1/me/ratings/songs?ids=" stringByAppendingString:[batch componentsJoinedByString:@","]] user:YES error:NULL];
        if (!json) break;
        for (id x in TNArr([json objectForKey:@"data"]) ?: @[]) {
            NSDictionary *item = TNDict(x);
            if (TNInt([TNDict([item objectForKey:@"attributes"]) objectForKey:@"value"]) != 1) continue;
            TNTrack *t = [byId objectForKey:TNStr([item objectForKey:@"id"]) ?: @""];
            if (t) [loved addObject:t];
        }
    }
    TNLog(@"apple: %lu loved songs", (unsigned long)loved.count);
    if (loved.count) TNOnMainSync(^{ [[TNLibrary shared] addLikedFromApple:loved]; });
}

#pragma mark - Finding a song in Apple's catalog

// "Get Lucky (feat. Pharrell Williams) - Radio Edit" -> "get lucky"
static NSString *TNPlainTitle(NSString *title)
{
    NSMutableString *m = [[title ?: @"" lowercaseString] mutableCopy];
    for (NSArray *pair in @[ @[ @"(", @")" ], @[ @"[", @"]" ] ]) {
        while (YES) {
            NSRange open = [m rangeOfString:[pair objectAtIndex:0]];
            if (open.location == NSNotFound || open.location == 0) break;
            NSRange close = [m rangeOfString:[pair objectAtIndex:1] options:0 range:NSMakeRange(open.location, m.length - open.location)];
            NSUInteger end = close.location == NSNotFound ? m.length : close.location + 1;
            [m deleteCharactersInRange:NSMakeRange(open.location, end - open.location)];
        }
    }
    NSRange dash = [m rangeOfString:@" - "];
    if (dash.location != NSNotFound && dash.location > 0) [m deleteCharactersInRange:NSMakeRange(dash.location, m.length - dash.location)];
    return [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

// The catalog id of any song (a YouTube Music one too): its own, by its ISRC, else a search scored by title, artist
// and length. Remembered for the run. Worker threads.
- (NSString *)catalogIdForTrackSync:(TNTrack *)track
{
    if (track.appleCatalogId.length) return track.appleCatalogId;
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *key = [track key];
    @synchronized (cache) { if ([cache objectForKey:key]) return [[cache objectForKey:key] length] ? [cache objectForKey:key] : nil; }
    NSString *storefront = [TNSettings appleStorefront];
    NSString *found = nil;
    if (track.isrc.length) {
        NSDictionary *json = [self apiGetSync:[NSString stringWithFormat:@"/v1/catalog/%@/songs?filter%%5Bisrc%%5D=%@", storefront, [TNUtils urlEncode:track.isrc]] user:NO error:NULL];
        found = TNStr([TNDict([TNArr([json objectForKey:@"data"]) firstObject]) objectForKey:@"id"]);
    }
    if (!found.length && track.name.length) {
        NSString *artist = [(TNArtist *)track.artists.firstObject name] ?: [track artistNames] ?: @"";
        NSString *term = [NSString stringWithFormat:@"%@ %@", TNPlainTitle(track.name), artist];
        NSDictionary *json = [self apiGetSync:[NSString stringWithFormat:@"/v1/catalog/%@/search?types=songs&limit=10&term=%@", storefront, [TNUtils urlEncode:term]] user:NO error:NULL];
        NSString *title = TNPlainTitle(track.name), *who = [artist lowercaseString];
        for (id x in TNArr([TNDict([TNDict([json objectForKey:@"results"]) objectForKey:@"songs"]) objectForKey:@"data"]) ?: @[]) {
            NSDictionary *a = TNDict([TNDict(x) objectForKey:@"attributes"]);
            NSString *t = TNPlainTitle(TNStr([a objectForKey:@"name"]));
            NSString *by = [TNStr([a objectForKey:@"artistName"]) lowercaseString] ?: @"";
            BOOL titleFits = t.length && ([t isEqualToString:title] || [t hasPrefix:title] || [title hasPrefix:t]);
            BOOL artistFits = !who.length || [by rangeOfString:who].location != NSNotFound || [who rangeOfString:by].location != NSNotFound;
            NSInteger ms = TNInt([a objectForKey:@"durationInMillis"]);
            BOOL lengthFits = !ms || !track.durationMs || labs((long)(ms - track.durationMs)) <= 8000;
            if (titleFits && artistFits && lengthFits) { found = TNStr([TNDict(x) objectForKey:@"id"]); break; }
        }
    }
    @synchronized (cache) { TNLegacyDictionarySet(cache, key, found ?: @""); }
    if (!found.length) TNLog(@"apple: no catalog song for %@ - %@", [track artistNames], track.name);
    return found.length ? found : nil;
}

#pragma mark - Writing to the library

- (void)sendLike:(BOOL)like track:(TNTrack *)track
{
    if (!track || ![self connected] || ![TNSettings syncAppleLikes]) return;
    dispatch_async(_queue, ^{
        NSString *catalogId = [self catalogIdForTrackSync:track];
        if (!catalogId) return;
        NSString *path = [@"/v1/me/ratings/songs/" stringByAppendingString:catalogId];
        NSError *error = nil;
        NSDictionary *answer = like ? [self apiSync:@"PUT" path:path body:@{ @"type": @"rating", @"attributes": @{ @"value": @1 } } user:YES error:&error]
                                    : [self apiSync:@"DELETE" path:path body:nil user:YES error:&error];
        TNLog(@"apple: %@ %@ %@", like ? @"love" : @"unlove", catalogId, answer ? @"ok" : error.localizedDescription);
    });
}

// What Apple takes as a playlist's songs: a library song by its library id, any other by its catalog id
- (NSArray *)resourcesFor:(NSArray *)tracks
{
    NSMutableArray *data = [NSMutableArray array];
    for (TNTrack *t in tracks) {
        if ([t.appleId hasPrefix:@"i."]) { [data addObject:@{ @"id": t.appleId, @"type": @"library-songs" }]; continue; }
        NSString *catalogId = [self catalogIdForTrackSync:t];
        if (catalogId) [data addObject:@{ @"id": catalogId, @"type": @"songs" }];
    }
    return data;
}

- (void)addTracks:(NSArray *)tracks toPlaylist:(TNPlaylist *)playlist completion:(void (^)(NSUInteger, NSError *))completion
{
    dispatch_async(_queue, ^{
        NSArray *data = [self resourcesFor:tracks];
        NSError *error = nil;
        BOOL ok = NO;
        if (data.count) {
            NSString *path = [NSString stringWithFormat:@"/v1/me/library/playlists/%@/tracks", [TNUtils urlEncode:playlist.playlistId]];
            ok = [self apiSync:@"POST" path:path body:@{ @"data": data } user:YES error:&error] != nil;
        } else {
            error = TNMakeError(TNErrorAPI, L(@"Apple Music does not have this song."));
        }
        // the playlist as Apple has it now
        NSArray *fresh = ok ? [self tracksOfPlaylistSync:playlist error:NULL] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (fresh) {
                playlist.trackCount = (NSInteger)fresh.count;
                [[TNLibrary shared] setTracks:fresh ofPlaylist:playlist];
            }
            completion(ok ? data.count : 0, ok ? nil : error);
        });
    });
}

- (void)createPlaylistNamed:(NSString *)name tracks:(NSArray *)tracks completion:(void (^)(TNPlaylist *, NSError *))completion
{
    dispatch_async(_queue, ^{
        NSArray *data = [self resourcesFor:tracks];
        NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{ @"attributes": @{ @"name": name ?: L(@"New playlist"), @"description": L(@"Made in Muzika") } }];
        if (data.count) TNLegacyDictionarySet(body, @"relationships", @{ @"tracks": @{ @"data": data } });
        NSError *error = nil;
        NSDictionary *json = [self apiSync:@"POST" path:@"/v1/me/library/playlists" body:body user:YES error:&error];
        TNPlaylist *playlist = TNPlaylistFromApple(TNDict([TNArr([json objectForKey:@"data"]) firstObject]), YES);
        if (playlist) {
            playlist.canEdit = YES;
            playlist.storefront = [TNSettings appleStorefront];
            playlist.trackCount = (NSInteger)data.count;
        } else if (!error) {
            error = TNMakeError(TNErrorAPI, L(@"Apple Music did not make the playlist."));
        }
        NSArray *fresh = playlist && data.count ? [self tracksOfPlaylistSync:playlist error:NULL] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (playlist) {
                TNLibrary *library = [TNLibrary shared];
                [library setApplePlaylists:[@[ playlist ] arrayByAddingObjectsFromArray:[library applePlaylists]]];
                [library setTracks:fresh ?: @[] ofPlaylist:playlist];
            }
            completion(playlist, error);
        });
    });
}

- (NSArray *)editablePlaylists
{
    NSMutableArray *out = [NSMutableArray array];
    for (TNPlaylist *p in [[TNLibrary shared] applePlaylists]) if (p.canEdit) [out addObject:p];
    return out;
}

#pragma mark - Charts

- (TNHTTPTask *)chartsWithCompletion:(void (^)(NSArray *, NSError *))completion
{
    TNHTTPTask *task = [[TNHTTPTask alloc] init];
    NSString *storefront = [TNSettings appleStorefront];
    dispatch_async(_queue, ^{
        NSError *error = nil;
        NSString *path = [NSString stringWithFormat:@"/v1/catalog/%@/charts?types=songs,albums,playlists&limit=50&with=dailyGlobalTopCharts,cityCharts", storefront];
        NSDictionary *json = [self apiGetSync:path user:NO error:&error];
        NSDictionary *results = TNDict([json objectForKey:@"results"]);
        NSMutableArray *shelves = [NSMutableArray array];
        for (NSString *kind in @[ @"songs", @"dailyGlobalTopCharts", @"playlists", @"albums", @"cityCharts" ]) {
            for (id x in TNArr([results objectForKey:kind]) ?: @[]) {
                NSDictionary *chart = TNDict(x);
                NSMutableArray *items = [NSMutableArray array];
                BOOL songs = NO;
                for (id y in TNArr([chart objectForKey:@"data"]) ?: @[]) {
                    NSDictionary *item = TNDict(y);
                    NSString *type = TNStr([item objectForKey:@"type"]) ?: @"";
                    if ([type isEqualToString:@"songs"]) {
                        TNTrack *t = TNTrackFromApple(item);
                        if (t) { [items addObject:t]; songs = YES; }
                    } else if ([type isEqualToString:@"albums"] || [type isEqualToString:@"playlists"]) {
                        TNPlaylist *p = TNPlaylistFromApple(item, NO);
                        if (!p) continue;
                        p.storefront = storefront;
                        if ([type isEqualToString:@"albums"]) p.playlistId = [@"album:" stringByAppendingString:p.playlistId];
                        [items addObject:p];
                    }
                }
                if (!items.count) continue;
                TNShelf *shelf = [[TNShelf alloc] init];
                shelf.title = TNStr([chart objectForKey:@"name"]) ?: L(@"Charts");
                shelf.items = items;
                shelf.songs = songs;
                [shelves addObject:shelf];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task.isCancelled) return;
            completion(shelves, shelves.count ? nil : error);
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
