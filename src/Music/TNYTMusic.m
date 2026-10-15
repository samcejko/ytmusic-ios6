#import "TNYTMusic.h"
#import "TNHTTPRequest.h"
#import "TNSettings.h"
#import "TNUtils.h"
#import "TNCommon.h"

static NSString * const TNYTMBase = @"https://music.youtube.com/youtubei/v1/";
static NSString * const TNYTMVersion = @"1.20250310.01.00";
static NSString * const TNYTMUserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

// The "params" of a filtered search (from the chips of music.youtube.com, 2026-10)
static NSString *TNFilterParams(TNSearchFilter filter)
{
    switch (filter) {
        case TNSearchSongs: return @"EgWKAQIIAWoSEAUQCRADEAQQChAQEA4QFRAR";
        case TNSearchVideos: return @"EgWKAQIQAWoSEAUQCRADEAQQChAQEA4QFRAR";
        case TNSearchAlbums: return @"EgWKAQIYAWoSEAUQCRADEAQQChAQEA4QFRAR";
        case TNSearchArtists: return @"EgWKAQIgAWoSEAUQCRADEAQQChAQEA4QFRAR";
        case TNSearchPlaylists: return @"EgeKAQQoAEABahIQBRAJEAMQBBAKEBAQDhAVEBE=";
        default: return nil;
    }
}

#pragma mark - Reading the JSON

static id TNAt(id node, NSString *path)
{
    for (NSString *part in [path componentsSeparatedByString:@"."]) {
        if (!node) return nil;
        unichar c = part.length ? [part characterAtIndex:0] : 0;
        if (c >= '0' && c <= '9') {
            NSArray *a = TNArr(node);
            NSUInteger i = (NSUInteger)[part integerValue];
            node = i < a.count ? a[i] : nil;
        } else {
            node = TNDict(node)[part];
        }
    }
    return node;
}

static NSArray *TNRunsOf(id text)
{
    NSArray *runs = TNArr(TNDict(text)[@"runs"]);
    if (runs) return runs;
    NSString *simple = TNStr(TNDict(text)[@"simpleText"]);
    return simple ? @[ @{ @"text": simple } ] : @[];
}

static NSString *TNText(id text)
{
    NSMutableString *s = [NSMutableString string];
    for (id r in TNRunsOf(text)) [s appendString:TNStr(TNDict(r)[@"text"]) ?: @""];
    return s.length ? s : nil;
}

static NSString *TNPageType(NSDictionary *browse)
{
    return TNStr(TNAt(browse, @"browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType"));
}

static NSString *TNMusicVideoType(NSDictionary *watch)
{
    return TNStr(TNAt(watch, @"watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig.musicVideoType"));
}

static NSArray *TNThumbsOf(NSDictionary *r)
{
    for (NSString *path in @[ @"thumbnail.musicThumbnailRenderer.thumbnail.thumbnails", @"thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails",
                              @"thumbnail.croppedSquareThumbnailRenderer.thumbnail.thumbnails", @"thumbnail.thumbnails",
                              @"foregroundThumbnail.musicThumbnailRenderer.thumbnail.thumbnails" ]) {
        NSArray *t = TNArr(TNAt(r, path));
        if (t.count) return t;
    }
    return nil;
}

static BOOL TNHasExplicitBadge(NSDictionary *r)
{
    for (NSString *key in @[ @"badges", @"subtitleBadges", @"subtitleBadge" ]) {
        for (id b in TNArr(r[key]) ?: @[]) {
            NSString *icon = TNStr(TNAt(b, @"musicInlineBadgeRenderer.icon.iconType"));
            if ([icon isEqualToString:@"MUSIC_EXPLICIT_BADGE"]) return YES;
        }
    }
    return NO;
}

// The words YouTube Music puts in front of a result (English and Czech, as the app asks in either)
static BOOL TNIsTypeWord(NSString *s)
{
    static NSSet *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = [NSSet setWithArray:@[ @"song", @"video", @"album", @"single", @"ep", @"artist", @"playlist", @"episode", @"podcast",
                                       @"profile", @"station", @"skladba", @"singl", @"interpret", @"interpretka", @"epizoda", @"profil",
                                       @"stanice", @"umělec", @"umělkyně", @"pořad", @"audiokniha", @"audiobook" ]];
    });
    return [words containsObject:[[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString]];
}

static BOOL TNIsYear(NSString *s)
{
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return t.length == 4 && [t rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
}

// The " • " separated parts of a line of runs
static NSArray *TNSegments(NSArray *runs)
{
    NSMutableString *all = [NSMutableString string];
    for (id r in runs) [all appendString:TNStr(TNDict(r)[@"text"]) ?: @""];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in [all componentsSeparatedByString:@" • "]) {
        NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [out addObject:t];
    }
    return out;
}

static NSInteger TNCountIn(NSString *s)
{
    // "35 songs", "34 skladeb" -> 35
    NSScanner *scanner = [NSScanner scannerWithString:s ?: @""];
    NSInteger n = 0;
    if ([scanner scanInteger:&n] && scanner.scanLocation == [s rangeOfString:@" "].location) return n;
    return 0;
}

static TNArtist *TNArtistFromRun(NSDictionary *run)
{
    NSDictionary *browse = TNDict(TNAt(run, @"navigationEndpoint.browseEndpoint"));
    NSString *type = TNPageType(browse);
    if (!browse || !([type isEqualToString:@"MUSIC_PAGE_TYPE_ARTIST"] || [type isEqualToString:@"MUSIC_PAGE_TYPE_USER_CHANNEL"])) return nil;
    TNArtist *a = [[TNArtist alloc] init];
    a.browseId = TNStr(browse[@"browseId"]);
    a.name = TNStr(run[@"text"]);
    return a.name.length ? a : nil;
}

static TNAlbum *TNAlbumFromRun(NSDictionary *run)
{
    NSDictionary *browse = TNDict(TNAt(run, @"navigationEndpoint.browseEndpoint"));
    if (![TNPageType(browse) isEqualToString:@"MUSIC_PAGE_TYPE_ALBUM"]) return nil;
    TNAlbum *a = [[TNAlbum alloc] init];
    a.browseId = TNStr(browse[@"browseId"]);
    a.name = TNStr(run[@"text"]);
    return a.name.length ? a : nil;
}

