#import <Foundation/Foundation.h>

// One audio file of a song
@interface TNAudioSource : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic) NSInteger itag;          // 140: AAC-LC 128 kbit/s, 139: HE-AAC 48 kbit/s
@property (nonatomic) NSInteger durationMs;
@property (nonatomic) double loudnessDb;       // how much louder than YouTube's target (-14 LUFS) the song is
@end

// Where a song's sound is (AAC in MP4), straight from YouTube: the player API asked as YouTube's visionOS app, with
// the visitor id YouTube Music handed out, answers with addresses that serve the whole file to this device's own
// connection (no server of ours in between, works anywhere).
@interface TNStreams : NSObject

// Blocking, never on the main thread. `lowQuality`: the HE-AAC version when there is one.
+ (TNAudioSource *)audioForVideo:(NSString *)videoId lowQuality:(BOOL)lowQuality error:(NSError **)error;
// An address that failed (expired, refused): the next request asks again
+ (void)forget:(NSString *)videoId;

@end
