#import "TNListViewController.h"

// "Add to playlist": a new playlist, one of Muzika's own, or (with Apple Music connected) a new or an editable Apple
// Music playlist of the library. Shown as a sheet; closes itself after adding.
@interface TNPlaylistPickerViewController : TNListViewController
- (instancetype)initWithTracks:(NSArray *)tracks;
@end
