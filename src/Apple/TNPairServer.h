#import <Foundation/Foundation.h>

// A tiny web page this device serves on the home Wi-Fi while the Apple Music screen is open: the user opens its
// address in a computer's browser and pastes the token there (typing 400 characters on the iPad is no fun). Nothing
// leaves the home network; the server stops when the screen closes.
@interface TNPairServer : NSObject

+ (instancetype)shared;
- (BOOL)startWithHandler:(void (^)(NSString *token))handler;   // the handler runs on the main thread
- (void)stop;
@property (nonatomic, readonly, copy) NSString *address;      // "http://192.168.1.176:8765/" (nil when not running)

@end
