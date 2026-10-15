#import <Foundation/Foundation.h>

@class TNTrack, TNAlbum, TNArtist, TNPlaylist;

// What the user keeps, on this device (there is no YouTube account): liked songs, saved albums, artists and
// playlists, the songs played lately, and the copy of the Apple Music library (its playlists and their songs).
// Main thread only; written to Application Support in the background. Changes post TNLibraryDidChangeNotification
// (Apple Music ones TNAppleDidChangeNotification).
@interface TNLibrary : NSObject

+ (instancetype)shared;

- (NSArray *)likedSongs;                   // newest first
- (BOOL)isLiked:(TNTrack *)track;
- (void)setLiked:(BOOL)liked track:(TNTrack *)track;

- (NSArray *)savedAlbums;
- (BOOL)isSavedAlbum:(TNAlbum *)album;
- (void)setSaved:(BOOL)saved album:(TNAlbum *)album;

- (NSArray *)savedArtists;
- (BOOL)isSavedArtist:(TNArtist *)artist;
- (void)setSaved:(BOOL)saved artist:(TNArtist *)artist;

// YouTube Music playlists and imported Apple Music links (catalog playlists and albums)
- (NSArray *)savedPlaylists;
- (BOOL)isSavedPlaylist:(TNPlaylist *)playlist;
- (void)setSaved:(BOOL)saved playlist:(TNPlaylist *)playlist;

- (NSArray *)recentTracks;                 // newest first, at most 100
- (void)addRecent:(TNTrack *)track;
- (void)clearRecent;

// Apple Music: the library's playlists as last synced, and the songs of any Apple playlist kept here
- (NSArray *)applePlaylists;
- (void)setApplePlaylists:(NSArray *)playlists;
- (NSArray *)tracksOfPlaylist:(TNPlaylist *)playlist;          // nil when not kept yet
- (void)setTracks:(NSArray *)tracks ofPlaylist:(TNPlaylist *)playlist;
- (void)forgetApple;                                          // disconnecting: the synced copy goes

- (void)saveNow;

@end
