#import "TNListViewController.h"

// Search: suggestions while typing, then YouTube Music's results (top result, songs, videos, albums, artists,
// playlists) or one kind of them with the filter chips, page after page. A music.apple.com or YouTube link pasted
// here opens (an Apple Music playlist is imported).
@interface TNSearchViewController : TNListViewController
- (instancetype)init;
- (void)focusSearchField;
- (void)searchFor:(NSString *)query;
@end
