#import "TNPairServer.h"
#import "TNUtils.h"
#import "TNCommon.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <unistd.h>
#include <errno.h>

@interface TNPairServer ()
@property (nonatomic, copy) NSString *address;
@property (nonatomic, copy) void (^handler)(NSString *token);
@end

@implementation TNPairServer {
    int _listener;
}

+ (instancetype)shared
{
    static TNPairServer *server;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ server = [[TNPairServer alloc] init]; });
    return server;
}

- (instancetype)init
{
    if ((self = [super init])) _listener = -1;
    return self;
}

// The Wi-Fi address (en0, else the first IPv4 address that is not the loopback)
static NSString *TNLocalAddress(void)
{
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    NSString *wifi = nil, *other = nil;
    for (struct ifaddrs *a = list; a; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET || !(a->ifa_flags & IFF_UP) || (a->ifa_flags & IFF_LOOPBACK)) continue;
        char buffer[INET_ADDRSTRLEN];
        const struct sockaddr_in *in = (const struct sockaddr_in *)a->ifa_addr;
        if (!inet_ntop(AF_INET, &in->sin_addr, buffer, sizeof(buffer))) continue;
        NSString *ip = [NSString stringWithUTF8String:buffer];
        if (strcmp(a->ifa_name, "en0") == 0) wifi = ip;
        else if (!other && strncmp(a->ifa_name, "pdp_ip", 6) != 0) other = ip;
    }
    freeifaddrs(list);
    return wifi ?: other;
}

- (BOOL)startWithHandler:(void (^)(NSString *))handler
{
    self.handler = handler;
    if (_listener >= 0) return YES;
    NSString *ip = TNLocalAddress();
    if (!ip) return NO;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    int port = 0;
    for (int p = 8765; p < 8775 && !port; p++) {
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_len = sizeof(addr);
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)p);
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) port = p;
    }
    if (!port || listen(fd, 4) != 0) { close(fd); return NO; }
    _listener = fd;
    self.address = [NSString stringWithFormat:@"http://%@:%d/", ip, port];
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(acceptLoop:) object:@(fd)];
    t.name = @"TNPairServer";
    [t start];
    TNLog(@"pair server at %@", self.address);
    return YES;
}

- (void)stop
{
    int fd = _listener;
    _listener = -1;
    self.address = nil;
    self.handler = nil;
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
}

- (void)acceptLoop:(NSNumber *)listener
{
    int fd = [listener intValue];
    while (YES) {
        @autoreleasepool {
            int client = accept(fd, NULL, NULL);
            if (client < 0) {
                if (errno == EINTR) continue;
                break;   // (the server was stopped)
            }
            struct timeval tv = { 10, 0 };
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            int yes = 1;
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            [self serve:client];
            close(client);
        }
    }
}

static NSString *TNHTML(NSString *s)
{
    NSString *t = [s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    t = [t stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    return [t stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
}

- (void)reply:(int)client status:(NSString *)status body:(NSString *)body
{
    NSData *b = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSString *head = [NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n",
                      status, (unsigned long)b.length];
    NSMutableData *all = [NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    [all appendData:b];
    const uint8_t *p = all.bytes;
    size_t left = all.length;
    while (left > 0) {
        ssize_t n = send(client, p, left, 0);
        if (n <= 0) break;
        p += n;
        left -= (size_t)n;
    }
}

- (NSString *)page:(NSString *)message
{
    NSString *style = @"body{font-family:Helvetica,Arial,sans-serif;background:#1e1f21;color:#eee;max-width:640px;margin:40px auto;padding:0 16px}"
                       "h1{color:#ff3b30;font-size:24px}ol{line-height:1.6;color:#ccc}code{background:#333;padding:1px 5px;border-radius:3px}"
                       "textarea{width:100%;height:140px;background:#111;color:#eee;border:1px solid #555;border-radius:6px;padding:8px;font-size:13px}"
                       "button{margin-top:12px;background:linear-gradient(#ff5a4e,#d92a20);color:#fff;border:1px solid #9d1a12;border-radius:16px;padding:9px 26px;font-weight:bold;font-size:15px}"
                       ".msg{background:#2e3a2e;border:1px solid #4a6;padding:10px;border-radius:6px}";
    NSString *steps = [NSString stringWithFormat:@"<ol><li>%@</li><li>%@</li><li>%@</li><li>%@</li></ol>",
                       TNHTML(L(@"Open music.apple.com in this browser and sign in.")),
                       TNHTML(L(@"Open the developer tools (F12) > Application (Chrome, Edge) or Storage (Firefox) > Cookies > https://music.apple.com.")),
                       TNHTML(L(@"Copy the value of the cookie media-user-token.")),
                       TNHTML(L(@"Paste it below and press Send."))];
    NSString *note = message.length ? [NSString stringWithFormat:@"<p class=msg>%@</p>", TNHTML(message)] : @"";
    return [NSString stringWithFormat:@"<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width'>"
            "<title>Muzika</title><style>%@</style></head><body><h1>Muzika · Apple Music</h1>%@<p>%@</p>%@"
            "<form method=post action=/token><textarea name=token placeholder='media-user-token'></textarea><br><button type=submit>%@</button></form>"
            "<p style='color:#888;font-size:12px'>%@</p></body></html>",
            style, note, TNHTML(L(@"Connect Muzika on your iPad or iPhone to your Apple Music library.")), steps, TNHTML(L(@"Send")),
            TNHTML(L(@"The token goes straight to your device on this network and is kept only there."))];
}

- (void)serve:(int)client
{
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[8192];
    NSUInteger headerEnd = 0, contentLength = 0;
    while (data.length < 256 * 1024) {
        ssize_t n = recv(client, buffer, sizeof(buffer), 0);
        if (n <= 0) break;
        [data appendBytes:buffer length:(NSUInteger)n];
        if (!headerEnd) {
            NSRange r = [data rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, data.length)];
            if (r.location == NSNotFound) continue;
            headerEnd = r.location + 4;
            NSString *head = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, r.location)] encoding:NSISOLatin1StringEncoding] ?: @"";
            for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
                if ([[line lowercaseString] hasPrefix:@"content-length:"]) contentLength = (NSUInteger)[[line substringFromIndex:15] integerValue];
            }
        }
        if (headerEnd && data.length >= headerEnd + contentLength) break;
    }
    if (!headerEnd) return;
    NSString *head = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, headerEnd)] encoding:NSISOLatin1StringEncoding] ?: @"";
    NSString *requestLine = [[head componentsSeparatedByString:@"\r\n"] firstObject];
    if ([requestLine hasPrefix:@"POST /token"]) {
        NSData *bodyData = data.length > headerEnd ? [data subdataWithRange:NSMakeRange(headerEnd, data.length - headerEnd)] : [NSData data];
        NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding] ?: @"";
        NSString *token = [[[TNUtils parseQuery:[body stringByReplacingOccurrencesOfString:@"+" withString:@" "]] objectForKey:@"token"]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (token.length) {
            void (^handler)(NSString *) = self.handler;
            if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(token); });
            [self reply:client status:@"200 OK" body:[self page:L(@"Received. Look at your device: it checks the token with Apple now.")]];
        } else {
            [self reply:client status:@"200 OK" body:[self page:L(@"Nothing was pasted.")]];
        }
        return;
    }
    if ([requestLine hasPrefix:@"GET / "] || [requestLine hasPrefix:@"GET /?"]) {
        [self reply:client status:@"200 OK" body:[self page:nil]];
        return;
    }
    [self reply:client status:@"404 Not Found" body:@"<html><body>Not found</body></html>"];
}

@end
