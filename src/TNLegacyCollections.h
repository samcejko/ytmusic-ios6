#import <Foundation/Foundation.h>
static inline id TNLegacyDictionarySet(NSMutableDictionary *dictionary, id key, id value)
{
    if (value) [dictionary setObject:value forKey:key];
    else [dictionary removeObjectForKey:key];
    return value;
}
