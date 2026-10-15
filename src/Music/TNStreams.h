#import <Foundation/Foundation.h>

// Where a song's sound is (AAC in MP4, itag 140), straight from YouTube: the player API asked as YouTube's visionOS
// app, with the visitor id YouTube Music handed out, answers with addresses that serve the whole file to this
// device's own connection (no server of ours in between, works anywhere).
@interface TNStreams : NSObject

// Blocking, never on the main thread. `durationMs` receives the song's length when known.
+ (NSString *)audioURLForVideo:(NSString *)videoId durationMs:(NSInteger *)durationMs error:(NSError **)error;
// An address that failed (expired, refused): the next request asks again
+ (void)forget:(NSString *)videoId;

@end
