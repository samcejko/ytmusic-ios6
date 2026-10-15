#import "TNRouter.h"
#import "TNRootViewController.h"
#import "TNTrackListViewController.h"
#import "TNArtistViewController.h"
#import "TNBrowseViewController.h"
#import "TNMatchPickerViewController.h"
#import "TNAppleConnectViewController.h"
#import "TNPlaylistPickerViewController.h"
#import "TNAppleChartsViewController.h"
#import "TNDownloads.h"
#import "TNImport.h"
#import "TNSettings.h"
#import "TNModels.h"
#import "TNPlayer.h"
#import "TNLibrary.h"
#import "TNMatcher.h"
#import "TNYTMusic.h"
#import "TNAppleMusic.h"
#import "TNUtils.h"
#import "TNCommon.h"

@interface TNActionSheet () <UIActionSheetDelegate>
@property (nonatomic, strong) UIActionSheet *sheet;
@property (nonatomic, strong) NSMutableArray *actions;
@property (nonatomic, strong) TNActionSheet *keepAlive;
@end

@implementation TNActionSheet

static __weak TNActionSheet *TNShownSheet;

+ (BOOL)pressButtonTitled:(NSString *)title
{
    TNActionSheet *s = TNShownSheet;
    if (!s.sheet.visible) return NO;
    for (NSInteger i = 0; i < s.sheet.numberOfButtons; i++) {
        if (![[s.sheet buttonTitleAtIndex:i] isEqualToString:title]) continue;
        [s.sheet dismissWithClickedButtonIndex:i animated:NO];
        return YES;
    }
    return NO;
}

- (instancetype)initWithTitle:(NSString *)title
{
    if ((self = [super init])) {
        _sheet = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
        _sheet.actionSheetStyle = UIActionSheetStyleBlackTranslucent;
        _actions = [NSMutableArray array];
    }
    return self;
}

- (void)addButton:(NSString *)title action:(dispatch_block_t)action
{
    [self.sheet addButtonWithTitle:title];
    [self.actions addObject:[action copy] ?: [NSNull null]];
}

- (void)addDestructiveButton:(NSString *)title action:(dispatch_block_t)action
{
    self.sheet.destructiveButtonIndex = [self.sheet addButtonWithTitle:title];
    [self.actions addObject:[action copy] ?: [NSNull null]];
}

- (void)showFromView:(UIView *)view inController:(UIViewController *)controller
{
    self.sheet.cancelButtonIndex = [self.sheet addButtonWithTitle:L(@"Cancel")];
    [self.actions addObject:[NSNull null]];
    self.keepAlive = self;
    TNShownSheet = self;
    if (TNIsPad() && view.window) [self.sheet showFromRect:view.bounds inView:view animated:YES];
    else [self.sheet showInView:controller.view.window ?: controller.view];
}

- (void)actionSheet:(UIActionSheet *)sheet didDismissWithButtonIndex:(NSInteger)index
{
    if (index >= 0 && index < (NSInteger)self.actions.count) {
        id action = self.actions[(NSUInteger)index];
        if (action != [NSNull null]) ((dispatch_block_t)action)();
    }
    self.keepAlive = nil;
}

@end

// A UIAlertView with a text field and a block (keeps itself alive while it is up)
@interface TNPrompt : NSObject <UIAlertViewDelegate>
@property (nonatomic, copy) void (^completion)(NSString *text);
@property (nonatomic, strong) TNPrompt *keepAlive;
@end