// Artists, album, duration, year and the artists' line out of the runs of a song's second (and further) columns
static void TNFillTrackFromRuns(TNTrack *t, NSArray *runs)
{
    NSMutableArray *artists = [NSMutableArray arrayWithArray:t.artists ?: @[]];
    NSInteger firstArtist = -1, lastArtist = -1;
    for (NSUInteger i = 0; i < runs.count; i++) {
        NSDictionary *run = TNDict(runs[i]);
        TNArtist *artist = TNArtistFromRun(run);
        if (artist) {
            [artists addObject:artist];
            if (firstArtist < 0) firstArtist = (NSInteger)i;
            lastArtist = (NSInteger)i;
            continue;
        }
        TNAlbum *album = TNAlbumFromRun(run);
        if (album) { if (!t.album) t.album = album; continue; }
        NSString *text = TNStr(run[@"text"]);
        NSInteger ms = TNParseDurationMs(text);
        if (ms && !t.durationMs) t.durationMs = ms;
    }
    t.artists = artists;
    if (firstArtist >= 0 && !t.byline.length) {
        NSMutableString *by = [NSMutableString string];
        for (NSInteger i = firstArtist; i <= lastArtist; i++) [by appendString:TNStr(TNDict(runs[(NSUInteger)i])[@"text"]) ?: @""];
        t.byline = by;
    }
    for (NSString *seg in TNSegments(runs)) {
        if (TNIsYear(seg)) { if (t.album && !t.album.year) t.album.year = seg; continue; }
        if (TNParseDurationMs(seg) || TNIsTypeWord(seg)) continue;
        unichar c = [seg characterAtIndex:0];
        if (c >= '0' && c <= '9') { if (!t.plays.length) t.plays = seg; continue; }
        if (!t.byline.length && !artists.count) t.byline = seg;
    }
}

static NSString *TNVideoTypeOf(NSDictionary *nav)
{
    return TNMusicVideoType(TNDict(nav[@"watchEndpoint"]));
}

#pragma mark - Items

static id TNItemFromListItem(NSDictionary *r)
{
    NSArray *columns = TNArr(r[@"flexColumns"]) ?: @[];
    NSMutableArray *columnRuns = [NSMutableArray array];
    for (id c in columns) [columnRuns addObject:TNRunsOf(TNAt(c, @"musicResponsiveListItemFlexColumnRenderer.text"))];
    NSArray *runs0 = columnRuns.count ? columnRuns[0] : @[];
    NSString *title = TNText(TNAt(columns.firstObject, @"musicResponsiveListItemFlexColumnRenderer.text"));
    if (!title.length) return nil;
    NSDictionary *nav0 = TNDict(TNDict(runs0.firstObject)[@"navigationEndpoint"]);
    NSDictionary *browse = TNDict(TNAt(r, @"navigationEndpoint.browseEndpoint"));
    NSDictionary *play = TNDict(TNAt(r, @"overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint"));
    NSArray *line = columnRuns.count > 1 ? columnRuns[1] : @[];
    NSArray *segments = TNSegments(line);
    NSArray *thumbs = TNThumbsOf(r);

    NSString *pageType = TNPageType(browse);
    if (browse && pageType) {
        NSString *browseId = TNStr(browse[@"browseId"]);
        if ([pageType isEqualToString:@"MUSIC_PAGE_TYPE_ALBUM"]) {
            TNAlbum *a = [[TNAlbum alloc] init];
            a.browseId = browseId;
            a.name = title;
            a.thumbnails = thumbs;
            a.playlistId = TNStr(TNAt(play, @"watchPlaylistEndpoint.playlistId"));
            NSMutableArray *artists = [NSMutableArray array];
            for (id run in line) { TNArtist *x = TNArtistFromRun(TNDict(run)); if (x) [artists addObject:x]; }
            for (NSString *seg in segments) {
                if (TNIsYear(seg)) a.year = seg;
                else if (TNIsTypeWord(seg) && !a.kind) a.kind = seg;
                else if (!artists.count && seg.length) {
                    TNArtist *x = [[TNArtist alloc] init];
                    x.name = seg;
                    [artists addObject:x];
                }
            }
            a.artists = artists;
            return a;
        }
        if ([pageType isEqualToString:@"MUSIC_PAGE_TYPE_ARTIST"]) {
            TNArtist *a = [[TNArtist alloc] init];
            a.browseId = browseId;
            a.name = title;
            a.thumbnails = thumbs;
            NSMutableArray *rest = [NSMutableArray array];
            for (NSString *seg in segments) if (!TNIsTypeWord(seg)) [rest addObject:seg];
            a.subtitle = [rest componentsJoinedByString:@" • "];
            return a;
        }
        if ([pageType isEqualToString:@"MUSIC_PAGE_TYPE_PLAYLIST"]) {
            TNPlaylist *p = [[TNPlaylist alloc] init];
            p.browseId = browseId;
            p.playlistId = [TNYTMusic playlistIdFromBrowseId:browseId];
            p.name = title;
            p.thumbnails = thumbs;
            p.source = TNSourceYouTube;
            for (NSString *seg in segments) {
                if (TNIsTypeWord(seg)) continue;
                NSInteger n = TNCountIn(seg);
                if (n) { p.trackCount = n; continue; }
                unichar c = [seg characterAtIndex:0];
                if (c >= '0' && c <= '9') continue;   // ("9.2K views")
                if (!p.author.length) p.author = seg;
            }
            return p;
        }
        return nil;   // (podcasts, profiles)
    }

    NSString *videoId = TNStr(TNAt(r, @"playlistItemData.videoId")) ?: TNStr(TNAt(nav0, @"watchEndpoint.videoId")) ?: TNStr(TNAt(play, @"watchEndpoint.videoId"));
    if (!videoId.length) return nil;
    NSString *videoType = TNVideoTypeOf(nav0) ?: TNVideoTypeOf(play);
    if ([videoType isEqualToString:@"MUSIC_VIDEO_TYPE_PODCAST_EPISODE"]) return nil;
    TNTrack *t = [[TNTrack alloc] init];
    t.videoId = videoId;
    t.name = title;
    t.thumbnails = thumbs;
    t.explicitContent = TNHasExplicitBadge(r);
    t.isVideo = videoType.length && ![videoType isEqualToString:@"MUSIC_VIDEO_TYPE_ATV"];
    t.setVideoId = TNStr(TNAt(r, @"playlistItemData.playlistSetVideoId"));
    t.trackNumber = [TNText(r[@"index"]) integerValue];
    for (NSUInteger i = 1; i < columnRuns.count; i++) TNFillTrackFromRuns(t, columnRuns[i]);
    for (id c in TNArr(r[@"fixedColumns"]) ?: @[]) {
        NSInteger ms = TNParseDurationMs(TNText(TNAt(c, @"musicResponsiveListItemFixedColumnRenderer.text")));
        if (ms) t.durationMs = ms;
    }
    return t;
}

