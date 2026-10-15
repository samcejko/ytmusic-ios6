#import "TNBrowseViewController.h"

extern NSString * const TNAppleChartsBrowseId;    // what Explore's tile opens

// Apple Music's charts of the country (no account needed): top songs as YouTube Music's columns of songs, the daily
// global and city charts, top playlists and albums as cards. The songs play as their YouTube twins.
@interface TNAppleChartsViewController : TNBrowseViewController
- (instancetype)init;
@end
