#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class TNTrack;

typedef NS_ENUM(NSInteger, TNRepeatMode) {
    TNRepeatOff = 0,
    TNRepeatAll,
    TNRepeatOne,
};

extern NSString * const TNPlayerDidChangeNotification;      // the song, the state or the queue changed (main thread)
extern NSString * const TNPlayerDidFailNotification;        // userInfo[@"error"]: a song could not be played

// What plays: a context (an album, a playlist, the liked songs, an artist's top songs, a radio...) in its order or
// shuffled, the songs the user put in the queue first, repeat, and the radio of the last song when everything has
// played (autoplay). Talks to the engine, the lock screen and the remote controls. Main thread only.
@interface TNPlayer : NSObject

+ (instancetype)shared;

- (void)playTracks:(NSArray *)tracks startingAt:(NSUInteger)index contextURI:(NSString *)uri contextName:(NSString *)name;
- (void)playTracks:(NSArray *)tracks startingAt:(NSUInteger)index positionMs:(NSInteger)positionMs paused:(BOOL)paused
        contextURI:(NSString *)uri contextName:(NSString *)name;
- (void)playTracksShuffled:(NSArray *)tracks contextURI:(NSString *)uri contextName:(NSString *)name;
- (void)startRadioFor:(TNTrack *)track;            // the song, then YouTube Music's radio of it
- (void)addToQueue:(TNTrack *)track;
- (void)playNext:(TNTrack *)track;                 // first in the queue

- (void)play;
- (void)pause;
- (void)togglePlay;
- (void)next;
- (void)previous;
- (void)seekToMs:(NSInteger)ms;

@property (nonatomic, readonly) TNTrack *currentTrack;
@property (nonatomic, readonly, copy) NSString *currentVideoId;   // what plays (an Apple Music song: its YouTube twin)
@property (nonatomic, readonly) BOOL playing;      // meant to play (also while loading or buffering)
@property (nonatomic, readonly) BOOL loading;
@property (nonatomic, readonly) BOOL buffering;
@property (nonatomic, readonly) NSInteger positionMs;
@property (nonatomic, readonly) NSInteger durationMs;
@property (nonatomic, readonly, copy) NSString *contextURI;
@property (nonatomic, readonly, copy) NSString *contextName;
@property (nonatomic, readonly, copy) NSString *formatName;
@property (nonatomic) BOOL shuffle;
@property (nonatomic) TNRepeatMode repeat;

@property (nonatomic, readonly) NSArray *userQueue;        // TNTrack, "Next in queue"
- (NSArray *)upcomingTracks:(NSUInteger)max;               // "Next from <context>"
- (NSArray *)previousTracks:(NSUInteger)max;
- (void)removeFromQueueAtIndex:(NSUInteger)index;
- (void)clearQueue;
- (void)replaceQueue:(NSArray *)tracks;
@property (nonatomic, readonly) NSArray *contextTracks;    // the context in its own order
@property (nonatomic, readonly) NSInteger contextIndex;    // the current song's place in it (-1: from the queue / none)
- (BOOL)isCurrent:(TNTrack *)track;                        // the same song as the one playing
- (void)moveQueueItemFrom:(NSUInteger)from to:(NSUInteger)to;
- (void)moveUpcomingFrom:(NSUInteger)from to:(NSUInteger)to;   // indices as in -upcomingTracks:
- (void)removeUpcomingAtIndex:(NSUInteger)index;
- (void)playNextTracks:(NSArray *)tracks;                  // in their order, before the rest of the queue
- (void)addTracksToQueue:(NSArray *)tracks;

// The sleep timer: minutes from now (0: off, -1: at the end of this song)
- (void)setSleepTimerMinutes:(NSInteger)minutes;
@property (nonatomic, readonly) NSDate *sleepAt;
@property (nonatomic, readonly) BOOL sleepAtEndOfSong;

// The queue and the place in the song are kept between launches
- (void)saveState;
- (void)restoreState;
- (NSInteger)resumePositionMs;                             // a restored song that has not started again yet

- (void)handleRemoteEvent:(UIEvent *)event;              // from the app delegate
- (NSString *)debugState;
- (void)debugPlayURL:(NSString *)url durationMs:(NSInteger)durationMs;   // an audio file's address straight to the engine

@end
