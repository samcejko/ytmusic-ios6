#import <UIKit/UIKit.h>

@class TNAlbum, TNArtist, TNPlaylist, TNTrack, TNCategory;

// A UIActionSheet with a block per button (the delegate keeps itself alive while the sheet is up)
@interface TNActionSheet : NSObject
- (instancetype)initWithTitle:(NSString *)title;
- (void)addButton:(NSString *)title action:(dispatch_block_t)action;
- (void)addDestructiveButton:(NSString *)title action:(dispatch_block_t)action;
- (void)showFromView:(UIView *)view inController:(UIViewController *)controller;
+ (BOOL)pressButtonTitled:(NSString *)title;      // the sheet on screen (debug commands)
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
+ (BOOL)openURL:(NSString *)url;                   // music.youtube.com, youtube.com, music.apple.com and open.spotify.com links
+ (void)playHandoff:(NSDictionary *)metadata;
+ (void)cancelHandoff;
+ (void)push:(UIViewController *)controller;       // onto the content that is on screen (closing what covers it)

+ (void)showActionsForTrack:(TNTrack *)track fromView:(UIView *)view inController:(UIViewController *)controller;
+ (void)showActionsForTrack:(TNTrack *)track fromView:(UIView *)view inController:(UIViewController *)controller
                removeTitle:(NSString *)removeTitle remove:(dispatch_block_t)remove;   // + a red "remove from this list"
+ (void)addTracksToPlaylist:(NSArray *)tracks;      // the playlist picker
+ (void)downloadTracks:(NSArray *)tracks;           // those not downloaded yet
+ (void)showSleepTimerFromView:(UIView *)view inController:(UIViewController *)controller;
+ (void)importLinkPrompt;                           // asks for an Apple Music, Spotify or YouTube link
+ (void)importLink:(NSString *)link;
+ (void)promptWithTitle:(NSString *)title message:(NSString *)message text:(NSString *)text placeholder:(NSString *)placeholder
                 button:(NSString *)button completion:(void (^)(NSString *text))completion;   // a text field in an alert
+ (void)chooseVideoForTrack:(TNTrack *)track;      // an Apple Music song: which YouTube version plays
+ (void)toggleLike:(TNTrack *)track;
+ (void)showNowPlaying;
+ (void)showAppleConnect;
+ (void)toast:(NSString *)text;                    // a short note in the middle of the screen

@end
