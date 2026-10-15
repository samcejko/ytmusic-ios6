#import "TNImport.h"
#import "TNAppleMusic.h"
#import "TNYTMusic.h"
#import "TNMatcher.h"
#import "TNLibrary.h"
#import "TNModels.h"
#import "TNHTTP.h"
#import "TNUtils.h"
#import "TNCommon.h"

static const NSUInteger TNMaxImportedSongs = 3000;
static NSString * const TNBrowserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

@implementation TNImport

+ (BOOL)isSpotifyLink:(NSString *)text
{
    return [text rangeOfString:@"open.spotify.com/"].location != NSNotFound || [text hasPrefix:@"spotify:"];
}

static NSString *TNListParam(NSString *url)
{
    NSRange q = [url rangeOfString:@"?"];
    if (q.location == NSNotFound) return nil;
    return [TNUtils parseQuery:[url substringFromIndex:q.location + 1]][@"list"];
}

+ (BOOL)isYouTubePlaylistLink:(NSString *)text
{
    NSString *lower = [text lowercaseString];
    BOOL youtube = [lower rangeOfString:@"youtube.com/"].location != NSNotFound || [lower rangeOfString:@"youtu.be/"].location != NSNotFound;
    return youtube && TNListParam(text).length > 0;
}

+ (BOOL)canImport:(NSString *)text
{
    return [TNAppleMusic isAppleMusicLink:text] || [self isSpotifyLink:text] || [self isYouTubePlaylistLink:text];
}

+ (void)importLink:(NSString *)link completion:(void (^)(TNPlaylist *, NSError *))completion
{
    NSString *s = [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([TNAppleMusic isAppleMusicLink:s]) {
        [[TNAppleMusic shared] importLink:s completion:^(TNPlaylist *playlist, NSArray *tracks, NSError *error) {
            if (playlist) [[TNLibrary shared] setSaved:YES playlist:playlist];
            completion(playlist, playlist ? nil : error ?: TNMakeError(TNErrorAPI, L(@"The link could not be imported.")));
        }];
    } else if ([self isSpotifyLink:s]) {
        [self importSpotify:s completion:completion];
    } else if ([self isYouTubePlaylistLink:s]) {
        [self importYouTube:TNListParam(s) completion:completion];
    } else {
        completion(nil, TNMakeError(TNErrorAPI, L(@"Muzika can import links of Apple Music, Spotify and YouTube playlists.")));
    }
}

#pragma mark - Spotify

// open.spotify.com/playlist/<id>?si=..., /album/<id>, /track/<id> (also /intl-cs/...), spotify:playlist:<id>
+ (NSString *)embedURLFor:(NSString *)link
{
    NSString *path = link;
    if ([link hasPrefix:@"spotify:"]) path = [[link substringFromIndex:8] stringByReplacingOccurrencesOfString:@":" withString:@"/"];
    else {
        NSRange host = [link rangeOfString:@"open.spotify.com/"];
        path = [[[link substringFromIndex:host.location + host.length] componentsSeparatedByString:@"?"] firstObject];
    }
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        NSString *type = parts[i];
        if ([type isEqualToString:@"playlist"] || [type isEqualToString:@"album"] || [type isEqualToString:@"track"]) {
            NSString *identifier = [[parts[i + 1] componentsSeparatedByString:@"#"] firstObject];
            if (identifier.length) return [NSString stringWithFormat:@"https://open.spotify.com/embed/%@/%@", type, identifier];
        }
    }
    return nil;
}

