#import "TNLegacyCollections.h"
#import "TNModels.h"
#import "TNCommon.h"

#pragma mark - Images

// Google's image servers take the size and format after the last "=": w120-h120-l90-rj (rj: JPEG, rw: WebP)
static NSString *TNGoogleImageURL(NSString *url, CGFloat pixels)
{
    NSRange eq = [url rangeOfString:@"=" options:NSBackwardsSearch];
    NSRange slash = [url rangeOfString:@"/" options:NSBackwardsSearch];
    BOOL hasParams = eq.location != NSNotFound && (slash.location == NSNotFound || eq.location > slash.location);
    NSString *base = hasParams ? [url substringToIndex:eq.location] : url;
    NSString *params = hasParams ? [url substringFromIndex:eq.location + 1] : @"";
    NSInteger w = 0, h = 0;
    BOOL crop = NO;
    for (NSString *p in [params componentsSeparatedByString:@"-"]) {
        if (p.length < 1) continue;
        unichar c = [p characterAtIndex:0];
        NSString *rest = [p substringFromIndex:1];
        BOOL digits = rest.length > 0 && [rest rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
        if (c == 'w' && digits) w = [rest integerValue];
        else if (c == 'h' && digits) h = [rest integerValue];
        else if (c == 's' && digits) w = h = [rest integerValue];
        else if ([p isEqualToString:@"p"]) crop = YES;
    }
    NSInteger n = MAX(1, (NSInteger)ceil(pixels));
    NSInteger nw = n, nh = n;
    if (w > 0 && h > 0 && w != h) {
        // a banner keeps its shape, the longer side as asked
        if (w > h) { nw = n; nh = MAX(1, n * h / w); }
        else { nh = n; nw = MAX(1, n * w / h); }
    }
    return [NSString stringWithFormat:@"%@=w%ld-h%ld%@-l90-rj", base, (long)nw, (long)nh, crop ? @"-p" : @""];
}

NSString *TNSizedImageURL(NSString *url, CGFloat pixels)
{
    if (![url isKindOfClass:[NSString class]] || !url.length) return nil;
    if ([url hasPrefix:@"//"]) url = [@"https:" stringByAppendingString:url];
    NSURL *u = [NSURL URLWithString:url];
    NSString *host = [u.host lowercaseString] ?: @"";
    if ([host hasSuffix:@"ytimg.com"]) {
        // https://i.ytimg.com/vi/<id>/hqdefault.jpg?sqp=...: the query asks for WebP, which iOS 6 cannot show.
        // The frame without black bars: mqdefault (320x180) for small pictures, hq720 (1280x720) for big ones.
        NSRange q = [url rangeOfString:@"?"];
        NSString *base = q.location != NSNotFound ? [url substringToIndex:q.location] : url;
        for (NSString *marker in @[ @"/vi/", @"/vi_webp/" ]) {
            NSRange vi = [base rangeOfString:marker];
            if (vi.location == NSNotFound) continue;
            NSString *videoId = [[[base substringFromIndex:vi.location + marker.length] componentsSeparatedByString:@"/"] firstObject];
            if (videoId.length == 11) return [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/%@", videoId, pixels <= 320 ? @"mqdefault.jpg" : @"hq720.jpg"];
        }
        return base;
    }
    if ([host hasSuffix:@"googleusercontent.com"] || [host hasSuffix:@"ggpht.com"]) return TNGoogleImageURL(url, pixels);
    return url;
}

NSString *TNBestThumbnail(NSArray *thumbnails, CGFloat pixels)
{
    NSDictionary *best = nil, *largest = nil;
    NSInteger bestSide = NSIntegerMax, largestSide = -1;
    for (id t in [thumbnails isKindOfClass:[NSArray class]] ? thumbnails : @[]) {
        NSDictionary *d = TNDict(t);
        if (!TNStr([d objectForKey:@"url"]).length) continue;
        NSInteger side = MAX(TNInt([d objectForKey:@"width"]), TNInt([d objectForKey:@"height"]));
        if (side > largestSide) { largestSide = side; largest = d; }
        if (side >= pixels && side < bestSide) { bestSide = side; best = d; }
    }
    NSDictionary *pick = best ?: largest;
    return pick ? TNSizedImageURL(TNStr([pick objectForKey:@"url"]), pixels) : nil;
}

NSString *TNAppleArtworkURL(NSString *template, CGFloat pixels)
{
    if (![template isKindOfClass:[NSString class]] || !template.length) return nil;
    NSString *n = [NSString stringWithFormat:@"%ld", (long)MAX(1, (NSInteger)ceil(pixels))];
    NSString *u = [template stringByReplacingOccurrencesOfString:@"{w}" withString:n];
    u = [u stringByReplacingOccurrencesOfString:@"{h}" withString:n];
    u = [u stringByReplacingOccurrencesOfString:@"{f}" withString:@"jpg"];
    u = [u stringByReplacingOccurrencesOfString:@"{c}" withString:@"bb"];
    return u;
}

NSInteger TNParseDurationMs(NSString *text)
{
    if (![text isKindOfClass:[NSString class]]) return 0;
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *parts = [t componentsSeparatedByString:@":"];
    if (parts.count < 2 || parts.count > 3) return 0;
    NSInteger total = 0;
    for (NSString *p in parts) {
        if (!p.length || p.length > 2 || [p rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) return 0;
        total = total * 60 + [p integerValue];
    }
    return total * 1000;
}

NSString *TNFormatDurationMs(NSInteger ms)
{
    NSInteger s = MAX(0, ms) / 1000;
    if (s >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(s / 3600), (long)(s / 60 % 60), (long)(s % 60)];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(s / 60), (long)(s % 60)];
}

#pragma mark - JSON helpers

static void TNPut(NSMutableDictionary *d, NSString *key, id value)
{
    if (!value) return;
    if ([value isKindOfClass:[NSString class]] && ![value length]) return;
    if ([value isKindOfClass:[NSArray class]] && ![value count]) return;
    TNLegacyDictionarySet(d, key, value);
}

static NSArray *TNArtistsJSON(NSArray *artists)
{
    NSMutableArray *out = [NSMutableArray array];
    for (TNArtist *a in artists) if ([a isKindOfClass:[TNArtist class]]) [out addObject:[a toJSON]];
    return out;
}

static NSArray *TNArtistsFromJSON(id json)
{
    NSMutableArray *out = [NSMutableArray array];
    for (id a in TNArr(json) ?: @[]) {
        TNArtist *artist = [TNArtist fromJSON:TNDict(a)];
        if (artist) [out addObject:artist];
    }
    return out;
}

static NSString *TNJoinNames(NSArray *artists)
{
    NSMutableArray *names = [NSMutableArray array];
    for (TNArtist *a in artists) if (a.name.length) [names addObject:a.name];
    return [names componentsJoinedByString:@", "];
}

#pragma mark - Artist

@implementation TNArtist

- (NSString *)imageURLForSize:(CGFloat)pixels { return TNBestThumbnail(self.thumbnails, pixels); }

- (NSDictionary *)toJSON
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    TNPut(d, @"id", self.browseId);
    TNPut(d, @"name", self.name);
    TNPut(d, @"thumbs", self.thumbnails);
    TNPut(d, @"sub", self.subtitle);
    return d;
}

+ (instancetype)fromJSON:(NSDictionary *)json
{
    if (!TNDict(json)) return nil;
    TNArtist *a = [[TNArtist alloc] init];
    a.browseId = TNStr([json objectForKey:@"id"]);
    a.name = TNStr([json objectForKey:@"name"]);
    a.thumbnails = TNArr([json objectForKey:@"thumbs"]);
    a.subtitle = TNStr([json objectForKey:@"sub"]);
    return a.name.length || a.browseId.length ? a : nil;
}

@end

#pragma mark - Album

@implementation TNAlbum

- (NSString *)artistNames { return TNJoinNames(self.artists); }
- (NSString *)imageURLForSize:(CGFloat)pixels { return TNBestThumbnail(self.thumbnails, pixels); }

- (NSDictionary *)toJSON
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    TNPut(d, @"id", self.browseId);
    TNPut(d, @"pl", self.playlistId);
    TNPut(d, @"name", self.name);
    TNPut(d, @"artists", TNArtistsJSON(self.artists));
    TNPut(d, @"year", self.year);
    TNPut(d, @"kind", self.kind);
    TNPut(d, @"thumbs", self.thumbnails);
    return d;
}

