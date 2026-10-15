#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, TNIcon) {
    TNIconHome = 0,
    TNIconSearch,
    TNIconLibrary,
    TNIconRadio,
    TNIconSettings,
    TNIconBrowse,
    TNIconPlaylist,
    TNIconHeart,
    TNIconHeartFilled,
    TNIconAlbum,
    TNIconArtist,
    TNIconPodcast,
    TNIconPlay,
    TNIconPause,
    TNIconNext,
    TNIconPrevious,
    TNIconShuffle,
    TNIconRepeat,
    TNIconRepeatOne,
    TNIconQueue,
    TNIconLyrics,
    TNIconDevices,
    TNIconMore,
    TNIconPlus,
    TNIconClose,
    TNIconChevronDown,
    TNIconSpeaker,
    TNIconClock,
    TNIconCheck,
    TNIconExplore,
    TNIconThumbUp,
    TNIconThumbUpFilled,
    TNIconVideo,
    TNIconLink,
    TNIconSync,
    TNIconCloud,
    TNIconWarning,
    TNIconDownload,          // an arrow down into a tray
    TNIconDownloaded,        // a filled disc with an arrow down (a song kept on the device)
    TNIconMoon,              // the sleep timer
    TNIconEdit,              // a pencil
};

// The look of Muzika: Spot6's iPad app of the iOS 6 years made YouTube-like - near-black textured panels, glossy black
// bars, glossy red buttons, artwork drawn in code (no image files). Dark only.
@interface TNTheme : NSObject

+ (instancetype)shared;

// Colours
- (UIColor *)backgroundColor;          // content (textured)
- (UIColor *)plainBackgroundColor;     // the same without texture (cells, labels)
- (UIColor *)panelColor;               // the iPad sidebar
- (UIColor *)rowColor;
- (UIColor *)rowHighlightColor;
- (UIColor *)primaryTextColor;
- (UIColor *)secondaryTextColor;
- (UIColor *)tertiaryTextColor;
- (UIColor *)separatorColor;
- (UIColor *)accentColor;              // YouTube red
- (UIColor *)accentTextColor;          // red readable on dark

// Artwork
- (UIImage *)navigationBarImage;
- (UIImage *)playerBarImage;           // the now-playing strip along the bottom
- (UIImage *)tabBarImage;
- (UIImage *)accentButtonImageHighlighted:(BOOL)highlighted;
- (UIImage *)darkButtonImageHighlighted:(BOOL)highlighted;
- (UIImage *)outlineButtonImageHighlighted:(BOOL)highlighted;
- (UIImage *)searchFieldImage;
- (UIImage *)sidebarSelectionImage;
- (UIImage *)sectionHeaderImage;
- (UIImage *)chipImageSelected:(BOOL)selected;          // the filter chips of search
- (UIImage *)artPlaceholderWithSize:(CGFloat)size;      // dark square with a note
- (UIImage *)artistPlaceholderWithSize:(CGFloat)size;   // round
- (UIImage *)shadowImageTop:(BOOL)top;                  // black fade (over artwork)
- (UIImage *)sliderTrackImageFilled:(BOOL)filled;
- (UIImage *)sliderThumbImage;
- (UIImage *)explicitBadge;
- (UIImage *)brandMarkWithSize:(CGFloat)size;           // Muzika's mark: a glossy red disc with a white note
- (UIImage *)appleMarkWithSize:(CGFloat)size;           // the Apple Music section: a rounded tile with a note

- (UIImage *)icon:(TNIcon)icon size:(CGFloat)size color:(UIColor *)color;
- (UIImage *)icon:(TNIcon)icon size:(CGFloat)size;      // white

// Fonts
- (UIFont *)titleFont;
- (UIFont *)bodyFont;
- (UIFont *)boldBodyFont;
- (UIFont *)smallFont;
- (UIFont *)headerFont;                 // big page titles
- (UIFont *)sectionFont;                // "QUICK PICKS"

// Applying to UIKit
- (void)applyGlobalAppearance;
- (void)applyToNavigationBar:(UINavigationBar *)bar;
- (void)applyToTableView:(UITableView *)tableView;
- (void)styleCell:(UITableViewCell *)cell;
- (void)applyToSearchBar:(UISearchBar *)bar;
- (UIButton *)accentButtonWithTitle:(NSString *)title;
- (UIButton *)outlineButtonWithTitle:(NSString *)title;
- (CGFloat)widthForButton:(UIButton *)button minimum:(CGFloat)minimum;   // its title fits (Czech words are longer)
- (UIActivityIndicatorViewStyle)spinnerStyle;

@end
