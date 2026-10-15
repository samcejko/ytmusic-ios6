#import "TNRouter.h"
#import "TNRootViewController.h"
#import "TNTrackListViewController.h"
#import "TNArtistViewController.h"
#import "TNBrowseViewController.h"
#import "TNMatchPickerViewController.h"
#import "TNAppleConnectViewController.h"
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

@implementation TNRouter

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
    [self push:[[TNBrowseViewController alloc] initWithBrowseId:category.browseId params:category.params title:category.title]];
}

+ (void)openBrowseId:(NSString *)browseId params:(NSString *)params title:(NSString *)title
{
    if (!browseId.length) return;
    if ([browseId hasPrefix:@"MPREb_"]) {
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
    if (!track) return;
    TNActionSheet *sheet = [[TNActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"%@\n%@", track.name ?: @"", [track artistNames] ?: @""]];
    TNPlayer *player = [TNPlayer shared];
    if (track.playable) {
        [sheet addButton:L(@"Play next") action:^{ [player playNext:track]; [self toast:L(@"Plays next")]; }];
        [sheet addButton:L(@"Add to queue") action:^{ [player addToQueue:track]; [self toast:L(@"Added to queue")]; }];
    }
    BOOL liked = [[TNLibrary shared] isLiked:track];
    [sheet addButton:liked ? L(@"Remove from Liked music") : L(@"Add to Liked music") action:^{ [self toggleLike:track]; }];
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
    [sheet showFromView:view inController:controller];
}

@end