@implementation TNPrompt

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex != alertView.cancelButtonIndex && self.completion) {
        self.completion([[alertView textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    }
    self.completion = nil;
    self.keepAlive = nil;
}

@end

@implementation TNRouter

+ (void)promptWithTitle:(NSString *)title message:(NSString *)message text:(NSString *)text placeholder:(NSString *)placeholder
                 button:(NSString *)button completion:(void (^)(NSString *))completion
{
    TNPrompt *prompt = [[TNPrompt alloc] init];
    prompt.completion = completion;
    prompt.keepAlive = prompt;
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:title message:message delegate:prompt cancelButtonTitle:L(@"Cancel") otherButtonTitles:button, nil];
    a.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *f = [a textFieldAtIndex:0];
    f.placeholder = placeholder;
    f.text = text;
    f.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    [a show];
}

+ (void)importLinkPrompt
{
    NSString *clip = [UIPasteboard generalPasteboard].string ?: @"";
    [self promptWithTitle:L(@"Import a link") message:L(@"A playlist or an album from Apple Music, Spotify or YouTube")   // (short: on iOS 6 a longer message beside the field turns into a cut-off scroll box)
                     text:[TNImport canImport:clip] ? clip : @"" placeholder:@"https://..." button:L(@"Import") completion:^(NSString *link) {
        if (!link.length) return;
        if (![TNImport canImport:link]) { [self toast:L(@"Muzika can import links of Apple Music, Spotify and YouTube playlists.")]; return; }
        [self importLink:link];
    }];
}

+ (void)importLink:(NSString *)link
{
    [self toast:L(@"Importing…")];
    [TNImport importLink:link completion:^(TNPlaylist *playlist, NSError *error) {
        if (!playlist) { [self toast:error.localizedDescription ?: L(@"The link could not be imported.")]; return; }
        [self openPlaylist:playlist];
    }];
}

+ (void)addTracksToPlaylist:(NSArray *)tracks
{
    if (!tracks.count) return;
    [[TNRootViewController shared] presentSheet:[[TNPlaylistPickerViewController alloc] initWithTracks:tracks]];
}

+ (void)downloadTracks:(NSArray *)tracks
{
    NSMutableArray *todo = [NSMutableArray array];
    TNDownloads *downloads = [TNDownloads shared];
    for (TNTrack *t in tracks) if (t.playable && ![downloads isDownloaded:t] && ![downloads isWaiting:t]) [todo addObject:t];
    if (!todo.count) { [self toast:L(@"Already downloaded")]; return; }
    [downloads download:todo];
    [self toast:todo.count == 1 ? L(@"Downloading…") : [NSString stringWithFormat:L(@"Downloading %lu songs…"), (unsigned long)todo.count]];
}

+ (void)showSleepTimerFromView:(UIView *)view inController:(UIViewController *)controller
{
    TNPlayer *player = [TNPlayer shared];
    NSString *title = L(@"Sleep timer");
    if (player.sleepAtEndOfSong) title = L(@"The music stops at the end of this song.");
    else if (player.sleepAt) title = [NSString stringWithFormat:L(@"The music stops in %@."), TNFormatDurationMs((NSInteger)([player.sleepAt timeIntervalSinceNow] * 1000))];
    TNActionSheet *sheet = [[TNActionSheet alloc] initWithTitle:title];
    for (NSNumber *n in @[ @5, @10, @15, @30, @45, @60, @90 ]) {
        NSInteger minutes = [n integerValue];
        [sheet addButton:[NSString stringWithFormat:L(@"%ld minutes"), (long)minutes] action:^{
            [player setSleepTimerMinutes:minutes];
            [self toast:[NSString stringWithFormat:L(@"The music stops in %ld minutes"), (long)minutes]];
        }];
    }
    [sheet addButton:L(@"End of this song") action:^{
        [player setSleepTimerMinutes:-1];
        [self toast:L(@"The music stops at the end of this song")];
    }];
    if (player.sleepAt || player.sleepAtEndOfSong) {
        [sheet addDestructiveButton:L(@"Turn the timer off") action:^{
            [player setSleepTimerMinutes:0];
            [self toast:L(@"Sleep timer off")];
        }];
    }
    [sheet showFromView:view inController:controller];
}

+ (void)push:(UIViewController *)controller
{
    [[TNRootViewController shared] pushViewController:controller];
}

+ (void)openAlbum:(TNAlbum *)album
{
    if (album.browseId.length) [self push:[[TNTrackListViewController alloc] initWithAlbum:album]];
}

+ (void)openArtist:(TNArtist *)artist
{
    if (artist.browseId.length) [self push:[[TNArtistViewController alloc] initWithArtist:artist]];
}

+ (void)openPlaylist:(TNPlaylist *)playlist
{
    if (playlist.playlistId.length || playlist.browseId.length) [self push:[[TNTrackListViewController alloc] initWithPlaylist:playlist]];
}

+ (void)openCategory:(TNCategory *)category
{
    if ([category.browseId isEqualToString:TNAppleChartsBrowseId]) { [self openBrowseId:category.browseId params:nil title:category.title]; return; }
    [self push:[[TNBrowseViewController alloc] initWithBrowseId:category.browseId params:category.params title:category.title]];
}

+ (void)openBrowseId:(NSString *)browseId params:(NSString *)params title:(NSString *)title
{
    if (!browseId.length) return;
    if ([browseId isEqualToString:TNAppleChartsBrowseId]) {
        [self push:[[TNAppleChartsViewController alloc] init]];
    } else if ([browseId hasPrefix:@"MPREb_"]) {
        TNAlbum *a = [[TNAlbum alloc] init];
        a.browseId = browseId;
        a.name = title;
        [self openAlbum:a];
    } else if ([browseId hasPrefix:@"UC"]) {
        TNArtist *a = [[TNArtist alloc] init];
        a.browseId = browseId;
        a.name = title;
        [self openArtist:a];
    } else if ([browseId hasPrefix:@"VL"]) {
        TNPlaylist *p = [[TNPlaylist alloc] init];
        p.browseId = browseId;
        p.playlistId = [TNYTMusic playlistIdFromBrowseId:browseId];
        p.name = title;
        [self openPlaylist:p];
    } else {
        [self push:[[TNBrowseViewController alloc] initWithBrowseId:browseId params:params title:title]];
    }
}

+ (void)openLikedSongs { [self push:[[TNTrackListViewController alloc] initLikedSongs]]; }
+ (void)openRecent { [self push:[[TNTrackListViewController alloc] initRecent]]; }

+ (void)playSingle:(TNTrack *)track
{
    if (!track.playable) { [self toast:L(@"This song is not available.")]; return; }
    TNPlayer *player = [TNPlayer shared];
    player.shuffle = NO;
    [player playTracks:@[ track ] startingAt:0 contextURI:track.videoId ?: [track key] contextName:track.name];
    // what follows is the song's radio, as in YouTube Music
    if (track.videoId.length) [player startRadioFor:track];
}

+ (void)openItem:(id)item
{
    if ([item isKindOfClass:[TNAlbum class]]) [self openAlbum:item];
    else if ([item isKindOfClass:[TNPlaylist class]]) [self openPlaylist:item];
    else if ([item isKindOfClass:[TNArtist class]]) [self openArtist:item];
    else if ([item isKindOfClass:[TNCategory class]]) [self openCategory:item];
    else if ([item isKindOfClass:[TNTrack class]]) {
        TNTrack *t = item;
        if ([[TNPlayer shared] isCurrent:t]) { [self showNowPlaying]; return; }
        [self playSingle:t];
    }
}

static NSString *TNQueryParam(NSString *url, NSString *name)
{
    NSRange q = [url rangeOfString:@"?"];
    if (q.location == NSNotFound) return nil;
    return [TNUtils parseQuery:[url substringFromIndex:q.location + 1]][name];
}

+ (BOOL)openURL:(NSString *)url
{
    NSString *u = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([TNImport isSpotifyLink:u]) {
        [self importLink:u];
        return YES;
    }
    if ([TNAppleMusic isAppleMusicLink:u]) {
        [self toast:L(@"Importing from Apple Music…")];
        [[TNAppleMusic shared] importLink:u completion:^(TNPlaylist *playlist, NSArray *tracks, NSError *error) {
            if (!playlist) { [self toast:error.localizedDescription ?: L(@"The link could not be imported.")]; return; }
            [[TNLibrary shared] setSaved:YES playlist:playlist];
            [self openPlaylist:playlist];
        }];
        return YES;
    }
    NSString *lower = [u lowercaseString];
    if ([lower rangeOfString:@"youtube.com/"].location == NSNotFound && [lower rangeOfString:@"youtu.be/"].location == NSNotFound) return NO;
    NSString *list = TNQueryParam(u, @"list");
    NSString *video = TNQueryParam(u, @"v");
    NSRange shortLink = [lower rangeOfString:@"youtu.be/"];
    if (!video.length && shortLink.location != NSNotFound) {
        video = [[[u substringFromIndex:shortLink.location + shortLink.length] componentsSeparatedByString:@"?"] firstObject];
    }
    if (video.length) {
        [TNYTMusic radioFor:video playlistId:list completion:^(TNWatchQueue *queue, NSError *error) {
            NSUInteger start = 0;
            for (NSUInteger i = 0; i < queue.tracks.count; i++) if ([((TNTrack *)queue.tracks[i]).videoId isEqualToString:video]) { start = i; break; }
            if (!queue.tracks.count) { [self toast:error.localizedDescription ?: L(@"This song cannot be played.")]; return; }
            [TNPlayer shared].shuffle = NO;
            [[TNPlayer shared] playTracks:queue.tracks startingAt:start contextURI:[@"radio:" stringByAppendingString:video] contextName:((TNTrack *)queue.tracks[start]).name];
        }];
        return YES;
    }
    if (list.length) {
        TNPlaylist *p = [[TNPlaylist alloc] init];
        p.playlistId = list;
        p.browseId = [@"VL" stringByAppendingString:list];
        [self openPlaylist:p];
        return YES;
    }
    for (NSString *marker in @[ @"/browse/", @"/channel/" ]) {
        NSRange r = [u rangeOfString:marker];
        if (r.location == NSNotFound) continue;
        NSString *bid = [[[u substringFromIndex:r.location + r.length] componentsSeparatedByString:@"?"] firstObject];
        [self openBrowseId:bid params:nil title:nil];
        return YES;
    }
    return NO;
}

+ (void)showNowPlaying
{
    [[TNRootViewController shared] presentNowPlaying];
}

+ (void)toast:(NSString *)text
{
    if (!text.length) return;
    [[TNRootViewController shared] showToast:text];
}

+ (void)toggleLike:(TNTrack *)track
{
    if (!track) return;
    TNLibrary *library = [TNLibrary shared];
    BOOL like = ![library isLiked:track];
    [library setLiked:like track:track];
    [self toast:like ? L(@"Added to Liked music") : L(@"Removed from Liked music")];
}

+ (void)chooseVideoForTrack:(TNTrack *)track
{
    if (!track) return;
    [[TNRootViewController shared] presentSheet:[[TNMatchPickerViewController alloc] initWithTrack:track]];
}

+ (void)showAppleConnect
{
    [[TNRootViewController shared] presentSheet:[[TNAppleConnectViewController alloc] init]];
}

+ (void)showActionsForTrack:(TNTrack *)track fromView:(UIView *)view inController:(UIViewController *)controller
{
    [self showActionsForTrack:track fromView:view inController:controller removeTitle:nil remove:nil];
}

+ (void)showActionsForTrack:(TNTrack *)track fromView:(UIView *)view inController:(UIViewController *)controller
                removeTitle:(NSString *)removeTitle remove:(dispatch_block_t)remove
{
    if (!track) return;
    TNActionSheet *sheet = [[TNActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"%@\n%@", track.name ?: @"", [track artistNames] ?: @""]];
    TNPlayer *player = [TNPlayer shared];
    if (track.playable) {
        [sheet addButton:L(@"Play next") action:^{ [player playNext:track]; [self toast:L(@"Plays next")]; }];
        [sheet addButton:L(@"Add to queue") action:^{ [player addToQueue:track]; [self toast:L(@"Added to queue")]; }];
    }
    BOOL liked = [[TNLibrary shared] isLiked:track];
    [sheet addButton:liked ? L(@"Remove from Liked music") : L(@"Add to Liked music") action:^{ [self toggleLike:track]; }];
    [sheet addButton:L(@"Add to playlist…") action:^{ [self addTracksToPlaylist:@[ track ]]; }];
    TNDownloads *downloads = [TNDownloads shared];
    if ([downloads isDownloaded:track]) {
        [sheet addButton:L(@"Remove download") action:^{ [downloads remove:track]; [self toast:L(@"Download removed")]; }];
    } else if (track.playable && ![downloads isWaiting:track]) {
        [sheet addButton:L(@"Download") action:^{ [self downloadTracks:@[ track ]]; }];
    }
    NSString *videoId = track.videoId ?: ([player isCurrent:track] ? player.currentVideoId : nil);
    if (videoId.length) [sheet addButton:L(@"Start radio") action:^{ [player startRadioFor:track]; [self toast:L(@"Starting radio…")]; }];
    if ([track isApple]) {
        [sheet addButton:L(@"Choose the YouTube version") action:^{ [self chooseVideoForTrack:track]; }];
    }
    if (track.album.browseId.length) [sheet addButton:L(@"Go to album") action:^{ [self openAlbum:track.album]; }];
    TNArtist *artist = nil;
    for (TNArtist *a in track.artists) if (a.browseId.length) { artist = a; break; }
    if (artist) [sheet addButton:L(@"Go to artist") action:^{ [self openArtist:artist]; }];
    if (videoId.length) {
        [sheet addButton:L(@"Copy link") action:^{
            [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"https://music.youtube.com/watch?v=%@", videoId];
            [self toast:L(@"Link copied")];
        }];
    }
    if (remove) [sheet addDestructiveButton:removeTitle action:remove];
    [sheet showFromView:view inController:controller];
}

@end
