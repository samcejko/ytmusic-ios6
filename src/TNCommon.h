// Shared macros and constants. Everything here must be iOS 6.0 safe.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Any API newer than the iOS 6.0 deployment target is a hard error in files that include this header.
#pragma clang diagnostic error "-Wunguarded-availability"

#define L(key) NSLocalizedString((key), nil)
#define TNIsPad() (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
#define TNLog(fmt, ...) NSLog((@"[Muzika] " fmt), ##__VA_ARGS__)

// Runs a block on the main thread (immediately if already there).
static inline void TNMain(dispatch_block_t block)
{
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

extern NSString * const TNErrorDomain;
extern NSString * const TNThemeDidChangeNotification;
extern NSString * const TNSettingsDidChangeNotification;
extern NSString * const TNLibraryDidChangeNotification;     // liked songs, saved albums, artists or playlists changed
extern NSString * const TNAppleDidChangeNotification;       // the Apple Music connection or its synced playlists changed
extern NSString * const TNMatchDidChangeNotification;       // songs of Apple Music were matched to YouTube (userInfo[@"key"])

// NSError codes in TNErrorDomain (HTTP errors use the HTTP status as code)
enum {
    TNErrorNetwork        = -1,
    TNErrorTLS            = -2,
    TNErrorCertificate    = -3,
    TNErrorTimeout        = -4,
    TNErrorCancelled      = -5,
    TNErrorBadResponse    = -6,
    TNErrorDNS            = -7,
    TNErrorConnect        = -8,
    TNErrorConnectionLost = -9,
    TNErrorAPI            = -10,   // YouTube or Apple answered, but with an error
    TNErrorNotConnected   = -11,   // Apple Music is not connected yet
    TNErrorAuth           = -12,   // Apple refused the token
    TNErrorRestricted     = -13,   // not available in this country, removed...
    TNErrorPlayback       = -14,   // the audio could not be fetched or decoded
    TNErrorNoMatch        = -15,   // no YouTube version of an Apple Music song was found
    TNErrorHelper         = -16,   // the audio helper is unreachable or broken (no song plays until it is back)
};

NSError *TNMakeError(NSInteger code, NSString *message);

// JSON values as the type the caller expects, nil/0 for anything else (NSNull, wrong type)
NSString *TNStr(id value);         // numbers become their decimal string
NSDictionary *TNDict(id value);
NSArray *TNArr(id value);
NSInteger TNInt(id value);
double TNDbl(id value);
BOOL TNBool(id value);

// "2026-10-02T17:31:00Z" and "2026-10-02T17:31:05.042684Z"
NSDate *TNDateFromISO(NSString *string);
