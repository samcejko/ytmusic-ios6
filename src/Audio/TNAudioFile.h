#import <Foundation/Foundation.h>

// One audio file (a song's MP4 from YouTube's servers), downloaded into memory on a thread of its own. The decoder
// reads from it while the rest still comes; redirects are followed, a broken connection carries on where it stopped
// (Range).
@interface TNAudioFile : NSObject

- (instancetype)initWithURL:(NSString *)url;
- (instancetype)initWithLocalPath:(NSString *)path;   // a downloaded song
- (void)start;
- (void)cancel;

@property (atomic, readonly) NSUInteger length;       // the whole file (0 until the first answer)
@property (atomic, readonly) NSUInteger available;    // bytes from the start that are here
@property (atomic, readonly) BOOL finished;           // all here (or given up: see error)
@property (atomic, readonly, strong) NSError *error;
@property (atomic, readonly) NSInteger lastStatus;    // the HTTP status of the last answer (403: the address expired)

// The file's bytes; valid while this object lives, from the moment `length` is known
- (const uint8_t *)bytes;
// Waits until `end` bytes are here, the download finished or failed, or `timeout` passed; YES when they are here
- (BOOL)waitForBytes:(NSUInteger)end timeout:(NSTimeInterval)timeout;

@end
