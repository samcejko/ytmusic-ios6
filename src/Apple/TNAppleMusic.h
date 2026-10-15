#import <Foundation/Foundation.h>
#import "TNHTTP.h"

@class TNPlaylist;

// The user's Apple Music library through the API music.apple.com itself uses (amp-api.music.apple.com): the web
// player's developer token (read from its script, renewed by itself) and the user's own "media-user-token" (the
// cookie music.apple.com sets after the login; the user copies it from a computer's browser). Only reads: the
// playlists and their songs, with the ISRC of every song (for TNMatcher). Public playlists and albums can be imported
// from a music.apple.com link without any account.
@interface TNAppleMusic : NSObject

+ (instancetype)shared;

- (BOOL)connected;
// Checks the token with Apple, keeps it (keychain) and syncs the library
- (void)connectWithToken:(NSString *)token completion:(void (^)(NSError *error))completion;
- (void)disconnect;

// The library's playlists, then the songs of those that changed since the last time (kept in TNLibrary)
- (void)syncWithCompletion:(void (^)(NSError *error))completion;
@property (nonatomic, readonly) BOOL syncing;
@property (nonatomic, readonly, copy) NSString *syncStatus;     // "Playlist 3 of 12: Road trip"

// The songs of an Apple playlist (a library one or a catalog one), fresh from Apple
- (TNHTTPTask *)tracksOf:(TNPlaylist *)playlist completion:(void (^)(NSArray *tracks, NSError *error))completion;
// A music.apple.com link to a playlist or an album: it and its songs (no account needed)
- (TNHTTPTask *)importLink:(NSString *)link completion:(void (^)(TNPlaylist *playlist, NSArray *tracks, NSError *error))completion;
+ (BOOL)isAppleMusicLink:(NSString *)text;

- (NSString *)debugState;

@end
