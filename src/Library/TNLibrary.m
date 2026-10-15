#import "TNLibrary.h"
#import "TNModels.h"
#import "TNUtils.h"
#import "TNCommon.h"

static const NSUInteger TNMaxRecent = 100;

@implementation TNLibrary {
    NSMutableArray *_liked;        // TNTrack
    NSMutableArray *_albums;       // TNAlbum
    NSMutableArray *_artists;      // TNArtist
    NSMutableArray *_playlists;    // TNPlaylist
    NSMutableArray *_recent;       // TNTrack
    NSArray *_applePlaylists;      // TNPlaylist
    NSMutableDictionary *_tracks;  // playlist key -> NSArray of TNTrack (loaded on demand)
    BOOL _saveScheduled;
    dispatch_queue_t _io;
}

+ (instancetype)shared
{
    static TNLibrary *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ library = [[TNLibrary alloc] init]; });
    return library;
}

+ (NSString *)folder
{
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [base stringByAppendingPathComponent:@"Muzika"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

+ (NSString *)tracksFolder
{
    NSString *dir = [[self folder] stringByAppendingPathComponent:@"playlists"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

static NSMutableArray *TNTracksFrom(id json)
{
    NSMutableArray *out = [NSMutableArray array];
    for (id x in TNArr(json) ?: @[]) { TNTrack *t = [TNTrack fromJSON:TNDict(x)]; if (t) [out addObject:t]; }
    return out;
}

static NSArray *TNJSONOf(NSArray *items)
{
    NSMutableArray *out = [NSMutableArray array];
    for (id x in items) if ([x respondsToSelector:@selector(toJSON)]) [out addObject:[x toJSON]];
    return out;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _io = dispatch_queue_create("com.samcejko.muzika.library", DISPATCH_QUEUE_SERIAL);
        _tracks = [NSMutableDictionary dictionary];
        NSString *path = [[TNLibrary folder] stringByAppendingPathComponent:@"library.json"];
        NSDictionary *json = TNDict([TNUtils JSONObjectFromData:[NSData dataWithContentsOfFile:path]]);
        _liked = TNTracksFrom(json[@"liked"]);
        _recent = TNTracksFrom(json[@"recent"]);
        _albums = [NSMutableArray array];
        for (id x in TNArr(json[@"albums"]) ?: @[]) { TNAlbum *a = [TNAlbum fromJSON:TNDict(x)]; if (a) [_albums addObject:a]; }
        _artists = [NSMutableArray array];
        for (id x in TNArr(json[@"artists"]) ?: @[]) { TNArtist *a = [TNArtist fromJSON:TNDict(x)]; if (a) [_artists addObject:a]; }
        _playlists = [NSMutableArray array];
        for (id x in TNArr(json[@"playlists"]) ?: @[]) { TNPlaylist *p = [TNPlaylist fromJSON:TNDict(x)]; if (p) [_playlists addObject:p]; }
        NSMutableArray *apple = [NSMutableArray array];
        for (id x in TNArr(json[@"apple"]) ?: @[]) { TNPlaylist *p = [TNPlaylist fromJSON:TNDict(x)]; if (p) [apple addObject:p]; }
        _applePlaylists = apple;
    }
    return self;
}

#pragma mark - Saving

- (void)changed:(NSString *)notification
{
    [[NSNotificationCenter defaultCenter] postNotificationName:notification object:self];
    if (_saveScheduled) return;
    _saveScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self saveNow]; });
}

- (void)saveNow
{
    _saveScheduled = NO;
    NSDictionary *json = @{ @"liked": TNJSONOf(_liked), @"recent": TNJSONOf(_recent), @"albums": TNJSONOf(_albums),
                            @"artists": TNJSONOf(_artists), @"playlists": TNJSONOf(_playlists), @"apple": TNJSONOf(_applePlaylists) };
    NSString *path = [[TNLibrary folder] stringByAppendingPathComponent:@"library.json"];
    dispatch_async(_io, ^{
        NSData *data = [TNUtils JSONDataFromObject:json];
        if (data) [data writeToFile:path atomically:YES];
    });
}

#pragma mark - Liked songs

- (NSArray *)likedSongs { return [_liked copy]; }

- (NSInteger)indexOfTrack:(TNTrack *)track in:(NSArray *)list
{
    NSString *key = [track key];
    for (NSUInteger i = 0; i < list.count; i++) if ([[list[i] key] isEqualToString:key]) return (NSInteger)i;
    return -1;
}

- (BOOL)isLiked:(TNTrack *)track { return track && [self indexOfTrack:track in:_liked] >= 0; }

- (void)setLiked:(BOOL)liked track:(TNTrack *)track
{
    if (!track) return;
    NSInteger i = [self indexOfTrack:track in:_liked];
    if (liked && i < 0) [_liked insertObject:track atIndex:0];
    else if (!liked && i >= 0) [_liked removeObjectAtIndex:(NSUInteger)i];
    else return;
    [self changed:TNLibraryDidChangeNotification];
}

#pragma mark - Albums, artists, playlists

- (NSArray *)savedAlbums { return [_albums copy]; }

- (NSInteger)indexOfAlbum:(TNAlbum *)album
{
    for (NSUInteger i = 0; i < _albums.count; i++) if ([[_albums[i] browseId] isEqualToString:album.browseId]) return (NSInteger)i;
    return -1;
}

- (BOOL)isSavedAlbum:(TNAlbum *)album { return album.browseId.length && [self indexOfAlbum:album] >= 0; }