+ (instancetype)fromJSON:(NSDictionary *)json
{
    if (!TNDict(json)) return nil;
    TNAlbum *a = [[TNAlbum alloc] init];
    a.browseId = TNStr([json objectForKey:@"id"]);
    a.playlistId = TNStr([json objectForKey:@"pl"]);
    a.name = TNStr([json objectForKey:@"name"]);
    a.artists = TNArtistsFromJSON([json objectForKey:@"artists"]);
    a.year = TNStr([json objectForKey:@"year"]);
    a.kind = TNStr([json objectForKey:@"kind"]);
    a.thumbnails = TNArr([json objectForKey:@"thumbs"]);
    return a.name.length || a.browseId.length ? a : nil;
}

@end

#pragma mark - Track

@implementation TNTrack

- (BOOL)isApple { return self.appleId.length || self.appleCatalogId.length || self.isrc.length || self.spotifyId.length; }

- (BOOL)playable { return self.videoId.length > 0 || ([self isApple] && !self.matchFailed); }

- (NSString *)key
{
    if ([self isApple]) {
        if (self.isrc.length) return [@"isrc:" stringByAppendingString:self.isrc];
        if (self.appleCatalogId.length) return [@"am:" stringByAppendingString:self.appleCatalogId];
        if (self.appleId.length) return [@"am:" stringByAppendingString:self.appleId];
        if (self.spotifyId.length) return [@"sp:" stringByAppendingString:self.spotifyId];
    }
    if (self.videoId.length) return self.videoId;
    return [NSString stringWithFormat:@"t:%@|%@", [self.name lowercaseString] ?: @"", [[self artistNames] lowercaseString] ?: @""];
}

