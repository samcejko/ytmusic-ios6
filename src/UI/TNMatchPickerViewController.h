#import "TNListViewController.h"

@class TNTrack;

// Which YouTube version an Apple Music song plays: the songs and videos YouTube Music finds for it, the chosen one
// kept for good (TNMatcher)
@interface TNMatchPickerViewController : TNListViewController
- (instancetype)initWithTrack:(TNTrack *)track;
@end
