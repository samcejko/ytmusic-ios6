#import <Foundation/Foundation.h>
#import "TNHTTP.h"
#import "TNModels.h"

typedef NS_ENUM(NSInteger, TNSearchFilter) {
    TNSearchAll = 0,
    TNSearchSongs,
    TNSearchVideos,
    TNSearchAlbums,
    TNSearchArtists,
    TNSearchPlaylists,
};

@interface TNSearchResults : NSObject
@property (nonatomic, copy) NSArray *shelves;          // TNShelf: "Top result", then songs, videos, albums, artists, playlists
@property (nonatomic, copy) NSString *continuation;    // a filtered search: the next page
- (BOOL)empty;
@end

@interface TNArtistPage : NSObject
@property (nonatomic, strong) TNArtist *artist;
@property (nonatomic, copy) NSString *subscribers;     // "7.19M"
@property (nonatomic, copy) NSString *descriptionText;
@property (nonatomic, copy) NSArray *topSongs;         // TNTrack
@property (nonatomic, copy) NSString *allSongsBrowseId;   // "VL..." (all the artist's songs as a playlist)
@property (nonatomic, copy) NSArray *shelves;          // TNShelf: albums, singles, videos, featured on, similar artists...
@property (nonatomic, copy) NSString *radioVideoId;
@property (nonatomic, copy) NSString *radioPlaylistId;
@property (nonatomic, copy) NSArray *bannerThumbnails;
@end

// The queue YouTube Music plays after a song (its radio), and where the song's lyrics and related things are
@interface TNWatchQueue : NSObject
@property (nonatomic, copy) NSArray *tracks;
@property (nonatomic, copy) NSString *continuation;
@property (nonatomic, copy) NSString *playlistId;
@property (nonatomic, copy) NSString *lyricsBrowseId;
@property (nonatomic, copy) NSString *relatedBrowseId;
@end

// YouTube Music's InnerTube API as the web player uses it (music.youtube.com/youtubei/v1, client WEB_REMIX),
// no account. Completion blocks run on the main thread; a cancelled task never calls back.
@interface TNYTMusic : NSObject

// One call from any thread, blocking (the matcher and the player use it on their worker threads)
+ (NSDictionary *)callSync:(NSString *)endpoint body:(NSDictionary *)body error:(NSError **)error;

+ (TNHTTPTask *)home:(void (^)(NSArray *shelves, NSError *error))completion;
// Any page of shelves: Explore (FEmusic_explore), charts, new releases, a mood or genre, "Related" of a song
+ (TNHTTPTask *)browsePage:(NSString *)browseId params:(NSString *)params
                completion:(void (^)(NSString *title, NSArray *shelves, NSError *error))completion;

+ (TNHTTPTask *)search:(NSString *)query filter:(TNSearchFilter)filter completion:(void (^)(TNSearchResults *results, NSError *error))completion;
+ (TNHTTPTask *)searchMore:(NSString *)continuation completion:(void (^)(NSArray *items, NSString *continuation, NSError *error))completion;
+ (NSArray *)searchSync:(NSString *)query filter:(TNSearchFilter)filter error:(NSError **)error;   // the items of the first page
+ (TNHTTPTask *)suggestions:(NSString *)input completion:(void (^)(NSArray *texts, NSError *error))completion;

+ (TNHTTPTask *)album:(NSString *)browseId completion:(void (^)(TNAlbum *album, NSArray *shelves, NSError *error))completion;
+ (TNHTTPTask *)artist:(NSString *)browseId completion:(void (^)(TNArtistPage *page, NSError *error))completion;
// A playlist ("VL..." or the bare id) and its first songs; the rest page after page
+ (TNHTTPTask *)playlist:(NSString *)browseId completion:(void (^)(TNPlaylist *playlist, NSArray *tracks, NSString *continuation, NSError *error))completion;
+ (TNHTTPTask *)playlistMore:(NSString *)continuation completion:(void (^)(NSArray *tracks, NSString *continuation, NSError *error))completion;

// The radio of a song (or of a playlist id such as an album's), with the song itself first
+ (TNHTTPTask *)radioFor:(NSString *)videoId playlistId:(NSString *)playlistId completion:(void (^)(TNWatchQueue *queue, NSError *error))completion;
+ (TNHTTPTask *)radioMore:(TNWatchQueue *)queue completion:(void (^)(NSArray *tracks, NSString *continuation, NSError *error))completion;
+ (TNHTTPTask *)lyricsFor:(NSString *)videoId completion:(void (^)(NSString *text, NSString *source, NSError *error))completion;

// "VLPL..." -> "PL..."
+ (NSString *)playlistIdFromBrowseId:(NSString *)browseId;

@end
