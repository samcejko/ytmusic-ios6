#import "TNSettings.h"
#import "TNKeychain.h"
#import "TNUtils.h"
#import "TNCommon.h"

#define DEF [NSUserDefaults standardUserDefaults]
static NSString * const TNAppleTokenKey = @"muzika.apple.mediaUserToken";
static const NSUInteger TNMaxRecentSearches = 12;

@implementation TNSettings

+ (void)registerDefaults
{
    [DEF registerDefaults:@{
        @"autoplay": @YES,
        @"allowVideosForApple": @YES,
        @"matchWholePlaylists": @YES,
        @"normalize": @YES,
        @"crossfade": @0,
        @"dataSaver": @YES,
        @"downloadWiFiOnly": @YES,
        @"syncAppleLikes": @YES,
        @"sidePanel": @YES,
        @"verifyTLS": @YES,
        @"recentSearches": @[],
    }];
}

+ (void)save { [DEF synchronize]; }

+ (void)notify
{
    TNMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName:TNSettingsDidChangeNotification object:nil]; });
}

#pragma mark - Playback

+ (BOOL)autoplay { return [DEF boolForKey:@"autoplay"]; }
+ (void)setAutoplay:(BOOL)value { [DEF setBool:value forKey:@"autoplay"]; [self notify]; }

+ (BOOL)allowVideosForApple { return [DEF boolForKey:@"allowVideosForApple"]; }
+ (void)setAllowVideosForApple:(BOOL)value { [DEF setBool:value forKey:@"allowVideosForApple"]; [self notify]; }

+ (BOOL)matchWholePlaylists { return [DEF boolForKey:@"matchWholePlaylists"]; }
+ (void)setMatchWholePlaylists:(BOOL)value { [DEF setBool:value forKey:@"matchWholePlaylists"]; [self notify]; }

+ (BOOL)normalize { return [DEF boolForKey:@"normalize"]; }
+ (void)setNormalize:(BOOL)value { [DEF setBool:value forKey:@"normalize"]; [self notify]; }

+ (NSInteger)crossfadeSeconds { return MAX(0, MIN(12, [DEF integerForKey:@"crossfade"])); }
+ (void)setCrossfadeSeconds:(NSInteger)value { [DEF setInteger:MAX(0, MIN(12, value)) forKey:@"crossfade"]; [self notify]; }

+ (BOOL)dataSaver { return [DEF boolForKey:@"dataSaver"]; }
+ (void)setDataSaver:(BOOL)value { [DEF setBool:value forKey:@"dataSaver"]; [self notify]; }

+ (BOOL)downloadOnWiFiOnly { return [DEF boolForKey:@"downloadWiFiOnly"]; }
+ (void)setDownloadOnWiFiOnly:(BOOL)value { [DEF setBool:value forKey:@"downloadWiFiOnly"]; [self notify]; }

+ (BOOL)syncAppleLikes { return [DEF boolForKey:@"syncAppleLikes"]; }
+ (void)setSyncAppleLikes:(BOOL)value { [DEF setBool:value forKey:@"syncAppleLikes"]; [self notify]; }

+ (BOOL)sidePanel { return [DEF boolForKey:@"sidePanel"]; }
+ (void)setSidePanel:(BOOL)value { [DEF setBool:value forKey:@"sidePanel"]; [self notify]; }

#pragma mark - Apple Music

+ (NSString *)appleUserToken
{
    NSString *t = [TNKeychain stringForKey:TNAppleTokenKey];
    return t.length ? t : nil;
}

+ (void)setAppleUserToken:(NSString *)token
{
    [TNKeychain setString:token.length ? token : nil forKey:TNAppleTokenKey];
    [self notify];
}

+ (NSString *)appleStorefront
{
    NSString *s = [DEF stringForKey:@"appleStorefront"];
    if (s.length) return s;
    NSString *country = [[[NSLocale currentLocale] objectForKey:NSLocaleCountryCode] lowercaseString];
    return country.length == 2 ? country : @"us";
}

+ (void)setAppleStorefront:(NSString *)storefront
{
    if (storefront.length) [DEF setObject:[storefront lowercaseString] forKey:@"appleStorefront"];
    else [DEF removeObjectForKey:@"appleStorefront"];
}

+ (NSString *)appleDeveloperToken
{
    NSString *t = [DEF stringForKey:@"appleDeveloperToken"];
    NSDate *expires = [DEF objectForKey:@"appleDeveloperTokenExpires"];
    if (!t.length || ![expires isKindOfClass:[NSDate class]]) return nil;
    // (a day of margin: a token that ends during a long session is not worth the trouble)
    if ([expires timeIntervalSinceNow] < 24 * 3600) return nil;
    return t;
}

+ (void)setAppleDeveloperToken:(NSString *)token expires:(NSDate *)expires
{
    if (token.length && expires) {
        [DEF setObject:token forKey:@"appleDeveloperToken"];
        [DEF setObject:expires forKey:@"appleDeveloperTokenExpires"];
    } else {
        [DEF removeObjectForKey:@"appleDeveloperToken"];
        [DEF removeObjectForKey:@"appleDeveloperTokenExpires"];
    }
}

+ (NSDate *)appleLastSync
{
    id d = [DEF objectForKey:@"appleLastSync"];
    return [d isKindOfClass:[NSDate class]] ? d : nil;
}

+ (void)setAppleLastSync:(NSDate *)date
{
    if (date) [DEF setObject:date forKey:@"appleLastSync"];
    else [DEF removeObjectForKey:@"appleLastSync"];
}

#pragma mark - Network

+ (BOOL)verifyTLS { return [DEF boolForKey:@"verifyTLS"]; }
+ (void)setVerifyTLS:(BOOL)value { [DEF setBool:value forKey:@"verifyTLS"]; [self notify]; }

#pragma mark - Recent searches

+ (NSArray *)recentSearches { return TNArr([DEF objectForKey:@"recentSearches"]) ?: @[]; }

+ (void)addRecentSearch:(NSString *)query
{
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return;
    NSMutableArray *list = [[self recentSearches] mutableCopy];
    for (NSInteger i = (NSInteger)list.count - 1; i >= 0; i--) {
        if ([TNStr(list[(NSUInteger)i]) caseInsensitiveCompare:q] == NSOrderedSame) [list removeObjectAtIndex:(NSUInteger)i];
    }
    [list insertObject:q atIndex:0];
    while (list.count > TNMaxRecentSearches) [list removeLastObject];
    [DEF setObject:list forKey:@"recentSearches"];
}

+ (void)clearRecentSearches { [DEF setObject:@[] forKey:@"recentSearches"]; }

@end
