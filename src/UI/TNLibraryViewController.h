#import "TNListViewController.h"

typedef NS_ENUM(NSInteger, TNLibraryMode) {
    TNLibraryPlaylists = 0,
    TNLibraryAlbums,
    TNLibraryArtists,
    TNLibraryApple,
    TNLibraryAppleAlbums,       // the Apple Music library's albums, made from its songs
    TNLibraryAppleArtists,
    TNLibraryAppleRecent,       // what was added lately
};

// What is kept on this device: playlists (Liked music, Recently played, Downloads, own playlists, imports), albums,
// artists, and the Apple Music library (connect, sync, its songs, albums, artists, what was added lately, playlists). With the switcher (the iPhone's Library tab) the kinds sit behind one control.
@interface TNLibraryViewController : TNListViewController
- (instancetype)initWithMode:(TNLibraryMode)mode switcher:(BOOL)switcher;
@property (nonatomic) TNLibraryMode mode;
@end
