#import <Foundation/Foundation.h>

// The app's preferences (NSUserDefaults) and the Apple Music token (keychain). Changes post
// TNSettingsDidChangeNotification on the main thread.
@interface TNSettings : NSObject

+ (void)registerDefaults;
+ (void)save;

// Playback
+ (BOOL)autoplay;                            // when the music runs out, the radio of the last song follows
+ (void)setAutoplay:(BOOL)value;
+ (BOOL)allowVideosForApple;                 // an Apple Music song may play as a music video when no song version exists
+ (void)setAllowVideosForApple:(BOOL)value;
+ (BOOL)matchWholePlaylists;                 // an opened Apple Music playlist is looked up on YouTube at once
+ (void)setMatchWholePlaylists:(BOOL)value;
+ (BOOL)normalize;                           // every song as loud as the next (YouTube's loudness of each song)
+ (void)setNormalize:(BOOL)value;
+ (NSInteger)crossfadeSeconds;               // 0 = off
+ (void)setCrossfadeSeconds:(NSInteger)value;
+ (BOOL)dataSaver;                           // on mobile data the 48 kbit/s HE-AAC version instead of 128 kbit/s AAC
+ (void)setDataSaver:(BOOL)value;
+ (BOOL)downloadOnWiFiOnly;
+ (void)setDownloadOnWiFiOnly:(BOOL)value;
+ (BOOL)syncAppleLikes;                      // the thumb and Apple Music's "love" go together
+ (void)setSyncAppleLikes:(BOOL)value;
+ (BOOL)sidePanel;                           // iPad landscape: "Up next" / lyrics beside the content
+ (void)setSidePanel:(BOOL)value;
+ (BOOL)classicPlayer;
+ (void)setClassicPlayer:(BOOL)value;

// Apple Music
+ (NSString *)appleUserToken;                // the "media-user-token" of music.apple.com (keychain)
+ (void)setAppleUserToken:(NSString *)token;
+ (NSString *)appleStorefront;               // "cz"
+ (void)setAppleStorefront:(NSString *)storefront;
+ (NSString *)appleDeveloperToken;           // the web player's token, while it is valid
+ (void)setAppleDeveloperToken:(NSString *)token expires:(NSDate *)expires;
+ (NSDate *)appleLastSync;
+ (void)setAppleLastSync:(NSDate *)date;

// Network
+ (BOOL)verifyTLS;
+ (void)setVerifyTLS:(BOOL)value;

// Recent searches (newest first)
+ (NSArray *)recentSearches;
+ (void)addRecentSearch:(NSString *)query;
+ (void)clearRecentSearches;

@end
