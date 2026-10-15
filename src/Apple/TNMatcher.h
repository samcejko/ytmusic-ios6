#import <Foundation/Foundation.h>

@class TNTrack;

// Apple Music songs play as their YouTube Music twins. A song is looked up by its ISRC (the code every recording has;
// YouTube Music finds songs by it) and else by its title and artist, the candidates scored by title, artist and
// length. What was found is kept (Application Support/Muzika/matches.json), a choice of the user's own wins over
// anything automatic. TNMatchDidChangeNotification tells about new matches (userInfo[@"key"]).
@interface TNMatcher : NSObject

+ (instancetype)shared;

- (NSString *)cachedVideoIdFor:(TNTrack *)track;     // any thread
- (BOOL)hasFailed:(TNTrack *)track;                  // looked for, nothing fitted
- (void)applyTo:(NSArray *)tracks;                   // fills in the videos known for these songs (main thread)

// The video for a song now: the cache, else a search (blocking; worker threads only)
- (NSString *)videoIdForTrackSync:(TNTrack *)track error:(NSError **)error;

// Looks the songs up in the background, one after the other (the newest request first)
- (void)matchTracks:(NSArray *)tracks;
@property (nonatomic, readonly) NSUInteger pendingCount;

- (void)setVideoId:(NSString *)videoId forTrack:(TNTrack *)track;   // the user's choice
- (void)forget:(TNTrack *)track;                                    // look it up again next time
- (NSUInteger)matchCount;
- (void)forgetAll;

@end