static id TNItemFromTwoRow(NSDictionary *r)
{
    NSString *title = TNText(r[@"title"]);
    if (!title.length) return nil;
    NSDictionary *nav = TNDict(r[@"navigationEndpoint"]);
    NSDictionary *browse = TNDict(nav[@"browseEndpoint"]);
    NSArray *subRuns = TNRunsOf(r[@"subtitle"]);
    NSArray *segments = TNSegments(subRuns);
    NSArray *thumbs = TNThumbsOf(r);
    NSString *pageType = TNPageType(browse);
    NSString *browseId = TNStr(browse[@"browseId"]);
    if ([pageType isEqualToString:@"MUSIC_PAGE_TYPE_ALBUM"]) {
        TNAlbum *a = [[TNAlbum alloc] init];
        a.browseId = browseId;
        a.name = title;
        a.thumbnails = thumbs;
        a.playlistId = TNStr(TNAt(r, @"thumbnailOverlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchPlaylistEndpoint.playlistId"));
        NSMutableArray *artists = [NSMutableArray array];
        for (id run in subRuns) { TNArtist *x = TNArtistFromRun(TNDict(run)); if (x) [artists addObject:x]; }
        for (NSString *seg in segments) {
            if (TNIsYear(seg)) a.year = seg;
            else if (TNIsTypeWord(seg) && !a.kind) a.kind = seg;
            else if (!artists.count) { TNArtist *x = [[TNArtist alloc] init]; x.name = seg; [artists addObject:x]; }
        }
        a.artists = artists;
        return a;
    }
    if ([pageType isEqualToString:@"MUSIC_PAGE_TYPE_ARTIST"] || [pageType isEqualToString:@"MUSIC_PAGE_TYPE_USER_CHANNEL"]) {
        TNArtist *a = [[TNArtist alloc] init];
        a.browseId = browseId;
        a.name = title;
        a.thumbnails = thumbs;
        a.subtitle = TNText(r[@"subtitle"]);
        return a;
    }
    if ([pageType isEqualToString:@"MUSIC_PAGE_TYPE_PLAYLIST"]) {
        TNPlaylist *p = [[TNPlaylist alloc] init];
        p.browseId = browseId;
        p.playlistId = [TNYTMusic playlistIdFromBrowseId:browseId];
        p.name = title;
        p.thumbnails = thumbs;
        p.source = TNSourceYouTube;
        NSMutableArray *rest = [NSMutableArray array];
        for (NSString *seg in segments) {
            if (TNIsTypeWord(seg)) continue;
            NSInteger n = TNCountIn(seg);
            if (n) { p.trackCount = n; continue; }
            [rest addObject:seg];
        }
        p.author = rest.firstObject;
        p.descriptionText = [rest componentsJoinedByString:@" • "];
        return p;
    }
    NSDictionary *watch = TNDict(nav[@"watchEndpoint"]);
    NSString *videoId = TNStr(watch[@"videoId"]);
    if (!videoId.length) return nil;
    NSString *videoType = TNMusicVideoType(watch);
    if ([videoType isEqualToString:@"MUSIC_VIDEO_TYPE_PODCAST_EPISODE"]) return nil;
    TNTrack *t = [[TNTrack alloc] init];
    t.videoId = videoId;
    t.name = title;
    t.thumbnails = thumbs;
    t.explicitContent = TNHasExplicitBadge(r);
    t.isVideo = videoType.length && ![videoType isEqualToString:@"MUSIC_VIDEO_TYPE_ATV"];
    TNFillTrackFromRuns(t, subRuns);
    return t;
}

static TNCategory *TNCategoryFromButton(NSDictionary *r)
{
    NSDictionary *browse = TNDict(TNAt(r, @"clickCommand.browseEndpoint"));
    NSString *title = TNText(r[@"buttonText"]);
    if (!title.length || !TNStr(browse[@"browseId"]).length) return nil;
    TNCategory *c = [[TNCategory alloc] init];
    c.title = title;
    c.browseId = TNStr(browse[@"browseId"]);
    c.params = TNStr(browse[@"params"]);
    long long argb = [TNStr(TNAt(r, @"solid.leftStripeColor")) longLongValue];
    if (argb) c.colorHex = [NSString stringWithFormat:@"#%06llX", argb & 0xFFFFFF];
    return c;
}

static TNTrack *TNTrackFromPanelVideo(NSDictionary *r)
{
    NSString *videoId = TNStr(r[@"videoId"]) ?: TNStr(TNAt(r, @"navigationEndpoint.watchEndpoint.videoId"));
    NSString *title = TNText(r[@"title"]);
    if (!videoId.length || !title.length) return nil;
    TNTrack *t = [[TNTrack alloc] init];
    t.videoId = videoId;
    t.name = title;
    t.thumbnails = TNThumbsOf(r);
    t.durationMs = TNParseDurationMs(TNText(r[@"lengthText"]));
    NSString *videoType = TNMusicVideoType(TNDict(TNAt(r, @"navigationEndpoint.watchEndpoint")));
    t.isVideo = videoType.length && ![videoType isEqualToString:@"MUSIC_VIDEO_TYPE_ATV"];
    t.explicitContent = TNHasExplicitBadge(r);
    t.setVideoId = TNStr(r[@"playlistSetVideoId"]);
    TNFillTrackFromRuns(t, TNRunsOf(r[@"longBylineText"]));
    if (!t.byline.length) t.byline = TNText(r[@"shortBylineText"]);
    return t;
}

static id TNItemFrom(NSDictionary *wrapper)
{
    NSDictionary *r;
    if ((r = TNDict(wrapper[@"musicResponsiveListItemRenderer"]))) return TNItemFromListItem(r);
    if ((r = TNDict(wrapper[@"musicTwoRowItemRenderer"]))) return TNItemFromTwoRow(r);
    if ((r = TNDict(wrapper[@"musicNavigationButtonRenderer"]))) return TNCategoryFromButton(r);
    if ((r = TNDict(wrapper[@"playlistPanelVideoRenderer"]))) return TNTrackFromPanelVideo(r);
    if ((r = TNDict(TNAt(wrapper, @"playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer")))) return TNTrackFromPanelVideo(r);
    return nil;
}

static NSArray *TNItemsFrom(NSArray *contents)
{
    NSMutableArray *items = [NSMutableArray array];
    for (id c in contents ?: @[]) {
        id item = TNItemFrom(TNDict(c));
        if (item) [items addObject:item];
    }
    return items;
}

