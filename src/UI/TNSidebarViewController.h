#import <UIKit/UIKit.h>
#import "TNRootViewController.h"

@class TNPlaylist;

// The iPad's left column, as in the music apps of 2012: Home, Explore and Search, the library, the Apple Music
// playlists, and Settings at the bottom
@interface TNSidebarViewController : UIViewController
@property (nonatomic, copy) void (^onSection)(TNSection section);
@property (nonatomic, copy) void (^onPlaylist)(TNPlaylist *playlist);
- (void)selectSection:(TNSection)section;
- (void)selectPlaylist:(NSString *)playlistKey;
@end
