#import "TNListViewController.h"

@class TNArtist;

// An artist: the picture, the audience, Play / Radio / Save, the top songs, then YouTube Music's shelves (albums,
// singles, videos, featured on, fans might also like)
@interface TNArtistViewController : TNListViewController
- (instancetype)initWithArtist:(TNArtist *)artist;
@end
