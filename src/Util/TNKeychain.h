#import <Foundation/Foundation.h>

// Small secrets (the Apple Music token) in the keychain, with a preferences fallback when the
// keychain refuses (no entitlement). Small strings only.
@interface TNKeychain : NSObject
+ (NSString *)stringForKey:(NSString *)key;
+ (void)setString:(NSString *)value forKey:(NSString *)key;
@end