static NSString *TNContinuationIn(NSArray *contents, NSDictionary *renderer)
{
    // the newer kind: a last item carrying the token; the older: "continuations" of the renderer
    NSString *token = TNStr(TNAt([contents lastObject], @"continuationItemRenderer.continuationEndpoint.continuationCommand.token"));
    if (token.length) return token;
    for (id c in TNArr(renderer[@"continuations"]) ?: @[]) {
        token = TNStr(TNAt(c, @"nextContinuationData.continuation")) ?: TNStr(TNAt(c, @"nextRadioContinuationData.continuation"));
        if (token.length) return token;
    }
    return nil;
}

#pragma mark - Shelves

static BOOL TNAllTracks(NSArray *items)
{
    if (!items.count) return NO;
    for (id i in items) if (![i isKindOfClass:[TNTrack class]]) return NO;
    return YES;
}

// The top result of a search: a card with its own title, picture and link
static id TNTopResultFromCard(NSDictionary *r)
{
    NSDictionary *titleRun = TNDict([TNRunsOf(r[@"title"]) firstObject]);
    NSString *title = TNStr(titleRun[@"text"]);
    if (!title.length) return nil;
    NSDictionary *nav = TNDict(titleRun[@"navigationEndpoint"]) ?: TNDict(TNAt(r, @"onTap"));
    NSMutableDictionary *fake = [NSMutableDictionary dictionary];
    fake[@"title"] = @{ @"runs": @[ @{ @"text": title } ] };
    if (r[@"subtitle"]) fake[@"subtitle"] = r[@"subtitle"];
    if (nav) fake[@"navigationEndpoint"] = nav;
    NSArray *thumbs = TNThumbsOf(r);
    if (thumbs) fake[@"thumbnail"] = @{ @"thumbnails": thumbs };
    return TNItemFromTwoRow(fake);
}

static TNShelf *TNShelfFrom(NSDictionary *section)
{
    NSDictionary *r;
    TNShelf *shelf = [[TNShelf alloc] init];
    if ((r = TNDict(section[@"musicCarouselShelfRenderer"])) || (r = TNDict(section[@"musicImmersiveCarouselShelfRenderer"]))) {
        NSDictionary *header = TNDict(TNAt(r, @"header.musicCarouselShelfBasicHeaderRenderer")) ?: TNDict(TNAt(r, @"header.musicImmersiveCarouselShelfBasicHeaderRenderer"));
        shelf.title = TNText(header[@"title"]);
        shelf.strapline = TNText(header[@"strapline"]);
        NSDictionary *more = TNDict(TNAt(header, @"moreContentButton.buttonRenderer.navigationEndpoint.browseEndpoint")) ?:
                             TNDict(TNAt([TNRunsOf(header[@"title"]) firstObject], @"navigationEndpoint.browseEndpoint"));
        shelf.moreBrowseId = TNStr(more[@"browseId"]);
        shelf.moreParams = TNStr(more[@"params"]);
        shelf.items = TNItemsFrom(TNArr(r[@"contents"]));
    } else if ((r = TNDict(section[@"musicShelfRenderer"])) || (r = TNDict(section[@"musicPlaylistShelfRenderer"]))) {
        shelf.title = TNText(r[@"title"]);
        NSDictionary *more = TNDict(TNAt(r, @"bottomEndpoint.browseEndpoint")) ?: TNDict(TNAt([TNRunsOf(r[@"title"]) firstObject], @"navigationEndpoint.browseEndpoint"));
        shelf.moreBrowseId = TNStr(more[@"browseId"]);
        shelf.moreParams = TNStr(more[@"params"]);
        shelf.items = TNItemsFrom(TNArr(r[@"contents"]));
    } else if ((r = TNDict(section[@"musicCardShelfRenderer"]))) {
        shelf.title = L(@"Top result");
        NSMutableArray *items = [NSMutableArray array];
        id top = TNTopResultFromCard(r);
        if (top) [items addObject:top];
        for (id item in TNItemsFrom(TNArr(r[@"contents"]))) {
            // (the songs under an artist's card come without the artist: it is the card's)
            if ([top isKindOfClass:[TNArtist class]] && [item isKindOfClass:[TNTrack class]] && ![(TNTrack *)item artistNames].length) {
                ((TNTrack *)item).artists = @[ top ];
                ((TNTrack *)item).byline = ((TNArtist *)top).name;
            }
            [items addObject:item];
        }
        shelf.items = items;
    } else if ((r = TNDict(section[@"gridRenderer"]))) {
        shelf.title = TNText(TNAt(r, @"header.gridHeaderRenderer.title"));
        shelf.items = TNItemsFrom(TNArr(r[@"items"]));
    } else if ((r = TNDict(section[@"itemSectionRenderer"]))) {
        shelf.items = TNItemsFrom(TNArr(r[@"contents"]));
    } else {
        return nil;
    }
    shelf.songs = TNAllTracks(shelf.items);
    return shelf.items.count ? shelf : nil;
}

static NSArray *TNShelvesFrom(NSArray *sections)
{
    NSMutableArray *shelves = [NSMutableArray array];
    for (id s in sections ?: @[]) {
        TNShelf *shelf = TNShelfFrom(TNDict(s));
        if (shelf) [shelves addObject:shelf];
    }
    return shelves;
}