- (NSString *)artistNames
{
    if (self.byline.length) return self.byline;
    return TNJoinNames(self.artists);
}

- (NSString *)imageURLForSize:(CGFloat)pixels
{
    NSString *u = TNBestThumbnail(self.thumbnails, pixels);
    if (!u && self.appleArtwork.length) u = TNAppleArtworkURL(self.appleArtwork, pixels);
    if (!u) u = [self.album imageURLForSize:pixels];
    if (!u && self.videoId.length) u = TNSizedImageURL([NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", self.videoId], pixels);
    return u;
}

- (NSDictionary *)toJSON
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    TNPut(d, @"v", self.videoId);
    TNPut(d, @"name", self.name);
    TNPut(d, @"artists", TNArtistsJSON(self.artists));
    TNPut(d, @"by", self.byline);
    if (self.album) TNPut(d, @"album", [self.album toJSON]);
    if (self.durationMs) TNLegacyDictionarySet(d, @"ms", @(self.durationMs));
    TNPut(d, @"thumbs", self.thumbnails);
    if (self.explicitContent) TNLegacyDictionarySet(d, @"e", @YES);
    if (self.isVideo) TNLegacyDictionarySet(d, @"video", @YES);
    TNPut(d, @"svid", self.setVideoId);
    if (self.trackNumber) TNLegacyDictionarySet(d, @"n", @(self.trackNumber));
    TNPut(d, @"am", self.appleId);
    TNPut(d, @"amc", self.appleCatalogId);
    TNPut(d, @"isrc", self.isrc);
    TNPut(d, @"art", self.appleArtwork);
    TNPut(d, @"sp", self.spotifyId);
    return d;
}

+ (instancetype)fromJSON:(NSDictionary *)json
{
    if (!TNDict(json)) return nil;
    TNTrack *t = [[TNTrack alloc] init];
    t.videoId = TNStr([json objectForKey:@"v"]);
    t.name = TNStr([json objectForKey:@"name"]);
    t.artists = TNArtistsFromJSON([json objectForKey:@"artists"]);
    t.byline = TNStr([json objectForKey:@"by"]);
    t.album = [TNAlbum fromJSON:TNDict([json objectForKey:@"album"])];
    t.durationMs = TNInt([json objectForKey:@"ms"]);
    t.thumbnails = TNArr([json objectForKey:@"thumbs"]);
    t.explicitContent = TNBool([json objectForKey:@"e"]);
    t.isVideo = TNBool([json objectForKey:@"video"]);
    t.setVideoId = TNStr([json objectForKey:@"svid"]);
    t.trackNumber = TNInt([json objectForKey:@"n"]);
    t.appleId = TNStr([json objectForKey:@"am"]);
    t.appleCatalogId = TNStr([json objectForKey:@"amc"]);
    t.isrc = TNStr([json objectForKey:@"isrc"]);
    t.appleArtwork = TNStr([json objectForKey:@"art"]);
    t.spotifyId = TNStr([json objectForKey:@"sp"]);
    return t.name.length || t.videoId.length ? t : nil;
}

@end

#pragma mark - Playlist

@implementation TNPlaylist

- (NSString *)imageURLForSize:(CGFloat)pixels
{
    NSString *u = TNBestThumbnail(self.thumbnails, pixels);
    if (!u && self.appleArtwork.length) u = TNAppleArtworkURL(self.appleArtwork, pixels);
    if (!u) {
        for (TNTrack *t in self.tracks) {
            u = [t imageURLForSize:pixels];
            if (u) break;
        }
    }
    return u;
}

- (NSString *)key
{
    return [NSString stringWithFormat:@"%@:%@", self.source == TNSourceApple ? @"am" : self.source == TNSourceLocal ? @"local" : @"yt", self.playlistId ?: @""];
}

- (NSDictionary *)toJSON
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    TNPut(d, @"id", self.playlistId);
    TNPut(d, @"browse", self.browseId);
    TNPut(d, @"name", self.name);
    TNPut(d, @"author", self.author);
    TNPut(d, @"desc", self.descriptionText);
    TNPut(d, @"thumbs", self.thumbnails);
    TNPut(d, @"info", self.info);
    TNLegacyDictionarySet(d, @"src", @(self.source));
    if (self.trackCount) TNLegacyDictionarySet(d, @"count", @(self.trackCount));
    TNPut(d, @"art", self.appleArtwork);
    TNPut(d, @"sf", self.storefront);
    if (self.fromLibrary) TNLegacyDictionarySet(d, @"lib", @YES);
    if (self.canEdit) TNLegacyDictionarySet(d, @"edit", @YES);
    if (self.coverIsOwn) TNLegacyDictionarySet(d, @"cover", @YES);
    TNPut(d, @"mod", self.modified);
    return d;
}

