#import "TNAppDelegate.h"
#import "TNRootViewController.h"
#import "TNExternalOpen.h"
#import "TNSearchViewController.h"
#import "TNNowPlayingViewController.h"
#import "TNRouter.h"
#import "TNYTMusic.h"
#import "TNAppleMusic.h"
#import "TNMatcher.h"
#import "TNLibrary.h"
#import "TNModels.h"
#import "TNPlayer.h"
#import "TNTLSSocket.h"
#import "TNImageLoader.h"
#import "TNSettings.h"
#import "TNTheme.h"
#import "TNUtils.h"
#import "TNModern.h"
#import "TNCommon.h"
#import <AVFoundation/AVFoundation.h>
#include <dlfcn.h>
#include <signal.h>
#include <mach/mach.h>

static BOOL TNButtonMatches(UIButton *button, NSString *text)
{
    for (NSString *name in @[ button.currentTitle ?: @"", button.accessibilityLabel ?: @"" ])
        if (name.length && [name rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static BOOL TNViewContainsText(UIView *view, NSString *text)
{
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *s = ((UILabel *)view).text;
        return s.length && [s rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound;
    }
    for (UIView *sub in view.subviews) { if ([sub isKindOfClass:[UIControl class]]) continue; if (TNViewContainsText(sub, text)) return YES; }
    return NO;
}

static BOOL TNPressView(UIView *v, NSString *text)
{
    if ([v isKindOfClass:[UIButton class]]) {
        if (!TNButtonMatches((UIButton *)v, text)) return NO;
        [(UIButton *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    if ([v isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *cell = (UITableViewCell *)v;
        if (!TNViewContainsText(cell, text)) return NO;
        UIView *table = cell.superview;
        while (table && ![table isKindOfClass:[UITableView class]]) table = table.superview;
        NSIndexPath *ip = [(UITableView *)table indexPathForCell:cell];
        id<UITableViewDelegate> delegate = [(UITableView *)table delegate];
        if (!ip || ![delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
        [delegate tableView:(UITableView *)table didSelectRowAtIndexPath:ip];
        return YES;
    }
    // (a control without a label must not match: a message to nil answers location 0)
    if ([v isKindOfClass:[UIControl class]] && (v.accessibilityLabel.length || TNViewContainsText(v, text))) {
        BOOL match = v.accessibilityLabel.length ? [v.accessibilityLabel rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound : YES;
        if (!match) return NO;
        [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    return NO;
}

@implementation TNAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    signal(SIGPIPE, SIG_IGN);
    [TNSettings registerDefaults];
    TNLog(@"Muzika %@ starting on %@ (iOS %@)", [TNUtils appVersion], [TNUtils deviceModel], [UIDevice currentDevice].systemVersion);
    [TNTLSSocket warmUp];
    [[TNImageLoader shared] pruneDisk];
    // iOS 7 and newer (the arm64 build): full-screen modals, rounded grouped tables; the look stays Muzika's own
    TNModernSetUpWithoutSkin();
    [[TNTheme shared] applyGlobalAppearance];

    // music goes on with the screen locked and the silent switch on
    NSError *audioError = nil;
    if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&audioError]) TNLog(@"audio session: %@", audioError);
    [[AVAudioSession sharedInstance] setActive:YES error:NULL];
    [application beginReceivingRemoteControlEvents];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[TNRootViewController alloc] init];
    self.window.backgroundColor = [UIColor blackColor];
    [self.window makeKeyAndVisible];
    [application setStatusBarStyle:UIStatusBarStyleBlackOpaque animated:NO];

    [TNLibrary shared];
    [[TNPlayer shared] restoreState];   // (the queue and the place in the song, as they were left)
    // the Apple Music library is synced once a day by itself
    NSDate *last = [TNSettings appleLastSync];
    if ([[TNAppleMusic shared] connected] && (!last || [last timeIntervalSinceNow] < -20 * 3600)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[TNAppleMusic shared] syncWithCompletion:nil];
        });
    }
    return YES;
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event { [[TNPlayer shared] handleRemoteEvent:event]; }

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    [TNSettings save];
    [[TNLibrary shared] saveNow];
    [[TNPlayer shared] saveState];
}

- (void)applicationWillTerminate:(UIApplication *)application { [[TNLibrary shared] saveNow]; [[TNPlayer shared] saveState]; }

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application { [[TNImageLoader shared] clearMemory]; }

#pragma mark - Links

// muzika:open?url=<music.youtube.com / youtube.com / music.apple.com link>, muzika:search?q=, and plain links.
// Debug commands (need Documents/debug): stats, screen, snapshot, press?title=/n=, back, lang?set=en|cs|system,
// section?name=, play?v=, player?cmd=pause|play|next|prev|seek&ms=|shuffle|repeat, nowplaying?panel=art|lyrics|queue,
// sync, ytm?ep=browse&id=&params= (the answer saved to tmp/ytm.json), rotate?o=landscape|portrait
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    NSString *s = url.absoluteString ?: @"";
    NSString *lower = [s lowercaseString];
    TNRootViewController *root = [TNRootViewController shared];
    if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]) return [TNRouter openURL:s];
    if (![lower hasPrefix:@"muzika:"]) return NO;
    NSString *target = [s substringFromIndex:@"muzika:".length];
    while ([target hasPrefix:@"/"]) target = [target substringFromIndex:1];
    NSString *query = nil;
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) { query = [target substringFromIndex:q.location + 1]; target = [target substringToIndex:q.location]; }
    NSDictionary *params = query.length ? [TNUtils parseQuery:query] : @{};
    if ([target isEqualToString:@"open"] && [params[@"url"] length]) { [TNRouter openURL:params[@"url"]]; return YES; }
    if ([target isEqualToString:@"search"]) {
        [root showSection:TNSectionSearch];
        UIViewController *search = root.contentNavigationController.viewControllers.firstObject;
        if ([params[@"q"] length] && [search isKindOfClass:[TNSearchViewController class]]) [(TNSearchViewController *)search searchFor:params[@"q"]];
        return YES;
    }

    BOOL debug = [[NSFileManager defaultManager] fileExistsAtPath:[[TNUtils documentsPath] stringByAppendingPathComponent:@"debug"]];
    if (!debug) return YES;
    UIViewController *top = [root topController];
    if ([target isEqualToString:@"stats"]) {
        struct task_basic_info info; mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
            TNLog(@"Memory: %.1f MB resident", info.resident_size / 1048576.0);
        TNLog(@"Top: %@, section %ld", NSStringFromClass([top class]), (long)root.section);
        TNLog(@"Player: %@", [[TNPlayer shared] debugState]);
        TNLog(@"Apple: %@", [[TNAppleMusic shared] debugState]);
        TNLog(@"Matcher: %lu matched, %lu waiting", (unsigned long)[[TNMatcher shared] matchCount], (unsigned long)[[TNMatcher shared] pendingCount]);
        return YES;
    }
    // link?url=<percent-encoded url>: what a tapped web link does (the browser chooser on iOS 6), for the tests
    if ([target isEqualToString:@"link"] && [params[@"url"] length]) {
        NSString *link = params[@"url"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [TNExternalOpen presentOpenInForURL:[NSURL URLWithString:link] from:[[TNRootViewController shared] topController] anchor:nil];
        });
        return YES;
    }
    if ([target isEqualToString:@"sync"]) {
        [[TNAppleMusic shared] syncWithCompletion:^(NSError *error) { TNLog(@"Sync: %@", error ? error.localizedDescription : @"done"); }];
        return YES;
    }
    // ytm?ep=browse&id=<browseId>[&params=] or ep=search&q=: one InnerTube call, the answer saved to tmp/ytm.json
    if ([target isEqualToString:@"ytm"]) {
        NSString *ep = params[@"ep"] ?: @"browse";
        NSMutableDictionary *body = [NSMutableDictionary dictionary];
        if (params[@"id"]) body[@"browseId"] = params[@"id"];
        if (params[@"params"]) body[@"params"] = params[@"params"];
        if (params[@"q"]) body[@"query"] = params[@"q"];
        if (params[@"v"]) body[@"videoId"] = params[@"v"];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *e = nil;
            NSDictionary *json = [TNYTMusic callSync:ep body:body error:&e];
            NSData *data = json ? [TNUtils JSONDataFromObject:json] : nil;
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ytm.json"];
            [data ?: [NSData data] writeToFile:path atomically:YES];
            TNLog(@"ytm %@: %lu bytes%@", ep, (unsigned long)data.length, e ? [@" " stringByAppendingString:e.localizedDescription] : @"");
        });
        return YES;
    }
    // lang?set=en|cs|system: the app's own language, for checking both (the device's stays); it applies from the next
    // launch, so the app quits
    if ([target isEqualToString:@"lang"]) {
        NSString *set = params[@"set"] ?: @"system";
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if ([set isEqualToString:@"system"]) [d removeObjectForKey:@"AppleLanguages"];
        else [d setObject:@[ set ] forKey:@"AppleLanguages"];
        [d synchronize];
        TNLog(@"Language %@ from the next launch: quitting", set);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        return YES;
    }
    if ([target isEqualToString:@"snapshot"] || [target isEqualToString:@"screen"]) {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
        BOOL ok = NO;
        if ([target isEqualToString:@"screen"]) {
            CGImageRef (*grab)(void) = (CGImageRef (*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
            CGImageRef shot = grab ? grab() : NULL;
            if (shot) { ok = [UIImagePNGRepresentation([UIImage imageWithCGImage:shot]) writeToFile:path atomically:YES]; CGImageRelease(shot); }
        } else {
            CGSize size = [UIScreen mainScreen].bounds.size;
            UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
            for (UIWindow *w in [UIApplication sharedApplication].windows) if (!w.hidden && w.alpha > 0) [w.layer renderInContext:UIGraphicsGetCurrentContext()];
            ok = [UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext()) writeToFile:path atomically:YES];
            UIGraphicsEndImageContext();
        }
        TNLog(@"%@ %@: %@", target, ok ? @"written" : @"failed", path);
        return YES;
    }
    if ([target isEqualToString:@"press"]) {
        NSString *byTitle = params[@"title"];
        NSInteger n = [params[@"n"] integerValue];
        // the screen on top first: a covered screen underneath can have a button with the same label
        NSMutableArray *views = [NSMutableArray array];
        UIView *topView = top.navigationController.view ?: top.view;
        if (topView) [views addObject:topView];
        for (UIWindow *w in [UIApplication sharedApplication].windows) [views addObject:w];
        BOOL pressed = NO;
        for (NSUInteger i = 0; i < views.count && !pressed; i++) {
            UIView *v = views[i];
            if (!byTitle.length && [v isKindOfClass:[UIActionSheet class]] && ((UIActionSheet *)v).visible) {
                UIActionSheet *sheet = (UIActionSheet *)v;
                if ([sheet.delegate respondsToSelector:@selector(actionSheet:clickedButtonAtIndex:)]) [sheet.delegate actionSheet:sheet clickedButtonAtIndex:n];
                [sheet dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (!byTitle.length && [v isKindOfClass:[UIAlertView class]] && ((UIAlertView *)v).visible) {
                UIAlertView *alert = (UIAlertView *)v;
                if ([alert.delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)]) [alert.delegate alertView:alert clickedButtonAtIndex:n];
                [alert dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (byTitle.length && !v.hidden && TNPressView(v, byTitle)) {
                pressed = YES;
            } else {
                [views addObjectsFromArray:v.subviews];
            }
        }
        TNLog(@"Press %@: %@", query ?: @"", pressed ? @"done" : @"nothing found");
        return YES;
    }
    if ([target isEqualToString:@"back"]) { [root goBack]; return YES; }
    if ([target isEqualToString:@"section"]) {
        NSDictionary *names = @{ @"home": @(TNSectionHome), @"explore": @(TNSectionExplore), @"search": @(TNSectionSearch), @"liked": @(TNSectionLiked),
                                 @"playlists": @(TNSectionPlaylists), @"albums": @(TNSectionAlbums), @"artists": @(TNSectionArtists),
                                 @"recent": @(TNSectionRecent), @"apple": @(TNSectionApple), @"settings": @(TNSectionSettings), @"library": @(TNSectionLibrary) };
        NSNumber *section = names[[params[@"name"] lowercaseString] ?: @""];
        if (section) [root showSection:(TNSection)[section integerValue]];
        TNLog(@"Section %@: %@", params[@"name"], section ? @"shown" : @"unknown");
        return YES;
    }

    // audiotest?url=<percent-encoded audio address>&ms=<length>: the file straight to the engine (the decoder on its own)
    if ([target isEqualToString:@"audiotest"] && [params[@"url"] length]) {
        [[TNPlayer shared] debugPlayURL:params[@"url"] durationMs:[params[@"ms"] integerValue]];
        return YES;
    }
    if ([target isEqualToString:@"play"] && [params[@"v"] length]) {
        [TNRouter openURL:[@"https://music.youtube.com/watch?v=" stringByAppendingString:params[@"v"]]];
        return YES;
    }
    if ([target isEqualToString:@"player"]) {
        TNPlayer *p = [TNPlayer shared];
        NSString *cmd = params[@"cmd"];
        if ([cmd isEqualToString:@"pause"]) [p pause];
        else if ([cmd isEqualToString:@"play"]) [p play];
        else if ([cmd isEqualToString:@"next"]) [p next];
        else if ([cmd isEqualToString:@"prev"]) [p previous];
        else if ([cmd isEqualToString:@"seek"]) [p seekToMs:[params[@"ms"] integerValue]];
        else if ([cmd isEqualToString:@"shuffle"]) p.shuffle = !p.shuffle;
        else if ([cmd isEqualToString:@"repeat"]) p.repeat = (TNRepeatMode)((p.repeat + 1) % 3);
        TNLog(@"Player %@: %@", cmd, [p debugState]);
        return YES;
    }
    if ([target isEqualToString:@"nowplaying"]) {
        NSString *panel = params[@"panel"];
        [root presentNowPlayingPanel:[panel isEqualToString:@"lyrics"] ? TNNowPlayingLyrics : [panel isEqualToString:@"queue"] ? TNNowPlayingQueue : TNNowPlayingArt];
        return YES;
    }
    if ([target isEqualToString:@"rotate"]) {
        // (debug only, for testing without turning the iPad: a private UIDevice method turns the interface)
        NSInteger o = [params[@"o"] isEqualToString:@"landscape"] ? UIInterfaceOrientationLandscapeLeft : UIInterfaceOrientationPortrait;
        SEL sel = NSSelectorFromString(@"setOrientation:");
        if ([[UIDevice currentDevice] respondsToSelector:sel]) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[UIDevice instanceMethodSignatureForSelector:sel]];
            inv.selector = sel;
            inv.target = [UIDevice currentDevice];
            [inv setArgument:&o atIndex:2];
            [inv invoke];
        }
        TNLog(@"Rotate to %@: interface now %ld", params[@"o"], (long)[UIApplication sharedApplication].statusBarOrientation);
        return YES;
    }
    return YES;
}

@end