// The first sectionListRenderer anywhere in a response (the pages nest it differently)
static NSDictionary *TNFindKey(id node, NSString *key, int depth)
{
    if (depth > 12) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = node;
        if (TNDict(d[key])) return d[key];
        for (NSString *k in d) {
            id v = d[k];
            if (![v isKindOfClass:[NSDictionary class]] && ![v isKindOfClass:[NSArray class]]) continue;
            NSDictionary *found = TNFindKey(v, key, depth + 1);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id v in node) {
            NSDictionary *found = TNFindKey(v, key, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

#pragma mark - Model classes

@implementation TNSearchResults
- (BOOL)empty
{
    for (TNShelf *s in self.shelves) if (s.items.count) return NO;
    return YES;
}
@end

@implementation TNArtistPage
@end

@implementation TNWatchQueue
@end

#pragma mark - Requests

@implementation TNYTMusic

+ (NSString *)language
{
    NSString *lang = [[[NSBundle mainBundle] preferredLocalizations] firstObject] ?: @"en";
    return [lang hasPrefix:@"cs"] ? @"cs" : @"en";
}

+ (NSString *)region
{
    NSString *r = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    return r.length == 2 ? [r uppercaseString] : @"US";
}

+ (NSString *)playlistIdFromBrowseId:(NSString *)browseId
{
    if ([browseId hasPrefix:@"VL"]) return [browseId substringFromIndex:2];
    return browseId;
}

+ (NSDictionary *)callSync:(NSString *)endpoint body:(NSDictionary *)body error:(NSError **)error
{
    NSMutableDictionary *full = body ? [body mutableCopy] : [NSMutableDictionary dictionary];
    full[@"context"] = @{ @"client": @{ @"clientName": @"WEB_REMIX", @"clientVersion": TNYTMVersion,
                                         @"hl": [self language], @"gl": [self region] } };
    NSData *data = [TNUtils JSONDataFromObject:full];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@?prettyPrint=false", TNYTMBase, endpoint]];
    NSError *failure = nil;
    for (int attempt = 0; attempt < 2; attempt++) {
        TNHTTPRequest *r = [[TNHTTPRequest alloc] initWithMethod:@"POST" URL:url];
        r.headers = @{ @"Content-Type": @"application/json", @"Accept": @"application/json", @"User-Agent": TNYTMUserAgent,
                       @"Origin": @"https://music.youtube.com", @"Referer": @"https://music.youtube.com/",
                       @"X-YouTube-Client-Name": @"67", @"X-YouTube-Client-Version": TNYTMVersion,
                       @"Accept-Language": [self language] };
        r.body = data;
        r.connectTimeout = 15;
        r.readTimeout = 30;
        r.verifyTLS = [TNSettings verifyTLS];
        __block NSError *requestError = nil;
        r.onComplete = ^(NSError *e) { requestError = e; };
        [r runSynchronously];
        if (requestError) {
            failure = requestError;
            if (requestError.code == TNErrorCancelled || requestError.code == TNErrorCertificate) break;
            usleep(400000);
            continue;
        }
        NSInteger status = r.statusCode;
        NSDictionary *json = TNDict([TNUtils JSONObjectFromData:r.responseBody]);
        if (status == 200 && json) return json;
        NSString *message = TNStr(TNAt(json, @"error.message"));
        if (status >= 500) {
            failure = TNMakeError(TNErrorAPI, L(@"YouTube Music is not answering right now. Try again in a moment."));
            usleep(400000);
            continue;
        }
        failure = TNMakeError(TNErrorAPI, message.length ? message : [NSString stringWithFormat:L(@"YouTube Music answered with an error (HTTP %ld)."), (long)status]);
        break;
    }
    if (error) *error = failure ?: TNMakeError(TNErrorNetwork, L(@"YouTube Music could not be reached."));
    return nil;
}

static dispatch_queue_t TNYTMQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.samcejko.muzika.ytm", DISPATCH_QUEUE_CONCURRENT); });
    return queue;
}

// Work on a worker thread, its result on the main thread (unless the task was cancelled meanwhile)
+ (TNHTTPTask *)run:(id (^)(NSError **error))work completion:(void (^)(id result, NSError *error))completion
{
    TNHTTPTask *task = [[TNHTTPTask alloc] init];
    dispatch_async(TNYTMQueue(), ^{
        NSError *error = nil;
        id result = task.isCancelled ? nil : work(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!task.isCancelled && completion) completion(result, error);
        });
    });
    return task;
}

#pragma mark - Pages

+ (TNHTTPTask *)home:(void (^)(NSArray *, NSError *))completion
{
    return [self browsePage:@"FEmusic_home" params:nil completion:^(NSString *title, NSArray *shelves, NSError *error) {
        completion(shelves, error);
    }];
}

+ (TNHTTPTask *)browsePage:(NSString *)browseId params:(NSString *)params completion:(void (^)(NSString *, NSArray *, NSError *))completion
{
    return [self run:^id(NSError **error) {
        NSMutableDictionary *body = [NSMutableDictionary dictionaryWithObject:browseId ?: @"" forKey:@"browseId"];
        if (params.length) body[@"params"] = params;
        NSDictionary *json = [self callSync:@"browse" body:body error:error];
        if (!json) return nil;
        NSDictionary *list = TNFindKey(json[@"contents"], @"sectionListRenderer", 0);
        NSArray *shelves = TNShelvesFrom(TNArr(list[@"contents"]));
        NSString *title = TNText(TNAt(json, @"header.musicHeaderRenderer.title")) ?: TNText(TNAt(json, @"header.musicImmersiveHeaderRenderer.title")) ?: @"";
        TNLog(@"browse %@: %lu shelves", browseId, (unsigned long)shelves.count);
        return @[ title, shelves ];
    } completion:^(id resultObject, NSError *error) {
        NSArray *result = TNArr(resultObject);
        completion(result.count ? result[0] : nil, result.count ? result[1] : nil, error);
    }];
}

#pragma mark - Search

// The new layout puts every result in a section of its own: they are gathered into shelves by kind
static NSArray *TNGroupResults(NSArray *shelves)
{
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *songs = [NSMutableArray array], *videos = [NSMutableArray array], *albums = [NSMutableArray array],
                   *artists = [NSMutableArray array], *playlists = [NSMutableArray array];
    for (TNShelf *s in shelves) {
        if (s.title.length) { [out addObject:s]; continue; }
        for (id item in s.items) {
            if ([item isKindOfClass:[TNTrack class]]) [(((TNTrack *)item).isVideo ? videos : songs) addObject:item];
            else if ([item isKindOfClass:[TNAlbum class]]) [albums addObject:item];
            else if ([item isKindOfClass:[TNArtist class]]) [artists addObject:item];
            else if ([item isKindOfClass:[TNPlaylist class]]) [playlists addObject:item];
        }
    }
    NSArray *groups = @[ @[ L(@"Songs"), songs ], @[ L(@"Videos"), videos ], @[ L(@"Albums"), albums ], @[ L(@"Artists"), artists ], @[ L(@"Playlists"), playlists ] ];
    for (NSArray *g in groups) {
        if (![g[1] count]) continue;
        TNShelf *s = [[TNShelf alloc] init];
        s.title = g[0];
        s.items = g[1];
        s.songs = TNAllTracks(s.items);
        [out addObject:s];
    }
    return out;
}