+ (instancetype)fromJSON:(NSDictionary *)json
{
    if (!TNDict(json)) return nil;
    TNPlaylist *p = [[TNPlaylist alloc] init];
    p.playlistId = TNStr([json objectForKey:@"id"]);
    p.browseId = TNStr([json objectForKey:@"browse"]);
    p.name = TNStr([json objectForKey:@"name"]);
    p.author = TNStr([json objectForKey:@"author"]);
    p.descriptionText = TNStr([json objectForKey:@"desc"]);
    p.thumbnails = TNArr([json objectForKey:@"thumbs"]);
    p.info = TNStr([json objectForKey:@"info"]);
    p.source = (TNSource)TNInt([json objectForKey:@"src"]);
    p.trackCount = TNInt([json objectForKey:@"count"]);
    p.appleArtwork = TNStr([json objectForKey:@"art"]);
    p.storefront = TNStr([json objectForKey:@"sf"]);
    p.fromLibrary = TNBool([json objectForKey:@"lib"]);
    p.canEdit = TNBool([json objectForKey:@"edit"]);
    p.coverIsOwn = TNBool([json objectForKey:@"cover"]);
    p.modified = TNStr([json objectForKey:@"mod"]);
    return p.playlistId.length ? p : nil;
}

@end

@implementation TNShelf
@end

@implementation TNCategory
@end

#pragma mark - Lines for the lists

NSString *TNTitleOf(id item)
{
    NSString *name = nil;
    if ([item isKindOfClass:[TNTrack class]]) name = ((TNTrack *)item).name;
    else if ([item isKindOfClass:[TNAlbum class]]) name = ((TNAlbum *)item).name;
    else if ([item isKindOfClass:[TNArtist class]]) name = ((TNArtist *)item).name;
    else if ([item isKindOfClass:[TNPlaylist class]]) name = ((TNPlaylist *)item).name;
    else if ([item isKindOfClass:[TNCategory class]]) name = ((TNCategory *)item).title;
    return name ?: @"";
}

NSString *TNSubtitleOf(id item)
{
    if ([item isKindOfClass:[TNTrack class]]) {
        TNTrack *t = item;
        NSString *kind = t.isVideo ? L(@"Video") : L(@"Song");
        NSString *by = [t artistNames];
        return by.length ? [NSString stringWithFormat:@"%@ • %@", kind, by] : kind;
    }
    if ([item isKindOfClass:[TNAlbum class]]) {
        TNAlbum *a = item;
        NSMutableArray *bits = [NSMutableArray array];
        [bits addObject:a.kind.length ? a.kind : L(@"Album")];
        if ([a artistNames].length) [bits addObject:[a artistNames]];
        if (a.year.length) [bits addObject:a.year];
        return [bits componentsJoinedByString:@" • "];
    }
    if ([item isKindOfClass:[TNArtist class]]) {
        TNArtist *a = item;
        return a.subtitle.length ? a.subtitle : L(@"Artist");
    }
    if ([item isKindOfClass:[TNPlaylist class]]) {
        TNPlaylist *p = item;
        if (p.source == TNSourceApple) {
            return p.trackCount ? [NSString stringWithFormat:L(@"Apple Music • %ld songs"), (long)p.trackCount] : L(@"Apple Music");
        }
        NSMutableArray *bits = [NSMutableArray arrayWithObject:L(@"Playlist")];
        if (p.author.length) [bits addObject:p.author];
        else if (p.trackCount) [bits addObject:[NSString stringWithFormat:L(@"%ld songs"), (long)p.trackCount]];
        return [bits componentsJoinedByString:@" • "];
    }
    return @"";
}

NSString *TNImageOf(id item, CGFloat pixels)
{
    if ([item respondsToSelector:@selector(imageURLForSize:)]) return [item imageURLForSize:pixels];
    return nil;
}
