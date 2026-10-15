#import <Foundation/Foundation.h>

@class TNTrack;

extern NSString * const TNDownloadsDidChangeNotification;   // something finished, started or went (main thread)

// Songs kept on the device to play without the internet: the audio file as YouTube serves it (AAC in MP4), saved in
// Application Support/Muzika/downloads with what playback needs (the video it came from, its loudness). One download
// at a time, waiting while only mobile data is there when the user wants Wi-Fi only. Main thread only, except
// -localFileFor:, which any thread may ask.
@interface TNDownloads : NSObject

+ (instancetype)shared;

- (void)download:(NSArray *)tracks;
- (void)remove:(TNTrack *)track;
- (void)removeAll;
- (void)cancelPending;

- (BOOL)isDownloaded:(TNTrack *)track;
- (BOOL)isWaiting:(TNTrack *)track;              // in the queue or downloading now
- (NSArray *)downloadedTracks;                    // newest first
- (unsigned long long)bytesUsed;
@property (nonatomic, readonly) NSUInteger waitingCount;
@property (nonatomic, readonly) float progress;   // of the one downloading now
@property (nonatomic, readonly, copy) NSString *state;   // "Downloading 3 of 12", "Waiting for Wi-Fi"

// Any thread: @{path, videoId, loud (dB), itag, ms} of a downloaded song, nil when it is not
- (NSDictionary *)localFileFor:(TNTrack *)track;

@end
