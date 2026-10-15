#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// What the screens show: songs, albums, artists and playlists of YouTube Music, and the songs and playlists of an
// Apple Music library (a song of Apple Music plays as its YouTube twin, found by TNMatcher). Everything can be
// written as JSON (the library, the saved queue) and read back.

typedef NS_ENUM(NSInteger, TNSource) {
    TNSourceYouTube = 0,
    TNSourceApple,
    TNSourceLocal,
};

// Image addresses: the smallest picture at least `pixels` big from a list of {url, width, height}, rewritten so that
// this system can show it (Google's image servers send JPEG instead of WebP, YouTube's frames without the WebP query)
NSString *TNBestThumbnail(NSArray *thumbnails, CGFloat pixels);
NSString *TNSizedImageURL(NSString *url, CGFloat pixels);
NSString *TNAppleArtworkURL(NSString *template, CGFloat pixels);   // ".../{w}x{h}bb.jpg"

NSInteger TNParseDurationMs(NSString *text);      // "4:36" -> 276000, "1:02:03"; 0 when it is no duration
NSString *TNFormatDurationMs(NSInteger ms);       // 3:05, 1:02:03

@interface TNArtist : NSObject
@property (nonatomic, copy) NSString *browseId;       // "UC..." (the artist's page); nil for a name without a page
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray *thumbnails;      // NSDictionary {url, width, height}
@property (nonatomic, copy) NSString *subtitle;       // "73.6M monthly audience"
- (NSString *)imageURLForSize:(CGFloat)pixels;
- (NSDictionary *)toJSON;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

@interface TNAlbum : NSObject
@property (nonatomic, copy) NSString *browseId;       // "MPREb_..."
@property (nonatomic, copy) NSString *playlistId;     // "OLAK5uy_..." (its songs as a playlist)
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray *artists;         // TNArtist
@property (nonatomic, copy) NSString *year;
@property (nonatomic, copy) NSString *kind;           // "Album", "Single", "EP" (as YouTube writes it)
@property (nonatomic, copy) NSArray *thumbnails;
@property (nonatomic, copy) NSString *descriptionText;
@property (nonatomic, copy) NSString *info;           // "13 songs • 1 hour, 14 minutes"
@property (nonatomic, copy) NSArray *tracks;          // TNTrack, when the album was fetched whole
- (NSString *)artistNames;
- (NSString *)imageURLForSize:(CGFloat)pixels;
- (NSDictionary *)toJSON;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

@interface TNTrack : NSObject
@property (nonatomic, copy) NSString *videoId;        // what plays; nil for an Apple Music song not matched yet
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray *artists;         // TNArtist
@property (nonatomic, copy) NSString *byline;         // the artists as written ("Daft Punk & Pharrell Williams")
@property (nonatomic, strong) TNAlbum *album;
@property (nonatomic) NSInteger durationMs;
@property (nonatomic, copy) NSArray *thumbnails;
@property (nonatomic) BOOL explicitContent;
@property (nonatomic) BOOL isVideo;                   // a music video or an upload rather than the song itself
@property (nonatomic, copy) NSString *plays;          // "1.2B plays"
@property (nonatomic, copy) NSString *setVideoId;     // its place in a YouTube playlist
@property (nonatomic) NSInteger trackNumber;
// An Apple Music song
@property (nonatomic, copy) NSString *appleId;        // the library's id ("i.xxxx") or the catalog's
@property (nonatomic, copy) NSString *appleCatalogId;
@property (nonatomic, copy) NSString *isrc;
@property (nonatomic, copy) NSString *appleArtwork;   // the artwork template
@property (nonatomic) BOOL matchFailed;               // looked for on YouTube, nothing fitted
// A Spotify song (imported from a link): it is looked up on YouTube as an Apple Music one is
@property (nonatomic, copy) NSString *spotifyId;

- (BOOL)isApple;                                       // it plays as its YouTube twin (Apple Music, Spotify)
- (BOOL)playable;                                     // it has a video, or it is an Apple song that may find one
- (NSString *)key;                                    // what it is known by (the same song from two lists is equal)
- (NSString *)artistNames;
- (NSString *)imageURLForSize:(CGFloat)pixels;
- (NSDictionary *)toJSON;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

@interface TNPlaylist : NSObject
@property (nonatomic, copy) NSString *playlistId;     // YouTube: "PL...", "RDCLAK...", "OLAK..."; Apple: "p.xxx", "pl.u-..."
@property (nonatomic, copy) NSString *browseId;       // YouTube: "VL" + the playlist id
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *descriptionText;
@property (nonatomic, copy) NSArray *thumbnails;
@property (nonatomic, copy) NSString *info;           // "34 songs • 2 hours, 30 minutes"
@property (nonatomic) TNSource source;
@property (nonatomic) NSInteger trackCount;
@property (nonatomic, copy) NSString *appleArtwork;
@property (nonatomic, copy) NSString *storefront;     // an Apple catalog playlist: its country
@property (nonatomic) BOOL fromLibrary;               // Apple: one of the user's library playlists (else a catalog one)
@property (nonatomic, copy) NSString *modified;       // Apple: lastModifiedDate
@property (nonatomic) BOOL canEdit;                   // Apple: a library playlist songs can be added to
@property (nonatomic) BOOL coverIsOwn;                // an own playlist with a picture of its own (an import's)
@property (nonatomic, copy) NSArray *tracks;
- (NSString *)imageURLForSize:(CGFloat)pixels;
- (NSString *)key;
- (NSDictionary *)toJSON;
+ (instancetype)fromJSON:(NSDictionary *)json;
@end

// A row of a page: a carousel of cards or a list of songs, with where "More" leads
@interface TNShelf : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *strapline;
@property (nonatomic, copy) NSArray *items;
@property (nonatomic, copy) NSString *moreBrowseId;
@property (nonatomic, copy) NSString *moreParams;
@property (nonatomic) BOOL songs;                     // the items are songs to list ("Quick picks", "Top songs")
@end

// A mood or a genre (a coloured button of Explore)
@interface TNCategory : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *browseId;
@property (nonatomic, copy) NSString *params;
@property (nonatomic, copy) NSString *colorHex;       // "#RRGGBB"
@end

// What a model is called and what its second line says, for the lists and cards
NSString *TNTitleOf(id item);
NSString *TNSubtitleOf(id item);
NSString *TNImageOf(id item, CGFloat pixels);
