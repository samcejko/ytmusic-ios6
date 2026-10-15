#import "TNAudioFile.h"
#import "TNHTTPRequest.h"
#import "TNSettings.h"
#import "TNCommon.h"

static const NSUInteger TNMaxAudioFile = 64 * 1024 * 1024;

@interface TNAudioFile ()
@property (atomic) NSUInteger length;
@property (atomic) NSUInteger available;
@property (atomic) BOOL finished;
@property (atomic, strong) NSError *error;
@property (atomic) NSInteger lastStatus;
@end

@implementation TNAudioFile {
    NSString *_url;
    uint8_t *_buffer;
    NSCondition *_condition;
    BOOL _cancelled;
    TNHTTPRequest *_request;
}

- (instancetype)initWithURL:(NSString *)url
{
    if ((self = [super init])) {
        _url = [url copy];
        _condition = [[NSCondition alloc] init];
    }
    return self;
}

- (void)dealloc
{
    free(_buffer);
}

- (const uint8_t *)bytes { return _buffer; }

- (void)start
{
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(download) object:nil];
    t.name = @"TNAudioFile";
    [t start];
}

- (void)cancel
{
    [_condition lock];
    _cancelled = YES;
    TNHTTPRequest *r = _request;
    [_condition broadcast];
    [_condition unlock];
    [r cancel];
}

- (BOOL)waitForBytes:(NSUInteger)end timeout:(NSTimeInterval)timeout
{
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    [_condition lock];
    while (self.available < end && !self.finished && !_cancelled) {
        if (![_condition waitUntilDate:until]) break;
    }
    BOOL ok = self.available >= end;
    [_condition unlock];
    return ok;
}

- (void)finishWithError:(NSError *)error
{
    [_condition lock];
    self.error = error;
    self.finished = YES;
    [_condition broadcast];
    [_condition unlock];
}

- (void)download
{
    NSError *last = nil;
    NSString *url = _url;
    int hops = 0;
    for (int attempt = 0; attempt < 6 && !_cancelled; attempt++) {
        NSString *redirect = nil;
        NSError *error = nil;
        BOOL complete = NO;
        @autoreleasepool {
            complete = [self fetchFrom:url redirect:&redirect error:&error];
            if (error) last = error;   // (kept outside the pool: it would be released with it)
        }
        if (complete) { [self finishWithError:nil]; return; }
        if (_cancelled) break;
        if (redirect.length && hops < 6) {
            // googlevideo hands the request on to a nearer server: no attempt used up
            url = redirect;
            hops++;
            attempt--;
            continue;
        }
        if (self.lastStatus == 403 || self.lastStatus == 404 || self.lastStatus == 410) break;   // (the address is no good any more)
        TNLog(@"audio download broke off at %lu of %lu: %@", (unsigned long)self.available, (unsigned long)self.length, last.localizedDescription);
        usleep(400000);
    }
    [self finishWithError:_cancelled ? TNMakeError(TNErrorCancelled, L(@"Cancelled")) : (last ?: TNMakeError(TNErrorPlayback, L(@"The song could not be downloaded.")))];
}

// One request from where the file stands; YES when the file is complete. A redirect hands back its address.
- (BOOL)fetchFrom:(NSString *)urlString redirect:(NSString **)redirect error:(NSError **)error
{
    NSUInteger offset = self.available;
    if (self.length && offset >= self.length) return YES;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url.host.length) {
        if (error) *error = TNMakeError(TNErrorPlayback, L(@"The song's address is not valid."));
        return NO;
    }
    TNHTTPRequest *r = [[TNHTTPRequest alloc] initWithMethod:@"GET" URL:url];
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:@{ @"Accept": @"*/*" }];
    headers[@"Range"] = [NSString stringWithFormat:@"bytes=%lu-", (unsigned long)offset];
    r.headers = headers;
    r.verifyTLS = [TNSettings verifyTLS];
    r.noCompression = YES;
    r.highPriority = YES;
    r.connectTimeout = 15;
    r.readTimeout = 20;
    __block NSInteger status = 0;
    __block BOOL bad = NO;
    __block NSString *location = nil;
    __weak TNAudioFile *weakSelf = self;
    __weak TNHTTPRequest *weakRequest = r;
    r.onHeaders = ^(NSInteger s, NSDictionary *h) {
        TNAudioFile *me = weakSelf;
        status = s;
        me.lastStatus = s;
        if (s >= 300 && s < 400) { location = h[@"location"]; bad = YES; [weakRequest cancel]; return; }
        if (!me || (s != 200 && s != 206)) { bad = YES; [weakRequest cancel]; return; }
        if (s == 200 && offset) { bad = YES; [weakRequest cancel]; return; }   // (the range was ignored)
        NSUInteger total = 0;
        NSString *range = h[@"content-range"];   // "bytes 1000-9999/10000"
        NSRange slash = [range rangeOfString:@"/"];
        if (slash.location != NSNotFound) total = (NSUInteger)[[range substringFromIndex:slash.location + 1] longLongValue];
        if (!total) total = (NSUInteger)[h[@"content-length"] longLongValue] + offset;
        [me prepareForLength:total];
        if (![me bytes]) { bad = YES; [weakRequest cancel]; }
    };
    r.onData = ^(NSData *chunk) {
        TNAudioFile *me = weakSelf;
        if (!me || bad || me->_cancelled) { [weakRequest cancel]; return; }
        [me appendChunk:chunk];
    };
    __block NSError *failure = nil;
    r.onComplete = ^(NSError *e) { failure = e; };
    [_condition lock];
    if (_cancelled) { [_condition unlock]; return NO; }
    _request = r;
    [_condition unlock];
    [r runSynchronously];
    [_condition lock];
    _request = nil;
    [_condition unlock];
    if (self.length && self.available >= self.length) return YES;
    if (location.length) {
        NSURL *next = [[NSURL URLWithString:location relativeToURL:url] absoluteURL];
        if (redirect) *redirect = next.absoluteString;
        return NO;
    }
    if (error) *error = (status >= 400 || bad) && status ? TNMakeError(status, [NSString stringWithFormat:L(@"The song's server answered HTTP %ld."), (long)status])
                                                          : (failure ?: TNMakeError(TNErrorConnectionLost, L(@"The download broke off.")));
    return NO;
}

- (void)prepareForLength:(NSUInteger)total
{
    [_condition lock];
    if (!_buffer && total > 0 && total <= TNMaxAudioFile) {
        _buffer = malloc(total);
        self.length = total;
    }
    [_condition unlock];
}

- (void)appendChunk:(NSData *)chunk
{
    NSUInteger at = self.available;
    NSUInteger n = chunk.length;
    if (!_buffer || at + n > self.length) n = self.length > at ? self.length - at : 0;
    if (!n) return;
    memcpy(_buffer + at, chunk.bytes, n);
    [_condition lock];
    self.available = at + n;
    [_condition broadcast];
    [_condition unlock];
}

@end