+ (TNSearchResults *)searchResultsSync:(NSString *)query filter:(TNSearchFilter)filter error:(NSError **)error
{
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithObject:query ?: @"" forKey:@"query"];
    NSString *params = TNFilterParams(filter);
    if (params) body[@"params"] = params;
    NSDictionary *json = [self callSync:@"search" body:body error:error];
    if (!json) return nil;
    NSDictionary *list = TNFindKey(TNAt(json, @"contents.tabbedSearchResultsRenderer"), @"sectionListRenderer", 0) ?: TNFindKey(json[@"contents"], @"sectionListRenderer", 0);
    NSArray *sections = TNArr(list[@"contents"]);
    TNSearchResults *results = [[TNSearchResults alloc] init];
    NSArray *shelves = TNShelvesFrom(sections);
    results.shelves = filter == TNSearchAll ? TNGroupResults(shelves) : shelves;
    if (filter != TNSearchAll) {
        for (id s in sections) {
            NSDictionary *shelf = TNDict(TNDict(s)[@"musicShelfRenderer"]);
            if (shelf) { results.continuation = TNContinuationIn(TNArr(shelf[@"contents"]), shelf); break; }
        }
    }
    return results;
}

+ (TNHTTPTask *)search:(NSString *)query filter:(TNSearchFilter)filter completion:(void (^)(TNSearchResults *, NSError *))completion
{
    return [self run:^id(NSError **error) {
        return [self searchResultsSync:query filter:filter error:error];
    } completion:^(id result, NSError *error) {
        completion(result, error);
    }];
}

+ (NSArray *)searchSync:(NSString *)query filter:(TNSearchFilter)filter error:(NSError **)error
{
    TNSearchResults *results = [self searchResultsSync:query filter:filter error:error];
    NSMutableArray *items = [NSMutableArray array];
    for (TNShelf *s in results.shelves) [items addObjectsFromArray:s.items ?: @[]];
    return results ? items : nil;
}

+ (TNHTTPTask *)searchMore:(NSString *)continuation completion:(void (^)(NSArray *, NSString *, NSError *))completion
{
    return [self run:^id(NSError **error) {
        NSDictionary *json = [self callSync:@"search" body:@{ @"continuation": continuation ?: @"" } error:error];
        if (!json) return nil;
        NSDictionary *shelf = TNDict(TNAt(json, @"continuationContents.musicShelfContinuation"));
        NSArray *contents = TNArr(shelf[@"contents"]);
        NSString *next = TNContinuationIn(contents, shelf);
        return @[ TNItemsFrom(contents), next ?: @"" ];
    } completion:^(id resultObject, NSError *error) {
        NSArray *result = TNArr(resultObject);
        NSString *next = result.count > 1 && [result[1] length] ? result[1] : nil;
        completion(result.count ? result[0] : nil, next, error);
    }];
}

+ (TNHTTPTask *)suggestions:(NSString *)input completion:(void (^)(NSArray *, NSError *))completion
{
    return [self run:^id(NSError **error) {
        NSDictionary *json = [self callSync:@"music/get_search_suggestions" body:@{ @"input": input ?: @"" } error:error];
        if (!json) return nil;
        NSMutableArray *texts = [NSMutableArray array];
        for (id section in TNArr(json[@"contents"]) ?: @[]) {
            for (id c in TNArr(TNAt(section, @"searchSuggestionsSectionRenderer.contents")) ?: @[]) {
                NSString *t = TNText(TNAt(c, @"searchSuggestionRenderer.suggestion"));
                if (t.length && ![texts containsObject:t]) [texts addObject:t];
            }
        }
        return texts;
    } completion:^(id result, NSError *error) {
        completion(result, error);
    }];
}

#pragma mark - Album, artist, playlist

+ (TNHTTPTask *)album:(NSString *)browseId completion:(void (^)(TNAlbum *, NSArray *, NSError *))completion
{
    return [self run:^id(NSError **error) {
        NSDictionary *json = [self callSync:@"browse" body:@{ @"browseId": browseId ?: @"" } error:error];
        if (!json) return nil;
        TNAlbum *album = [[TNAlbum alloc] init];
        album.browseId = browseId;
        NSDictionary *header = TNFindKey(json, @"musicResponsiveHeaderRenderer", 0) ?: TNFindKey(json, @"musicDetailHeaderRenderer", 0);
        album.name = TNText(header[@"title"]);
        album.thumbnails = TNThumbsOf(header);
        album.info = TNText(header[@"secondSubtitle"]);
        album.descriptionText = TNText(TNAt(header, @"description.musicDescriptionShelfRenderer.description")) ?: TNText(header[@"description"]);
        NSMutableArray *artists = [NSMutableArray array];
        for (id run in TNRunsOf(header[@"straplineTextOne"])) { TNArtist *a = TNArtistFromRun(TNDict(run)); if (a) [artists addObject:a]; }
        NSArray *subRuns = TNRunsOf(header[@"subtitle"]);
        for (id run in subRuns) { TNArtist *a = TNArtistFromRun(TNDict(run)); if (a) [artists addObject:a]; }
        for (NSString *seg in TNSegments(subRuns)) {
            if (TNIsYear(seg)) album.year = seg;
            else if (TNIsTypeWord(seg) && !album.kind) album.kind = seg;
        }
        if (!artists.count) {
            NSString *strap = TNText(header[@"straplineTextOne"]);
            if (strap.length) { TNArtist *a = [[TNArtist alloc] init]; a.name = strap; [artists addObject:a]; }
        }
        album.artists = artists;
        for (id b in TNArr(header[@"buttons"]) ?: @[]) {
            NSString *pl = TNStr(TNAt(b, @"musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.playlistId")) ?:
                           TNStr(TNAt(b, @"buttonRenderer.navigationEndpoint.watchPlaylistEndpoint.playlistId"));
            if ([pl hasPrefix:@"OLAK"]) { album.playlistId = pl; break; }
        }
        // the songs: the first shelf of the second column; the rest ("Other versions"...) are shelves
        NSDictionary *second = TNDict(TNAt(json, @"contents.twoColumnBrowseResultsRenderer.secondaryContents.sectionListRenderer"));
        NSArray *sections = TNArr(second[@"contents"]);
        if (!sections) sections = TNArr(TNFindKey(json[@"contents"], @"sectionListRenderer", 0)[@"contents"]);
        NSMutableArray *tracks = [NSMutableArray array];
        NSMutableArray *shelves = [NSMutableArray array];
        for (id s in sections ?: @[]) {
            NSDictionary *songs = TNDict(TNDict(s)[@"musicShelfRenderer"]);
            if (songs && !tracks.count) {
                TNAlbum *ref = [[TNAlbum alloc] init];   // (the songs carry a light copy: no list in a list)
                ref.browseId = album.browseId;
                ref.playlistId = album.playlistId;
                ref.name = album.name;
                ref.thumbnails = album.thumbnails;
                ref.artists = album.artists;
                ref.year = album.year;
                for (id item in TNItemsFrom(TNArr(songs[@"contents"]))) {
                    if (![item isKindOfClass:[TNTrack class]]) continue;
                    TNTrack *t = item;
                    t.album = ref;
                    if (!t.artists.count) t.artists = album.artists;
                    if (!t.byline.length) t.byline = [album artistNames];
                    if (!t.thumbnails.count) t.thumbnails = album.thumbnails;
                    t.isVideo = NO;   // (an album's song, whatever YouTube calls its video)
                    [tracks addObject:t];
                }
                if (!album.playlistId.length) {
                    NSString *pl = TNStr(TNAt([TNArr(songs[@"contents"]) firstObject], @"musicResponsiveListItemRenderer.flexColumns.0.musicResponsiveListItemFlexColumnRenderer.text.runs.0.navigationEndpoint.watchEndpoint.playlistId"));
                    if (pl.length) { album.playlistId = pl; ref.playlistId = pl; }
                }
                continue;
            }
            TNShelf *shelf = TNShelfFrom(TNDict(s));
            if (shelf) [shelves addObject:shelf];
        }
        album.tracks = tracks;
        TNLog(@"album %@: %@, %lu songs", browseId, album.name, (unsigned long)tracks.count);
        return @[ album, shelves ];
    } completion:^(id resultObject, NSError *error) {
        NSArray *result = TNArr(resultObject);
        completion(result.count ? result[0] : nil, result.count ? result[1] : nil, error);
    }];
}

