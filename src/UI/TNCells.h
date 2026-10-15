#import <UIKit/UIKit.h>

@class TNTrack, TNImageView;

// A song in a list: artwork or its number, the title (red while it plays), artists and album, length, the "E" badge,
// for an Apple Music song whether its YouTube twin was found, "…"
@interface TNTrackCell : UITableViewCell
@property (nonatomic, strong, readonly) TNImageView *art;
@property (nonatomic, strong, readonly) UIButton *moreButton;
@property (nonatomic) BOOL showsArt;              // NO: the track number stands there (albums)
@property (nonatomic) BOOL showsAlbum;            // the album after the artists (default YES)
- (void)showTrack:(TNTrack *)track number:(NSInteger)number;
@end

// An album, playlist, artist or anything else in a list: artwork (round for artists), two lines of text
@interface TNMediaCell : UITableViewCell
@property (nonatomic, strong, readonly) TNImageView *art;
@property (nonatomic) BOOL round;
- (void)showTitle:(NSString *)title subtitle:(NSString *)subtitle imageURL:(NSString *)url;
- (void)showItem:(id)item;
@end

// One card of a shelf: square artwork (wide for videos, round for artists) with a title and a subtitle under it
@interface TNCardView : UIControl
@property (nonatomic, strong, readonly) TNImageView *art;
@property (nonatomic, strong, readonly) UILabel *titleLabel;
@property (nonatomic, strong, readonly) UILabel *subtitleLabel;
@property (nonatomic) BOOL round;
@property (nonatomic) BOOL wide;
@property (nonatomic, strong) id item;            // what the card stands for
@end

// A row with a sideways-scrolling shelf of cards ("Albums", "Featured on", "Mixed for you"...)
@interface TNShelfCell : UITableViewCell
@property (nonatomic, copy) void (^onSelect)(id item);
+ (CGFloat)heightForCardWidth:(CGFloat)width;
- (void)showItems:(NSArray *)items cardWidth:(CGFloat)width;   // any models (TNTrack, TNAlbum, TNPlaylist, TNArtist)
@end

// YouTube Music's "Quick picks": columns of four songs, scrolling sideways a column at a time
@interface TNSongGridCell : UITableViewCell
@property (nonatomic, copy) void (^onSelect)(TNTrack *track, NSUInteger index);
@property (nonatomic, copy) void (^onMore)(TNTrack *track, UIView *anchor);
+ (CGFloat)heightForRows:(NSUInteger)rows;
- (void)showTracks:(NSArray *)tracks rows:(NSUInteger)rows columnWidth:(CGFloat)width;
@end

// A row of mood and genre buttons (dark, with their colour along the left edge, as YouTube Music has them)
@interface TNTileRowCell : UITableViewCell
@property (nonatomic, copy) void (^onSelect)(id item);
+ (CGFloat)heightForWidth:(CGFloat)width columns:(NSInteger)columns;
- (void)showTiles:(NSArray *)tiles columns:(NSInteger)columns;   // TNCategory
@end

// The title of a section in the style of the time: small capitals on a dark bar, with "More" when there is more
UIView *TNSectionHeader(NSString *title, CGFloat width);
UIView *TNSectionHeaderWithMore(NSString *title, CGFloat width, id target, SEL action, NSInteger tag);