static TNTrack *TNTrackFromSpotify(NSDictionary *d)
{
    NSString *title = TNStr(d[@"title"]) ?: TNStr(d[@"name"]);
    if (!title.length) return nil;
    TNTrack *t = [[TNTrack alloc] init];
    t.name = title;
    NSString *by = [TNStr(d[@"subtitle"]) ?: @"" stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%C", (unichar)0xa0] withString:@" "];
    t.byline = by;
    NSMutableArray *artists = [NSMutableArray array];
    for (NSString *name in [by componentsSeparatedByString:@", "]) {
        if (!name.length) continue;
        TNArtist *a = [[TNArtist alloc] init];
        a.name = name;
        [artists addObject:a];
    }
    t.artists = artists;
    t.durationMs = TNInt(d[@"duration"]);
    t.explicitContent = TNBool(d[@"isExplicit"]);
    NSString *uri = TNStr(d[@"uri"]) ?: @"";
    t.spotifyId = [[uri componentsSeparatedByString:@":"] lastObject];
    if (!t.spotifyId.length) t.spotifyId = [NSString stringWithFormat:@"%@|%@", title, by];
    return t;
}

+ (void)importSpotify:(NSString *)link completion:(void (^)(TNPlaylist *, NSError *))completion
{
    NSString *embed = [self embedURLFor:link];
    if (!embed) { completion(nil, TNMakeError(TNErrorAPI, L(@"This is no link to a Spotify playlist, album or song."))); return; }
    [TNHTTP get:embed headers:@{ @"User-Agent": TNBrowserAgent, @"Accept-Language": @"en" } completion:^(NSInteger status, NSData *body, NSDictionary *headers, NSError *error) {
        NSString *html = body ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil;
        NSRange start = [html ?: @"" rangeOfString:@"<script id=\"__NEXT_DATA__\" type=\"application/json\">"];
        NSDictionary *entity = nil;
        if (start.location != NSNotFound) {
            NSUInteger from = start.location + start.length;
            NSRange end = [html rangeOfString:@"</script>" options:0 range:NSMakeRange(from, html.length - from)];
            if (end.location != NSNotFound) {
                NSData *json = [[html substringWithRange:NSMakeRange(from, end.location - from)] dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *root = TNDict([TNUtils JSONObjectFromData:json]);
                entity = TNDict(TNDict(TNDict(TNDict(TNDict(root[@"props"])[@"pageProps"])[@"state"])[@"data"])[@"entity"]);
            }
        }
        NSMutableArray *tracks = [NSMutableArray array];
        for (id x in TNArr(entity[@"trackList"]) ?: @[]) { TNTrack *t = TNTrackFromSpotify(TNDict(x)); if (t) [tracks addObject:t]; }
        if (!tracks.count && [TNStr(entity[@"type"]) isEqualToString:@"track"]) {
            TNTrack *t = TNTrackFromSpotify(@{ @"title": TNStr(entity[@"name"]) ?: @"", @"uri": TNStr(entity[@"uri"]) ?: @"", @"duration": entity[@"duration"] ?: @0,
                                               @"subtitle": [TNArr([TNArr(entity[@"artists"]) valueForKey:@"name"]) componentsJoinedByString:@", "] ?: @"" });
            if (t) [tracks addObject:t];
        }
        if (!tracks.count) {
            TNLog(@"import: spotify %@ -> %ld, %lu bytes, no songs", embed, (long)status, (unsigned long)body.length);
            completion(nil, error ?: TNMakeError(TNErrorAPI, L(@"Spotify shows no songs for this link (a private playlist cannot be imported).")));
            return;
        }
        NSMutableArray *thumbs = [NSMutableArray array];
        NSArray *sources = TNArr(TNDict(entity[@"coverArt"])[@"sources"]) ?: TNArr(TNDict(entity[@"visualIdentity"])[@"image"]) ?: @[];
        for (id x in sources) {
            NSDictionary *d = TNDict(x);
            if (TNStr(d[@"url"]).length) [thumbs addObject:@{ @"url": d[@"url"], @"width": d[@"width"] ?: @300, @"height": d[@"height"] ?: @300 }];
        }
        TNPlaylist *p = [[TNLibrary shared] createPlaylistNamed:TNStr(entity[@"name"]) ?: TNStr(entity[@"title"]) ?: L(@"Spotify playlist") tracks:tracks];
        p.author = [NSString stringWithFormat:L(@"From Spotify%@"), TNStr(entity[@"subtitle"]).length ? [@" • " stringByAppendingString:entity[@"subtitle"]] : @""];
        if (thumbs.count) { p.thumbnails = thumbs; p.coverIsOwn = YES; }
        [[TNLibrary shared] renamePlaylist:p to:p.name];   // (saves the author and cover too)
        [[TNMatcher shared] matchTracks:tracks];
        TNLog(@"import: spotify %@ -> %lu songs", p.name, (unsigned long)tracks.count);
        completion(p, nil);
    }];
}

#pragma mark - YouTube

+ (void)importYouTube:(NSString *)list completion:(void (^)(TNPlaylist *, NSError *))completion
{
    NSString *browseId = [list hasPrefix:@"VL"] ? list : [@"VL" stringByAppendingString:list];
    [TNYTMusic playlist:browseId completion:^(TNPlaylist *playlist, NSArray *tracks, NSString *continuation, NSError *error) {
        if (!tracks.count) { completion(nil, error ?: TNMakeError(TNErrorAPI, L(@"This playlist is empty."))); return; }
        [self collectFrom:continuation into:[tracks mutableCopy] done:^(NSArray *all) {
            TNPlaylist *p = [[TNLibrary shared] createPlaylistNamed:playlist.name ?: L(@"YouTube playlist") tracks:all];
            p.author = playlist.author.length ? [NSString stringWithFormat:L(@"From YouTube • %@"), playlist.author] : L(@"From YouTube");
            p.descriptionText = playlist.descriptionText;
            if (playlist.thumbnails.count) { p.thumbnails = playlist.thumbnails; p.coverIsOwn = YES; }
            [[TNLibrary shared] renamePlaylist:p to:p.name];
            TNLog(@"import: youtube %@ -> %lu songs", p.name, (unsigned long)all.count);
            completion(p, nil);
        }];
    }];
}

+ (void)collectFrom:(NSString *)continuation into:(NSMutableArray *)tracks done:(void (^)(NSArray *))done
{
    if (!continuation.length || tracks.count >= TNMaxImportedSongs) { done(tracks); return; }
    [TNYTMusic playlistMore:continuation completion:^(NSArray *more, NSString *next, NSError *error) {
        [tracks addObjectsFromArray:more ?: @[]];
        [self collectFrom:more.count ? next : nil into:tracks done:done];
    }];
}

@end
