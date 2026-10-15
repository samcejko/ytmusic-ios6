#import <Foundation/Foundation.h>
#import "TNHTTP.h"

@class TNTrack;

@interface TNLyricsResult : NSObject
@property (nonatomic, copy) NSArray *lines;     // NSDictionary {ms, text}; ms is 0 everywhere when not synced
@property (nonatomic) BOOL synced;
@property (nonatomic, copy) NSString *source;   // "LRCLIB", "Musixmatch"...
@end

// A song's lyrics: line by line in time from LRCLIB (the free, open lyrics database; the version whose length fits
// the song), else the plain text YouTube Music has. Completion on the main thread.
@interface TNLyrics : NSObject
+ (TNHTTPTask *)lyricsFor:(TNTrack *)track videoId:(NSString *)videoId durationMs:(NSInteger)durationMs
               completion:(void (^)(TNLyricsResult *result, NSError *error))completion;
@end
