#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, TNSection) {
    TNSectionHome = 0,
    TNSectionExplore,
    TNSectionSearch,
    TNSectionLiked,
    TNSectionPlaylists,
    TNSectionAlbums,
    TNSectionArtists,
    TNSectionRecent,
    TNSectionApple,
    TNSectionSettings,
    TNSectionLibrary,       // the iPhone's library tab (everything kept behind one switch)
};

// The frame of the app. iPad: the sidebar on the left, the content on the right, the player bar along the bottom.
// iPhone: the content, the compact player bar and the tab bar.
@interface TNRootViewController : UIViewController

+ (instancetype)shared;

- (void)showSection:(TNSection)section;
@property (nonatomic, readonly) TNSection section;
- (UINavigationController *)contentNavigationController;   // the one on screen

- (void)pushViewController:(UIViewController *)controller;  // onto the content on screen (closing what covers it)
- (void)presentNowPlaying;
- (void)presentNowPlayingPanel:(NSInteger)panel;            // TNNowPlayingPanel
- (void)presentSheet:(UIViewController *)controller;        // in its own navigation bar; a form sheet on the iPad
- (void)showToast:(NSString *)text;

- (UIViewController *)topController;                        // for the debug commands
- (void)goBack;

@end
