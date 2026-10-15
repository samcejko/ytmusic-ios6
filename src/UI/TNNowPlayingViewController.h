#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, TNNowPlayingPanel) {
    TNNowPlayingArt = 0,
    TNNowPlayingLyrics,
    TNNowPlayingQueue,
};

// The full player: the cover big over its own darkened copy, the song and artist, the thumb, progress, the controls,
// and in place of the cover the lyrics or the queue ("Up next")
@interface TNNowPlayingViewController : UIViewController
@property (nonatomic) TNNowPlayingPanel panel;
@end

// The queue: now playing, "Next in queue" (removable), "Next from <context>"
@interface TNQueueViewController : UITableViewController
@end
