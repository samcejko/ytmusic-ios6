#import <Foundation/Foundation.h>

@class TNTrack, TNAudioFile, TNAACDecoder;

// One song made ready to play: its YouTube twin found (Apple Music songs), its audio downloading, the decoder past
// the header
@interface TNPlaybackItem : NSObject
@property (nonatomic, strong) TNTrack *track;
@property (nonatomic, copy) NSString *videoId;            // what really plays (the match of an Apple Music song)
@property (nonatomic, strong) TNAudioFile *file;
@property (nonatomic, strong) TNAACDecoder *decoder;
@property (nonatomic) float gain;
@property (nonatomic) NSInteger durationMs;
@property (nonatomic, copy) NSString *formatName;        // "AAC 128 kbit/s"
// Loads a song (blocking, worker threads): the match, the audio address, the download, the header
+ (TNPlaybackItem *)loadTrack:(TNTrack *)track error:(NSError **)error;
// The same from a known audio address (the debug command, tests)
+ (TNPlaybackItem *)itemForTrack:(TNTrack *)track url:(NSString *)url durationMs:(NSInteger)durationMs error:(NSError **)error;
- (void)cancel;
@end

@protocol TNPlaybackEngineDelegate <NSObject>
- (void)engineDidStartItem:(TNPlaybackItem *)item;       // it is audible now (also the gapless next one)
- (void)engineDidFinishItem:(TNPlaybackItem *)item;      // played to the end and nothing followed
- (void)engineDidFailItem:(TNPlaybackItem *)item error:(NSError *)error;
- (void)engineNeedsNextItem;                             // the current song is almost all decoded: a good time to load the next
@end

// The decoding thread between the items and the speaker. Delegate calls come on the main thread.
@interface TNPlaybackEngine : NSObject

+ (instancetype)shared;
@property (nonatomic, weak) id<TNPlaybackEngineDelegate> delegate;

- (void)playItem:(TNPlaybackItem *)item fromMs:(NSInteger)startMs paused:(BOOL)paused;   // replaces whatever played
- (void)queueNextItem:(TNPlaybackItem *)item;            // follows without a gap
- (void)pause;
- (void)resume;
- (void)seekToMs:(NSInteger)ms;
- (void)stop;

@property (atomic, readonly, strong) TNPlaybackItem *currentItem;
@property (atomic, readonly, strong) TNPlaybackItem *nextItem;
@property (atomic, readonly) BOOL paused;
@property (atomic, readonly) BOOL buffering;
@property (nonatomic, readonly) NSInteger positionMs;    // of the current item
- (NSString *)debugState;

@end
