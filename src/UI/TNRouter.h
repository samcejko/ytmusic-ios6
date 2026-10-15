#import <UIKit/UIKit.h>

@class TNAlbum, TNArtist, TNPlaylist, TNTrack, TNCategory;

// A UIActionSheet with a block per button (the delegate keeps itself alive while the sheet is up)
@interface TNActionSheet : NSObject
- (instancetype)initWithTitle:(NSString *)title;
- (void)addButton:(NSString *)title action:(dispatch_block_t)action;
- (void)addDestructiveButton:(NSString *)title action:(dispatch_block_t)action;
- (void)showFromView:(UIView *)view inController:(UIViewController *)controller;
@end

// Going places: album, artist, playlist and browse pages, links, the actions of a song, now playing
@interface TNRouter : NSObject

+ (void)openAlbum:(TNAlbum *)album;
+ (void)openArtist:(TNArtist *)artist;
+ (void)openPlaylist:(TNPlaylist *)playlist;
+ (void)openCategory:(TNCategory *)category;
+ (void)openBrowseId:(NSString *)browseId params:(NSString *)params title:(NSString *)title;   // any page of shelves, or an album/playlist/artist by its id
+ (void)openLikedSongs;
+ (void)openRecent;
+ (void)openItem:(id)item;                         // any shelf item: a song plays, the rest opens
+ (BOOL)openURL:(NSString *)url;                   // music.youtube.com, youtube.com and music.apple.com links
+ (void)push:(UIViewController *)controller;       // onto the content that is on screen (closing what covers it)

+ (void)showActionsForTrack:(TNTrack *)track fromView:(UIView *)view inController:(UIViewController *)controller;
+ (void)chooseVideoForTrack:(TNTrack *)track;      // an Apple Music song: which YouTube version plays
+ (void)toggleLike:(TNTrack *)track;
+ (void)showNowPlaying;
+ (void)showAppleConnect;
+ (void)toast:(NSString *)text;                    // a short note in the middle of the screen

@end