+ (TNHTTPTask *)artist:(NSString *)browseId completion:(void (^)(TNArtistPage *, NSError *))completion
{
    return [self run:^id(NSError **error) {
        NSDictionary *json = [self callSync:@"browse" body:@{ @"browseId": browseId ?: @"" } error:error];
        if (!json) return nil;
        TNArtistPage *page = [[TNArtistPage alloc] init];
        NSDictionary *header = TNDict(TNAt(json, @"header.musicImmersiveHeaderRenderer")) ?: TNDict(TNAt(json, @"header.musicVisualHeaderRenderer")) ?:
                               TNFindKey(json[@"header"], @"musicResponsiveHeaderRenderer", 0);
        TNArtist *artist = [[TNArtist alloc] init];
        artist.browseId = browseId;
        artist.name = TNText(header[@"title"]);
        artist.thumbnails = TNThumbsOf(header);
        artist.subtitle = TNText(header[@"monthlyListenerCount"]);
        page.artist = artist;
        page.bannerThumbnails = artist.thumbnails;
        page.subscribers = TNText(TNAt(header, @"subscriptionButton.subscribeButtonRenderer.subscriberCountText"));
        page.descriptionText = TNText(header[@"description"]);
        page.radioVideoId = TNStr(TNAt(header, @"startRadioButton.buttonRenderer.navigationEndpoint.watchEndpoint.videoId"));
        page.radioPlaylistId = TNStr(TNAt(header, @"startRadioButton.buttonRenderer.navigationEndpoint.watchEndpoint.playlistId"));
        NSDictionary *list = TNFindKey(json[@"contents"], @"sectionListRenderer", 0);
        NSMutableArray *shelves = [NSMutableArray array];
        for (id s in TNArr(list[@"contents"]) ?: @[]) {
            NSDictionary *songs = TNDict(TNDict(s)[@"musicShelfRenderer"]);
            if (songs && !page.topSongs.count) {
                page.topSongs = TNItemsFrom(TNArr(songs[@"contents"]));
                page.allSongsBrowseId = TNStr(TNAt(songs, @"bottomEndpoint.browseEndpoint.browseId")) ?:
                                        TNStr(TNAt([TNRunsOf(songs[@"title"]) firstObject], @"navigationEndpoint.browseEndpoint.browseId"));
                continue;
            }
            NSString *about = TNText(TNAt(s, @"musicDescriptionShelfRenderer.description"));
            if (about.length) { if (!page.descriptionText.length) page.descriptionText = about; continue; }
            TNShelf *shelf = TNShelfFrom(TNDict(s));
            if (shelf) [shelves addObject:shelf];
        }
        page.shelves = shelves;
        TNLog(@"artist %@: %@, %lu top songs, %lu shelves", browseId, artist.name, (unsigned long)page.topSongs.count, (unsigned long)shelves.count);
        return page;
    } completion:^(id result, NSError *error) {
        completion(result, error);
    }];
}

+ (TNHTTPTask *)playlist:(NSString *)browseId completion:(void (^)(TNPlaylist *, NSArray *, NSString *, NSError *))completion
{
    NSString *bid = [browseId hasPrefix:@"VL"] ? browseId : [@"VL" stringByAppendingString:browseId ?: @""];
    return [self run:^id(NSError **error) {
        NSDictionary *json = [self callSync:@"browse" body:@{ @"browseId": bid } error:error];
        if (!json) return nil;
        TNPlaylist *p = [[TNPlaylist alloc] init];
        p.browseId = bid;
        p.playlistId = [self playlistIdFromBrowseId:bid];
        p.source = TNSourceYouTube;
        NSDictionary *header = TNFindKey(json, @"musicResponsiveHeaderRenderer", 0) ?: TNFindKey(json, @"musicDetailHeaderRenderer", 0);
        p.name = TNText(header[@"title"]);
        p.thumbnails = TNThumbsOf(header);
        p.info = TNText(header[@"secondSubtitle"]);
        p.trackCount = TNCountIn(p.info);
        p.descriptionText = TNText(TNAt(header, @"description.musicDescriptionShelfRenderer.description")) ?: TNText(header[@"description"]);
        p.author = TNText(header[@"straplineTextOne"]) ?: TNStr(TNAt(header, @"facepile.avatarStackViewModel.text.content"));
        if (!p.author.length) {
            for (NSString *seg in TNSegments(TNRunsOf(header[@"subtitle"]))) {
                if (TNIsTypeWord(seg) || TNIsYear(seg)) continue;
                p.author = seg;
                break;
            }
        }
        NSDictionary *shelf = TNFindKey(json[@"contents"], @"musicPlaylistShelfRenderer", 0) ?: TNFindKey(json[@"contents"], @"musicShelfRenderer", 0);
        NSArray *contents = TNArr(shelf[@"contents"]);
        NSArray *tracks = TNItemsFrom(contents);
        NSString *next = TNContinuationIn(contents, shelf);
        if (!next) {
            NSDictionary *list = TNDict(TNAt(json, @"contents.twoColumnBrowseResultsRenderer.secondaryContents.sectionListRenderer"));
            next = TNContinuationIn(nil, list);
        }
        TNLog(@"playlist %@: %@, %lu songs%@", bid, p.name, (unsigned long)tracks.count, next.length ? @", more" : @"");
        return @[ p, tracks, next ?: @"" ];
    } completion:^(id resultObject, NSError *error) {
        NSArray *result = TNArr(resultObject);
        NSString *next = result.count > 2 && [result[2] length] ? result[2] : nil;
        completion(result.count ? result[0] : nil, result.count > 1 ? result[1] : nil, next, error);
    }];
}

