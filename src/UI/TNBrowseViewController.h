#import "TNListViewController.h"

// A page of YouTube Music made of shelves: Explore, charts, new releases, a mood or a genre, "More" of a shelf.
// Song shelves show as YouTube Music's columns of songs, the rest as cards, moods and genres as coloured buttons.
@interface TNBrowseViewController : TNListViewController

- (instancetype)initWithBrowseId:(NSString *)browseId params:(NSString *)params title:(NSString *)title;

@property (nonatomic, copy, readonly) NSString *browseId;
@property (nonatomic, strong) NSArray *shelves;                  // TNShelf, what the table shows

// For subclasses: the shelves loaded from YouTube Music become the page (extra local shelves can be added first)
- (NSArray *)shelvesForLoaded:(NSArray *)loaded;

@end
