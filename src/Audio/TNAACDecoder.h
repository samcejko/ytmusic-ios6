#import <Foundation/Foundation.h>

@class TNAudioFile;

// AAC from one of YouTube's audio files (fragmented MP4, the "DASH" kind: ftyp, moov, sidx, then moof/mdat pairs)
// while it is still downloading: the boxes are read here, the packets go through the system's AudioConverter.
// The same shape as Spot6's Vorbis decoder, so the playback engine drives it the same way.
@interface TNAACDecoder : NSObject

- (instancetype)initWithFile:(TNAudioFile *)file;
- (BOOL)open:(NSError **)error;                        // waits for the header boxes (blocking)

@property (nonatomic, readonly) int sampleRate;
@property (nonatomic, readonly) int channels;
@property (nonatomic, readonly) NSInteger bitrate;     // bits per second, as the file states it (0: unknown)
@property (nonatomic) uint64_t totalFrames;            // from the song's length

@property (nonatomic, readonly) uint64_t frame;        // where the next frames come from
@property (nonatomic, readonly) BOOL atEnd;            // everything decoded
@property (nonatomic, readonly) BOOL starved;          // the last read ran out of downloaded bytes

// Up to `maxFrames` frames as interleaved 16-bit stereo, multiplied by `gain`; fewer (even 0) when the download is
// behind (`starved`) or at the end (`atEnd`); -1 when the stream is broken
- (NSInteger)readFrames:(int16_t *)out max:(NSUInteger)maxFrames gain:(float)gain;
- (BOOL)seekToFrame:(uint64_t)target;                   // blocking while the bytes there download

@end
