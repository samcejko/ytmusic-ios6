#import <Foundation/Foundation.h>

// Where a song's sound is. YouTube serves its audio files (AAC in MP4, itag 140) in full only to clients with a
// proof-of-origin token; without one the files stop after about a minute. The helper of the family (yt-dlp on the
// Raspberry Pi, "/yt/resolve", shared with Tubie) hands out addresses that serve the whole file.
@interface TNStreams : NSObject

// Blocking, never on the main thread. `durationMs` receives the song's length when known.
+ (NSString *)audioURLForVideo:(NSString *)videoId durationMs:(NSInteger *)durationMs error:(NSError **)error;
// An address that failed (expired, refused): the next request asks the helper again
+ (void)forget:(NSString *)videoId;

@end
