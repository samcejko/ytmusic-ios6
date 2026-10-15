#import <Foundation/Foundation.h>

@class TNPlaylist;

// A link from elsewhere into the library: a Spotify playlist, album or song (its public embed page lists the songs;
// they are looked up on YouTube as Apple Music ones are) and a YouTube or YouTube Music playlist (copied whole) become
// Muzika's own playlists; an Apple Music playlist or album is saved as it is (TNAppleMusic). Main thread.
@interface TNImport : NSObject

+ (BOOL)isSpotifyLink:(NSString *)text;
+ (BOOL)isYouTubePlaylistLink:(NSString *)text;
+ (BOOL)canImport:(NSString *)text;                // any of the three kinds

+ (void)importLink:(NSString *)link completion:(void (^)(TNPlaylist *playlist, NSError *error))completion;

@end
