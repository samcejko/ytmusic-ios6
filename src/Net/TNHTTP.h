#import <Foundation/Foundation.h>

typedef void (^TNHTTPCompletion)(NSInteger status, NSData *body, NSDictionary *headers, NSError *error);
typedef void (^TNJSONCompletion)(id json, NSInteger status, NSError *error);

// A running request of TNHTTP. After -cancel the completion block is never called.
@interface TNHTTPTask : NSObject
@property (atomic, readonly) BOOL isCancelled;
@property (atomic, copy) dispatch_block_t cancelBlock;   // for chained requests: called by -cancel (once)
- (void)cancel;
@end

// Convenience layer over TNHTTPRequest for API calls: redirects are followed, GET requests are tried a second
// time after a network error, completion blocks run on the main thread.
@interface TNHTTP : NSObject

+ (TNHTTPTask *)request:(NSString *)method url:(NSString *)url headers:(NSDictionary *)headers body:(NSData *)body
                retries:(NSInteger)retries completion:(TNHTTPCompletion)completion;

+ (TNHTTPTask *)get:(NSString *)url headers:(NSDictionary *)headers completion:(TNHTTPCompletion)completion;

// JSON answers. `error` is set for network errors, for statuses >= 400 (code = the status, message from the body
// when it has one) and for bodies that are not JSON; `json` is passed even with an error when the body parsed.
+ (TNHTTPTask *)getJSON:(NSString *)url headers:(NSDictionary *)headers completion:(TNJSONCompletion)completion;
+ (TNHTTPTask *)postJSON:(NSString *)url headers:(NSDictionary *)headers object:(id)object retries:(NSInteger)retries
              completion:(TNJSONCompletion)completion;
+ (TNHTTPTask *)postForm:(NSString *)url fields:(NSDictionary *)fields completion:(TNJSONCompletion)completion;
+ (TNHTTPTask *)postForm:(NSString *)url headers:(NSDictionary *)headers fields:(NSDictionary *)fields completion:(TNJSONCompletion)completion;

@end