+ (TNHTTPTask *)playlistMore:(NSString *)continuation completion:(void (^)(NSArray *, NSString *, NSError *))completion
{
    return [self run:^id(NSError **error) {
        NSDictionary *json = [self callSync:@"browse" body:@{ @"continuation": continuation ?: @"" } error:error];
        if (!json) return nil;
        NSArray *contents = TNArr(TNAt(json, @"onResponseReceivedActions.0.appendContinuationItemsAction.continuationItems"));
        NSDictionary *older = TNDict(TNAt(json, @"continuationContents.musicPlaylistShelfContinuation"));
        if (!contents) contents = TNArr(older[@"contents"]);
        NSString *next = TNContinuationIn(contents, older);
        return @[ TNItemsFrom(contents), next ?: @"" ];
    } completion:^(id resultObject, NSError *error) {
        NSArray *result = TNArr(resultObject);
        NSString *next = result.count > 1 && [result[1] length] ? result[1] : nil;
        completion(result.count ? result[0] : nil, next, error);
    }];
}

#pragma mark - Radio, lyrics

+ (TNWatchQueue *)watchQueueFrom:(NSDictionary *)json
{
    TNWatchQueue *q = [[TNWatchQueue alloc] init];
    NSArray *tabs = TNArr(TNAt(json, @"contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer.watchNextTabbedResultsRenderer.tabs"));
    NSDictionary *panel = TNDict(TNAt(tabs.firstObject, @"tabRenderer.content.musicQueueRenderer.content.playlistPanelRenderer"));
    NSArray *contents = TNArr(panel[@"contents"]);
    q.tracks = TNItemsFrom(contents);
    q.continuation = TNContinuationIn(contents, panel);
    q.playlistId = TNStr(panel[@"playlistId"]);
    for (id tab in tabs) {
        NSDictionary *browse = TNDict(TNAt(tab, @"tabRenderer.endpoint.browseEndpoint"));
        NSString *type = TNPageType(browse);
        if ([type isEqualToString:@"MUSIC_PAGE_TYPE_TRACK_LYRICS"]) q.lyricsBrowseId = TNStr(browse[@"browseId"]);
        if ([type isEqualToString:@"MUSIC_PAGE_TYPE_TRACK_RELATED"]) q.relatedBrowseId = TNStr(browse[@"browseId"]);
    }
    return q;
}

+ (TNHTTPTask *)radioFor:(NSString *)videoId playlistId:(NSString *)playlistId completion:(void (^)(TNWatchQueue *, NSError *))completion
{
    return [self run:^id(NSError **error) {
        NSMutableDictionary *body = [NSMutableDictionary dictionary];
        if (videoId.length) body[@"videoId"] = videoId;
        body[@"playlistId"] = playlistId.length ? playlistId : [@"RDAMVM" stringByAppendingString:videoId ?: @""];
        body[@"isAudioOnly"] = @YES;
        body[@"enablePersistentPlaylistPanel"] = @YES;
        body[@"tunerSettingValue"] = @"AUTOMIX_SETTING_NORMAL";
        NSDictionary *json = [self callSync:@"next" body:body error:error];
        if (!json) return nil;
        TNWatchQueue *q = [self watchQueueFrom:json];
        if (!q.playlistId.length) q.playlistId = body[@"playlistId"];
        TNLog(@"radio %@: %lu songs, lyrics %@", videoId ?: playlistId, (unsigned long)q.tracks.count, q.lyricsBrowseId.length ? @"yes" : @"no");
        return q;
    } completion:^(id result, NSError *error) {
        completion(result, error);
    }];
}

+ (TNHTTPTask *)radioMore:(TNWatchQueue *)queue completion:(void (^)(NSArray *, NSString *, NSError *))completion
{
    NSString *token = queue.continuation, *playlistId = queue.playlistId;
    return [self run:^id(NSError **error) {
        NSMutableDictionary *body = [NSMutableDictionary dictionaryWithObject:token ?: @"" forKey:@"continuation"];
        if (playlistId.length) body[@"playlistId"] = playlistId;
        body[@"isAudioOnly"] = @YES;
        body[@"enablePersistentPlaylistPanel"] = @YES;
        NSDictionary *json = [self callSync:@"next" body:body error:error];
        if (!json) return nil;
        NSDictionary *panel = TNDict(TNAt(json, @"continuationContents.playlistPanelContinuation"));
        NSArray *contents = TNArr(panel[@"contents"]);
        return @[ TNItemsFrom(contents), TNContinuationIn(contents, panel) ?: @"" ];
    } completion:^(id resultObject, NSError *error) {
        NSArray *result = TNArr(resultObject);
        NSString *next = result.count > 1 && [result[1] length] ? result[1] : nil;
        completion(result.count ? result[0] : nil, next, error);
    }];
}

+ (TNHTTPTask *)lyricsFor:(NSString *)videoId completion:(void (^)(NSString *, NSString *, NSError *))completion
{
    return [self run:^id(NSError **error) {
        NSDictionary *next = [self callSync:@"next" body:@{ @"videoId": videoId ?: @"", @"isAudioOnly": @YES } error:error];
        if (!next) return nil;
        NSString *lyricsId = [self watchQueueFrom:next].lyricsBrowseId;
        if (!lyricsId.length) return @[ @"", @"" ];
        NSDictionary *json = [self callSync:@"browse" body:@{ @"browseId": lyricsId } error:error];
        if (!json) return nil;
        NSDictionary *shelf = TNFindKey(json[@"contents"], @"musicDescriptionShelfRenderer", 0);
        return @[ TNText(shelf[@"description"]) ?: @"", TNText(shelf[@"footer"]) ?: @"" ];
    } completion:^(id resultObject, NSError *error) {
        NSArray *result = TNArr(resultObject);
        completion(result.count ? result[0] : nil, result.count > 1 ? result[1] : nil, error);
    }];
}

@end
