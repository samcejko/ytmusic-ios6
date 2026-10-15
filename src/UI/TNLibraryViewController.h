#import "TNListViewController.h"

typedef NS_ENUM(NSInteger, TNLibraryMode) {
    TNLibraryPlaylists = 0,
    TNLibraryAlbums,
    TNLibraryArtists,
    TNLibraryApple,
};

// What is kept on this device: playlists (with Liked music and Recently played), albums, artists, and the Apple Music
// library (connect, sync, import a link). With the switcher (the iPhone's Library tab) the kinds sit behind one control.
@interface TNLibraryViewController : TNListViewController
- (instancetype)initWithMode:(TNLibraryMode)mode switcher:(BOOL)switcher;
@property (nonatomic) TNLibraryMode mode;
@end
