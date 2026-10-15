#import "TNListViewController.h"

@class TNAlbum, TNPlaylist;

// A list of songs with a header: an album, a YouTube Music playlist, an Apple Music playlist (its songs looked up on
// YouTube while it is open), one of Muzika's own playlists (edited here), the liked songs, the songs played lately, the
// downloaded songs, or any list given
@interface TNTrackListViewController : TNListViewController

- (instancetype)initWithAlbum:(TNAlbum *)album;
- (instancetype)initWithPlaylist:(TNPlaylist *)playlist;
- (instancetype)initLikedSongs;
- (instancetype)initRecent;
- (instancetype)initDownloads;
- (instancetype)initWithTracks:(NSArray *)tracks title:(NSString *)title contextURI:(NSString *)uri;

@end