- (void)setSaved:(BOOL)saved album:(TNAlbum *)album
{
    if (!album.browseId.length) return;
    NSInteger i = [self indexOfAlbum:album];
    if (saved && i < 0) {
        TNAlbum *copy = [TNAlbum fromJSON:[album toJSON]];   // (without its songs)
        [_albums insertObject:copy ?: album atIndex:0];
    } else if (!saved && i >= 0) [_albums removeObjectAtIndex:(NSUInteger)i];
    else return;
    [self changed:TNLibraryDidChangeNotification];
}

- (NSArray *)savedArtists { return [_artists copy]; }

- (NSInteger)indexOfArtist:(TNArtist *)artist
{
    for (NSUInteger i = 0; i < _artists.count; i++) if ([[_artists[i] browseId] isEqualToString:artist.browseId]) return (NSInteger)i;
    return -1;
}

- (BOOL)isSavedArtist:(TNArtist *)artist { return artist.browseId.length && [self indexOfArtist:artist] >= 0; }

- (void)setSaved:(BOOL)saved artist:(TNArtist *)artist
{
    if (!artist.browseId.length) return;
    NSInteger i = [self indexOfArtist:artist];
    if (saved && i < 0) [_artists insertObject:artist atIndex:0];
    else if (!saved && i >= 0) [_artists removeObjectAtIndex:(NSUInteger)i];
    else return;
    [self changed:TNLibraryDidChangeNotification];
}

- (NSArray *)savedPlaylists { return [_playlists copy]; }

- (NSInteger)indexOfPlaylist:(TNPlaylist *)playlist
{
    NSString *key = [playlist key];
    for (NSUInteger i = 0; i < _playlists.count; i++) if ([[_playlists[i] key] isEqualToString:key]) return (NSInteger)i;
    return -1;
}

- (BOOL)isSavedPlaylist:(TNPlaylist *)playlist { return playlist.playlistId.length && [self indexOfPlaylist:playlist] >= 0; }

- (void)setSaved:(BOOL)saved playlist:(TNPlaylist *)playlist
{
    if (!playlist.playlistId.length) return;
    NSInteger i = [self indexOfPlaylist:playlist];
    if (saved && i < 0) [_playlists insertObject:playlist atIndex:0];
    else if (!saved && i >= 0) [_playlists removeObjectAtIndex:(NSUInteger)i];
    else return;
    [self changed:TNLibraryDidChangeNotification];
}

#pragma mark - Recent

- (NSArray *)recentTracks { return [_recent copy]; }

- (void)addRecent:(TNTrack *)track
{
    if (!track) return;
    NSInteger i = [self indexOfTrack:track in:_recent];
    if (i == 0) return;
    if (i > 0) [_recent removeObjectAtIndex:(NSUInteger)i];
    [_recent insertObject:track atIndex:0];
    while (_recent.count > TNMaxRecent) [_recent removeLastObject];
    [self changed:TNLibraryDidChangeNotification];
}

- (void)clearRecent
{
    [_recent removeAllObjects];
    [self changed:TNLibraryDidChangeNotification];
}

#pragma mark - Apple Music

- (NSArray *)applePlaylists { return _applePlaylists ?: @[]; }

- (void)setApplePlaylists:(NSArray *)playlists
{
    _applePlaylists = [playlists copy];
    [self changed:TNAppleDidChangeNotification];
}

- (NSString *)fileForPlaylist:(TNPlaylist *)playlist
{
    NSMutableString *name = [NSMutableString string];
    for (NSUInteger i = 0; i < [playlist key].length; i++) {
        unichar c = [[playlist key] characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.';
        [name appendFormat:@"%C", ok ? c : (unichar)'_'];
    }
    return [[TNLibrary tracksFolder] stringByAppendingPathComponent:[name stringByAppendingString:@".json"]];
}

- (NSArray *)tracksOfPlaylist:(TNPlaylist *)playlist
{
    if (!playlist.playlistId.length) return nil;
    NSString *key = [playlist key];
    NSArray *cached = _tracks[key];
    if (cached) return cached;
    NSData *data = [NSData dataWithContentsOfFile:[self fileForPlaylist:playlist]];
    if (!data) return nil;
    NSArray *tracks = TNTracksFrom([TNUtils JSONObjectFromData:data]);
    _tracks[key] = tracks;
    return tracks;
}

- (void)setTracks:(NSArray *)tracks ofPlaylist:(TNPlaylist *)playlist
{
    if (!playlist.playlistId.length) return;
    _tracks[[playlist key]] = [tracks copy] ?: @[];
    NSArray *json = TNJSONOf(tracks);
    NSString *path = [self fileForPlaylist:playlist];
    dispatch_async(_io, ^{
        NSData *data = [TNUtils JSONDataFromObject:json];
        if (data) [data writeToFile:path atomically:YES];
    });
    [[NSNotificationCenter defaultCenter] postNotificationName:TNAppleDidChangeNotification object:self];
}

- (void)forgetApple
{
    NSMutableArray *keep = [NSMutableArray array];
    for (TNPlaylist *p in _playlists) if (!(p.source == TNSourceApple && p.fromLibrary)) [keep addObject:p];
    _playlists = keep;
    for (TNPlaylist *p in _applePlaylists) {
        [_tracks removeObjectForKey:[p key]];
        [[NSFileManager defaultManager] removeItemAtPath:[self fileForPlaylist:p] error:NULL];
    }
    _applePlaylists = @[];
    [self changed:TNAppleDidChangeNotification];
}

@end
