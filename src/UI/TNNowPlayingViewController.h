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

// The queue: now playing, "Next in queue", "Next from <context>" (Edit: move and remove songs)
@interface TNQueueViewController : UITableViewController
- (void)refresh;
@end

// The lyrics of the song playing, in time when they are (a tap on a line jumps there); follows the player by itself
@interface TNLyricsViewController : UITableViewController
- (void)refresh;
- (void)tick;
@end
