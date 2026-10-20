#import "TNTrackListViewController.h"
#import "TNCells.h"
#import "TNRouter.h"
#import "TNTheme.h"
#import "TNModels.h"
#import "TNYTMusic.h"
#import "TNAppleMusic.h"
#import "TNMatcher.h"
#import "TNLibrary.h"
#import "TNPlayer.h"
#import "TNSettings.h"
#import "TNImageLoader.h"
#import "TNUtils.h"
#import "TNExternalOpen.h"
#import "TNDownloads.h"
#import "TNCommon.h"

typedef NS_ENUM(NSInteger, TNListKind) { TNListAlbum, TNListPlaylist, TNListApple, TNListLiked, TNListRecent, TNListTracks, TNListOwn, TNListDownloads };

static NSString * const TNTrackCellId = @"track";
static const NSUInteger TNMaxPlaylistLength = 3000;

@interface TNTrackListViewController ()
@property (nonatomic) TNListKind kind;
@property (nonatomic, strong) TNAlbum *album;
@property (nonatomic, strong) TNPlaylist *playlist;
@property (nonatomic, copy) NSString *contextURI;
@property (nonatomic, copy) NSString *listTitle;
@property (nonatomic, strong) NSArray *tracks;
@property (nonatomic) NSUInteger generation;    // a newer load makes the answers of an older one go unused
@property (nonatomic, strong) TNHTTPTask *task;
@property (nonatomic) BOOL reloadScheduled;
// header
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) TNImageView *cover;
@property (nonatomic, strong) UILabel *typeLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UILabel *descriptionLabel;
@property (nonatomic, strong) UILabel *matchLabel;
@property (nonatomic, strong) NSArray *descriptionLinks;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic) BOOL mutating;
@property (nonatomic, copy) NSString *shownPlaying;
@end

@implementation TNTrackListViewController

- (instancetype)initWithKind:(TNListKind)kind
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _kind = kind;
        _tracks = @[];
    }
    return self;
}

- (instancetype)initWithAlbum:(TNAlbum *)album
{
    if ((self = [self initWithKind:TNListAlbum])) {
        _album = album;
        _contextURI = [@"album:" stringByAppendingString:album.browseId ?: @""];
        _listTitle = album.name;
    }
    return self;
}

- (instancetype)initWithPlaylist:(TNPlaylist *)playlist
{
    TNListKind kind = playlist.source == TNSourceApple ? TNListApple : playlist.source == TNSourceLocal ? TNListOwn : TNListPlaylist;
    if ((self = [self initWithKind:kind])) {
        _playlist = playlist;
        _contextURI = [playlist key];
        _listTitle = playlist.name;
    }
    return self;
}

- (instancetype)initLikedSongs
{
    if ((self = [self initWithKind:TNListLiked])) {
        _listTitle = L(@"Liked music");
        _contextURI = @"liked";
        self.refreshable = NO;
    }
    return self;
}

- (instancetype)initRecent
{
    if ((self = [self initWithKind:TNListRecent])) {
        _listTitle = L(@"Recently played");
        _contextURI = @"recent";
        self.refreshable = NO;
    }
    return self;
}

- (instancetype)initDownloads
{
    if ((self = [self initWithKind:TNListDownloads])) {
        _listTitle = L(@"Downloads");
        _contextURI = @"downloads";
        self.refreshable = NO;
    }
    return self;
}

- (instancetype)initWithTracks:(NSArray *)tracks title:(NSString *)title contextURI:(NSString *)uri
{
    if ((self = [self initWithKind:TNListTracks])) {
        _tracks = [tracks copy];
        _listTitle = title;
        _contextURI = uri;
        self.refreshable = NO;
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_task cancel];
}

#pragma mark - View

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.listTitle;
    self.tableView.rowHeight = 56;
    [self.tableView registerClass:[TNTrackCell class] forCellReuseIdentifier:TNTrackCellId];
    [self buildHeader];
    [self showHeader];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(libraryChanged) name:TNLibraryDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(matchesChanged) name:TNMatchDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(downloadsChanged) name:TNDownloadsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(playerChanged) name:TNPlayerDidChangeNotification object:nil];
}

// The red title of the song playing follows the player
- (void)playerChanged
{
    NSString *key = [[TNPlayer shared].currentTrack key];
    if ((key == self.shownPlaying || [key isEqualToString:self.shownPlaying]) || self.tableView.editing || self.mutating) return;
    self.shownPlaying = key;
    if (self.isViewLoaded && self.view.window) [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    NSString *key = [[TNPlayer shared].currentTrack key];
    if (!(key == self.shownPlaying || [key isEqualToString:self.shownPlaying]) && !self.tableView.editing) {
        self.shownPlaying = key;
        [self.tableView reloadData];
    }
}

- (void)libraryChanged
{
    if (self.tableView.editing || self.mutating) return;   // (the rows stay while they are moved)
    if (self.kind == TNListLiked || self.kind == TNListRecent || self.kind == TNListOwn) [self load];
    else [self showHeader];
}

- (void)downloadsChanged
{
    if (!self.isViewLoaded || self.tableView.editing || self.mutating) return;
    if (self.kind == TNListDownloads) { [self load]; return; }
    if (self.view.window) [self.tableView reloadData];
}

// New matches come one by one: the list is redrawn at most twice a second
- (void)matchesChanged
{
    if (self.reloadScheduled || !self.isViewLoaded) return;
    self.reloadScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.reloadScheduled = NO;
        [[TNMatcher shared] applyTo:self.tracks];
        if (self.view.window) [self.tableView reloadData];
        if (self.kind == TNListOwn && !self.playlist.thumbnails.count) [self showHeader];   // (the cover of the first song found)
        else [self showMatchState];
    });
}

- (UILabel *)headerLabel:(UIFont *)font color:(UIColor *)color
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.font = font;
    l.textColor = color;
    l.backgroundColor = [UIColor clearColor];
    [self.header addSubview:l];
    return l;
}

- (void)buildHeader
{
    TNTheme *theme = [TNTheme shared];
    self.header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 10)];
    self.header.backgroundColor = [UIColor clearColor];
    self.cover = [[TNImageView alloc] initWithFrame:CGRectZero];
    self.cover.contentMode = UIViewContentModeScaleAspectFill;
    self.cover.clipsToBounds = YES;
    [self.header addSubview:self.cover];
    self.typeLabel = [self headerLabel:[theme sectionFont] color:[theme secondaryTextColor]];
    self.titleLabel = [self headerLabel:[theme headerFont] color:[theme primaryTextColor]];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.6;
    self.infoLabel = [self headerLabel:[theme smallFont] color:[theme secondaryTextColor]];
    self.infoLabel.numberOfLines = 2;
    self.descriptionLabel = [self headerLabel:[theme smallFont] color:[theme tertiaryTextColor]];
    self.descriptionLabel.numberOfLines = 2;
    self.descriptionLabel.userInteractionEnabled = YES;
    [self.descriptionLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(descriptionTapped)]];
    self.matchLabel = [self headerLabel:[theme smallFont] color:[theme accentTextColor]];
    self.playButton = [theme accentButtonWithTitle:L(@"Play")];
    [self.playButton addTarget:self action:@selector(playAll) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:self.playButton];
    self.shuffleButton = [theme outlineButtonWithTitle:L(@"Shuffle")];
    [self.shuffleButton addTarget:self action:@selector(shuffleAll) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:self.shuffleButton];
    self.saveButton = [theme outlineButtonWithTitle:L(@"Save")];
    [self.saveButton addTarget:self action:@selector(toggleSaved) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:self.saveButton];
    self.moreButton = [theme outlineButtonWithTitle:@""];
    [self.moreButton setImage:[theme icon:TNIconMore size:18 color:[theme primaryTextColor]] forState:UIControlStateNormal];
    self.moreButton.accessibilityLabel = L(@"More");
    [self.moreButton addTarget:self action:@selector(listActions) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:self.moreButton];
}

- (void)descriptionTapped
{
    [TNExternalOpen presentLinkChooserForURLs:self.descriptionLinks from:self anchor:self.descriptionLabel];
}

- (NSString *)imageURL
{
    switch (self.kind) {
        case TNListAlbum: return [self.album imageURLForSize:400];
        case TNListPlaylist:
        case TNListApple:
        case TNListOwn: {
            NSString *own = [self.playlist imageURLForSize:400];
            if (own) return own;
            for (TNTrack *t in self.tracks) { NSString *u = [t imageURLForSize:400]; if (u) return u; }   // (songs still being looked up have none)
            return nil;
        }
        default: return [(TNTrack *)self.tracks.firstObject imageURLForSize:400];
    }
}

- (void)showHeader
{
    TNTheme *theme = [TNTheme shared];
    NSString *type = @"", *info = @"", *description = nil;
    BOOL canSave = NO, saved = NO;
    switch (self.kind) {
        case TNListAlbum: {
            type = self.album.kind.length ? self.album.kind : L(@"Album");
            NSMutableArray *bits = [NSMutableArray array];
            if ([self.album artistNames].length) [bits addObject:[self.album artistNames]];
            if (self.album.year.length) [bits addObject:self.album.year];
            if (self.album.info.length) [bits addObject:self.album.info];
            else if (self.tracks.count) [bits addObject:[NSString stringWithFormat:L(@"%lu songs"), (unsigned long)self.tracks.count]];
            info = [bits componentsJoinedByString:@" • "];
            description = self.album.descriptionText;
            canSave = YES;
            saved = [[TNLibrary shared] isSavedAlbum:self.album];
            break;
        }
        case TNListPlaylist: {
            type = L(@"Playlist");
            NSMutableArray *bits = [NSMutableArray array];
            if (self.playlist.author.length) [bits addObject:self.playlist.author];
            if (self.playlist.info.length) [bits addObject:self.playlist.info];
            else if (self.tracks.count) [bits addObject:[NSString stringWithFormat:L(@"%lu songs"), (unsigned long)self.tracks.count]];
            info = [bits componentsJoinedByString:@" • "];
            description = self.playlist.descriptionText;
            canSave = YES;
            saved = [[TNLibrary shared] isSavedPlaylist:self.playlist];
            break;
        }
        case TNListApple: {
            type = [self.playlist.playlistId hasPrefix:@"album:"] || [self.playlist.playlistId hasPrefix:@"libalbum:"] ? L(@"Apple Music album") : L(@"Apple Music playlist");
            NSMutableArray *bits = [NSMutableArray array];
            if (self.playlist.author.length) [bits addObject:self.playlist.author];
            NSUInteger n = self.tracks.count ?: (NSUInteger)self.playlist.trackCount;
            if (n) [bits addObject:[NSString stringWithFormat:L(@"%lu songs"), (unsigned long)n]];
            info = [bits componentsJoinedByString:@" • "];
            description = self.playlist.descriptionText;
            canSave = !self.playlist.fromLibrary;
            saved = [[TNLibrary shared] isSavedPlaylist:self.playlist];
            break;
        }
        case TNListOwn: {
            type = L(@"Your playlist");
            NSMutableArray *bits = [NSMutableArray array];
            if (self.playlist.author.length) [bits addObject:self.playlist.author];
            [bits addObject:[NSString stringWithFormat:L(@"%lu songs"), (unsigned long)self.tracks.count]];
            info = [bits componentsJoinedByString:@" • "];
            description = self.playlist.descriptionText;
            break;
        }
        case TNListDownloads: {
            TNDownloads *downloads = [TNDownloads shared];
            info = [NSString stringWithFormat:L(@"%lu songs • %@"), (unsigned long)self.tracks.count, [TNUtils formatFileSize:[downloads bytesUsed]]];
            if (downloads.waitingCount) description = downloads.state;
            break;
        }
        case TNListLiked:
        case TNListRecent:
        case TNListTracks:
            info = [NSString stringWithFormat:L(@"%lu songs"), (unsigned long)self.tracks.count];
            break;
    }
    self.typeLabel.text = [type uppercaseString];
    self.titleLabel.text = [TNUtils displayText:self.listTitle];
    self.infoLabel.text = [TNUtils displayText:info];
    self.descriptionLabel.text = [TNUtils displayText:[description stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
    self.descriptionLinks = [TNExternalOpen linksInText:description];
    if (self.kind == TNListLiked) self.cover.image = [self badgeArtwork:TNIconThumbUpFilled];
    else if (self.kind == TNListRecent) self.cover.image = [self badgeArtwork:TNIconClock];
    else if (self.kind == TNListDownloads) self.cover.image = [self badgeArtwork:TNIconDownload];
    else {
        NSString *url = [self imageURL];
        [self.cover setImageURL:url placeholder:[theme artPlaceholderWithSize:160]];
        if (!url && self.kind == TNListApple) self.cover.image = [theme appleMarkWithSize:160];
    }
    self.saveButton.hidden = !canSave;
    [self.saveButton setTitle:[(saved ? L(@"Saved") : L(@"Save")) uppercaseString] forState:UIControlStateNormal];
    self.title = self.listTitle;
    [self showMatchState];
    if (self.kind == TNListApple) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshFromApple)];
    }
    [self layoutHeader];
}

// How many songs of an Apple playlist have their YouTube twin
- (void)showMatchState
{
    NSUInteger apple = 0, matched = 0, failed = 0;
    for (TNTrack *t in self.tracks) {
        if (![t isApple]) continue;
        apple++;
        if (t.videoId.length) matched++;
        else if (t.matchFailed) failed++;
    }
    NSString *text = nil;
    if (apple) {
        NSUInteger pending = apple - matched - failed;
        if (pending && [[TNMatcher shared] pendingCount]) text = [NSString stringWithFormat:L(@"Finding on YouTube: %lu of %lu"), (unsigned long)(matched + failed), (unsigned long)apple];
        else if (failed) text = [NSString stringWithFormat:L(@"On YouTube: %lu of %lu (%lu not found)"), (unsigned long)matched, (unsigned long)apple, (unsigned long)failed];
        else if (pending) text = [NSString stringWithFormat:L(@"On YouTube: %lu of %lu (the rest is looked up when it plays)"), (unsigned long)matched, (unsigned long)apple];
        else text = [NSString stringWithFormat:L(@"All %lu songs found on YouTube"), (unsigned long)apple];
    }
    if ((self.matchLabel.text.length > 0) != (text.length > 0)) {
        self.matchLabel.text = text;
        [self layoutHeader];
    } else {
        self.matchLabel.text = text;
    }
}

- (UIImage *)badgeArtwork:(TNIcon)icon
{
    TNTheme *theme = [TNTheme shared];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(160, 160), YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[ (id)[UIColor colorWithRed:0.85 green:0.12 blue:0.1 alpha:1].CGColor, (id)[UIColor colorWithRed:0.35 green:0.05 blue:0.2 alpha:1].CGColor ];
    CGGradientRef g = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, 0), CGPointMake(160, 160), 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(space);
    [[UIColor colorWithWhite:1 alpha:0.12] setFill];
    UIRectFill(CGRectMake(0, 0, 160, 80));
    [[theme icon:icon size:64] drawAtPoint:CGPointMake(48, 48)];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)layoutHeader
{
    CGFloat w = self.tableView.bounds.size.width;
    BOOL wide = w > 500;
    CGFloat art = wide ? 180 : 120, pad = wide ? 24 : 14;
    self.cover.frame = CGRectMake(pad, pad, art, art);
    CGFloat x = pad + art + 18, textW = w - x - pad;
    CGFloat y = pad + (wide ? 8 : 0);
    self.typeLabel.frame = CGRectMake(x, y, textW, 16);
    y += 18;
    CGSize t = [self.titleLabel.text ?: @"" sizeWithFont:self.titleLabel.font constrainedToSize:CGSizeMake(textW, wide ? 72 : 54) lineBreakMode:NSLineBreakByTruncatingTail];
    self.titleLabel.frame = CGRectMake(x, y, textW, MAX(ceilf(t.height), 26));
    y += MAX(ceilf(t.height), 26) + 4;
    self.infoLabel.frame = CGRectMake(x, y, textW, 34);
    [self.infoLabel sizeToFit];
    CGRect f = self.infoLabel.frame;
    f.size.width = textW;
    self.infoLabel.frame = f;
    y += f.size.height + 4;
    if (self.matchLabel.text.length) {
        self.matchLabel.frame = CGRectMake(x, y, textW, 17);
        y += 19;
    } else {
        self.matchLabel.frame = CGRectZero;
    }
    if (self.descriptionLabel.text.length) {
        self.descriptionLabel.frame = CGRectMake(x, y, textW, 34);
        y += 36;
    } else {
        self.descriptionLabel.frame = CGRectZero;
    }
    CGFloat by = MAX(y + 8, pad + art - 32);
    CGFloat bx = wide ? x : pad;
    if (!wide) by = MAX(pad + art + 14, y + 8);
    TNTheme *theme = [TNTheme shared];
    CGFloat pw = [theme widthForButton:self.playButton minimum:100], sw = [theme widthForButton:self.shuffleButton minimum:100];
    self.playButton.frame = CGRectMake(bx, by, pw, 32);
    self.shuffleButton.frame = CGRectMake(bx + pw + 10, by, sw, 32);
    CGFloat mx = bx + pw + sw + 20;
    if (!self.saveButton.hidden) {
        CGFloat vw = [theme widthForButton:self.saveButton minimum:100];
        self.saveButton.frame = CGRectMake(mx, by, vw, 32);
        mx += vw + 10;
    }
    self.moreButton.frame = CGRectMake(mx, by, 44, 32);
    CGFloat height = MAX(by + 32, pad + art) + pad;
    self.header.frame = CGRectMake(0, 0, w, height);
    self.tableView.tableHeaderView = self.header;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (fabs(self.header.bounds.size.width - self.tableView.bounds.size.width) > 1) [self layoutHeader];
}

#pragma mark - Loading

- (void)setTracksAndMatch:(NSArray *)tracks
{
    self.tracks = tracks ?: @[];
    [[TNMatcher shared] applyTo:self.tracks];
    if (self.kind == TNListApple && [TNSettings matchWholePlaylists]) [[TNMatcher shared] matchTracks:self.tracks];
}

- (void)load
{
    [self.task cancel];
    self.task = nil;
    NSUInteger generation = ++self.generation;
    __weak TNTrackListViewController *weakSelf = self;
    switch (self.kind) {
        case TNListTracks:
            [self setTracksAndMatch:self.tracks];
            [self finishLoadingWithError:nil empty:!self.tracks.count emptyMessage:L(@"Nothing here.")];
            [self showHeader];
            return;
        case TNListLiked:
            [self setTracksAndMatch:[[TNLibrary shared] likedSongs]];
            [self finishLoadingWithError:nil empty:!self.tracks.count emptyMessage:L(@"Songs you like show up here. Tap the thumb.")];
            [self showHeader];
            return;
        case TNListRecent:
            [self setTracksAndMatch:[[TNLibrary shared] recentTracks]];
            [self finishLoadingWithError:nil empty:!self.tracks.count emptyMessage:L(@"Songs you play show up here.")];
            [self showHeader];
            return;
        case TNListOwn:
            [self setTracksAndMatch:[[TNLibrary shared] tracksOfPlaylist:self.playlist]];
            [self finishLoadingWithError:nil empty:!self.tracks.count emptyMessage:L(@"Add songs with \"Add to playlist…\" in a song's menu.")];
            [self showHeader];
            return;
        case TNListDownloads:
            [self setTracksAndMatch:[[TNDownloads shared] downloadedTracks]];
            [self finishLoadingWithError:nil empty:!self.tracks.count emptyMessage:[TNDownloads shared].waitingCount ? [TNDownloads shared].state : L(@"Songs you download play without the internet. Download them from a song's menu or a whole album or playlist with its \"…\" button.")];
            [self showHeader];
            return;
        case TNListApple: {
            NSArray *cached = [[TNLibrary shared] tracksOfPlaylist:self.playlist];
            if (cached && !self.refreshing) {
                [self setTracksAndMatch:cached];
                [self finishLoadingWithError:nil empty:!self.tracks.count emptyMessage:L(@"This playlist is empty.")];
                [self showHeader];
                return;
            }
            [self refreshFromApple];
            return;
        }
        case TNListAlbum: {
            [self startLoading];
            self.task = [TNYTMusic album:self.album.browseId completion:^(TNAlbum *album, NSArray *shelves, NSError *error) {
                TNTrackListViewController *me = weakSelf;
                if (!me || generation != me.generation) return;
                if (album.name.length) {
                    me.album = album;
                    me.listTitle = album.name;
                }
                me.tracks = album.tracks ?: @[];
                [me finishLoadingWithError:me.tracks.count ? nil : error empty:!me.tracks.count emptyMessage:L(@"Nothing here.")];
                [me showHeader];
            }];
            return;
        }
        case TNListPlaylist: {
            [self startLoading];
            NSString *browseId = self.playlist.browseId ?: self.playlist.playlistId;
            self.task = [TNYTMusic playlist:browseId completion:^(TNPlaylist *playlist, NSArray *tracks, NSString *continuation, NSError *error) {
                TNTrackListViewController *me = weakSelf;
                if (!me || generation != me.generation) return;
                if (playlist.name.length) {
                    if (!playlist.thumbnails.count) playlist.thumbnails = me.playlist.thumbnails;
                    me.playlist = playlist;
                    me.listTitle = playlist.name;
                }
                me.tracks = tracks ?: @[];
                [me finishLoadingWithError:me.tracks.count ? nil : error empty:!me.tracks.count emptyMessage:L(@"Nothing here.")];
                [me showHeader];
                if (continuation.length) [me loadMore:continuation generation:generation];
            }];
            return;
        }
    }
}

// The rest of a long playlist, page after page
- (void)loadMore:(NSString *)continuation generation:(NSUInteger)generation
{
    if (self.tracks.count >= TNMaxPlaylistLength) return;
    __weak TNTrackListViewController *weakSelf = self;
    self.task = [TNYTMusic playlistMore:continuation completion:^(NSArray *tracks, NSString *next, NSError *error) {
        TNTrackListViewController *me = weakSelf;
        if (!me || generation != me.generation || !tracks.count) return;
        me.tracks = [me.tracks arrayByAddingObjectsFromArray:tracks];
        [me.tableView reloadData];
        [me showHeader];
        if (next.length) [me loadMore:next generation:generation];
    }];
}

- (void)refreshFromApple
{
    if (!self.playlist) return;
    if (self.playlist.fromLibrary && ![[TNAppleMusic shared] connected]) {
        [self finishLoadingWithError:TNMakeError(TNErrorNotConnected, L(@"Apple Music is not connected.")) empty:!self.tracks.count emptyMessage:nil];
        return;
    }
    [self startLoading];
    NSUInteger generation = ++self.generation;
    __weak TNTrackListViewController *weakSelf = self;
    self.task = [[TNAppleMusic shared] tracksOf:self.playlist completion:^(NSArray *tracks, NSError *error) {
        TNTrackListViewController *me = weakSelf;
        if (!me || generation != me.generation) return;
        if (tracks) [me setTracksAndMatch:tracks];
        [me finishLoadingWithError:me.tracks.count ? nil : error empty:!me.tracks.count emptyMessage:L(@"This playlist is empty.")];
        [me showHeader];
        if (error && me.tracks.count) [TNRouter toast:error.localizedDescription];
    }];
}

#pragma mark - Actions

- (void)playAll
{
    if (!self.tracks.count) return;
    [TNPlayer shared].shuffle = NO;
    [[TNPlayer shared] playTracks:self.tracks startingAt:0 contextURI:self.contextURI contextName:self.listTitle];
}

- (void)shuffleAll
{
    [[TNPlayer shared] playTracksShuffled:self.tracks contextURI:self.contextURI contextName:self.listTitle];
}

// The "…" of the list: the whole list next or into the queue, into a playlist, downloaded; an own playlist is renamed,
// edited or deleted here
- (void)listActions
{
    NSArray *tracks = self.tracks;
    TNActionSheet *sheet = [[TNActionSheet alloc] initWithTitle:self.listTitle];
    TNPlayer *player = [TNPlayer shared];
    if (tracks.count) {
        [sheet addButton:L(@"Play next") action:^{ [player playNextTracks:tracks]; [TNRouter toast:L(@"Plays next")]; }];
        [sheet addButton:L(@"Add to queue") action:^{ [player addTracksToQueue:tracks]; [TNRouter toast:L(@"Added to queue")]; }];
        if (self.kind != TNListOwn) [sheet addButton:L(@"Add to playlist…") action:^{ [TNRouter addTracksToPlaylist:tracks]; }];
    }
    TNDownloads *downloads = [TNDownloads shared];
    NSUInteger downloaded = 0;
    for (TNTrack *t in tracks) if ([downloads isDownloaded:t]) downloaded++;
    if (self.kind != TNListDownloads && tracks.count && downloaded < tracks.count) {
        [sheet addButton:L(@"Download all") action:^{ [TNRouter downloadTracks:tracks]; }];
    }
    if (self.kind == TNListDownloads && downloads.waitingCount) {
        [sheet addButton:L(@"Stop downloading") action:^{ [downloads cancelPending]; }];
    }
    __weak TNTrackListViewController *weakSelf = self;
    if (self.kind == TNListOwn) {
        [sheet addButton:L(@"Edit") action:^{ [weakSelf toggleEditing]; }];
        [sheet addButton:L(@"Rename") action:^{
            TNTrackListViewController *me = weakSelf;
            [TNRouter promptWithTitle:L(@"Rename the playlist") message:nil text:me.playlist.name placeholder:L(@"Name") button:L(@"Rename") completion:^(NSString *name) {
                if (!name.length) return;
                [[TNLibrary shared] renamePlaylist:me.playlist to:name];
                me.listTitle = name;
                [me showHeader];
            }];
        }];
        [sheet addDestructiveButton:L(@"Delete the playlist") action:^{
            TNTrackListViewController *me = weakSelf;
            [[TNLibrary shared] deletePlaylist:me.playlist];
            [TNRouter toast:L(@"Playlist deleted")];
            [me.navigationController popViewControllerAnimated:YES];
        }];
    } else if (downloaded) {
        NSString *title = self.kind == TNListDownloads ? L(@"Remove all downloads") : L(@"Remove the downloads");
        [sheet addDestructiveButton:title action:^{
            if (weakSelf.kind == TNListDownloads) [downloads removeAll];
            else for (TNTrack *t in tracks) [downloads remove:t];
            [TNRouter toast:L(@"Downloads removed")];
        }];
    }
    [sheet showFromView:self.moreButton inController:self];
}

- (void)toggleEditing
{
    BOOL editing = !self.tableView.editing;
    [self.tableView setEditing:editing animated:YES];
    for (TNTrackCell *cell in self.tableView.visibleCells) if ([cell isKindOfClass:[TNTrackCell class]]) cell.moreButton.hidden = editing;
    self.navigationItem.rightBarButtonItem = editing ? [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(toggleEditing)] : nil;
    if (!editing) [self load];
}

- (void)toggleSaved
{
    TNLibrary *library = [TNLibrary shared];
    if (self.kind == TNListAlbum) {
        BOOL saved = ![library isSavedAlbum:self.album];
        [library setSaved:saved album:self.album];
        [TNRouter toast:saved ? L(@"Added to your albums") : L(@"Removed from your albums")];
    } else if (self.playlist) {
        BOOL saved = ![library isSavedPlaylist:self.playlist];
        [library setSaved:saved playlist:self.playlist];
        [TNRouter toast:saved ? L(@"Added to your playlists") : L(@"Removed from your playlists")];
    }
    [self showHeader];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)self.tracks.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TNTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:TNTrackCellId forIndexPath:indexPath];
    TNTrack *t = self.tracks[(NSUInteger)indexPath.row];
    cell.showsArt = self.kind != TNListAlbum;
    cell.showsAlbum = self.kind != TNListPlaylist || TNIsPad();
    [cell showTrack:t number:self.kind == TNListAlbum ? (t.trackNumber ?: indexPath.row + 1) : 0];
    [cell.moreButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.moreButton addTarget:self action:@selector(moreTapped:) forControlEvents:UIControlEventTouchUpInside];
    cell.moreButton.tag = indexPath.row;
    cell.showsReorderControl = self.kind == TNListOwn;
    cell.moreButton.hidden = tableView.editing;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return self.kind == TNListOwn || self.kind == TNListDownloads;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return self.kind == TNListOwn; }

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath { return L(@"Remove"); }

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to
{
    NSMutableArray *tracks = [self.tracks mutableCopy];
    id t = tracks[(NSUInteger)from.row];
    [tracks removeObjectAtIndex:(NSUInteger)from.row];
    [tracks insertObject:t atIndex:(NSUInteger)to.row];
    self.tracks = tracks;
    [[TNLibrary shared] setTracks:tracks ofPlaylist:self.playlist];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    [self removeTrackAt:(NSUInteger)indexPath.row];
}

- (void)removeTrackAt:(NSUInteger)row
{
    if (row >= self.tracks.count) return;
    TNTrack *t = self.tracks[row];
    NSMutableArray *tracks = [self.tracks mutableCopy];
    [tracks removeObjectAtIndex:row];
    self.mutating = YES;   // (the change notifications leave the rows alone meanwhile)
    self.tracks = tracks;
    if (self.kind == TNListOwn) [[TNLibrary shared] setTracks:tracks ofPlaylist:self.playlist];
    else if (self.kind == TNListDownloads) [[TNDownloads shared] remove:t];
    self.mutating = NO;
    [self.tableView deleteRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:(NSInteger)row inSection:0] ] withRowAnimation:UITableViewRowAnimationFade];
    [self showHeader];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    TNTrack *t = self.tracks[(NSUInteger)indexPath.row];
    if ([[TNPlayer shared] isCurrent:t]) { [TNRouter showNowPlaying]; return; }
    if (!t.playable) {
        // (an Apple Music song that was not found: the user may pick its YouTube version)
        if ([t isApple]) [TNRouter chooseVideoForTrack:t];
        else [TNRouter toast:L(@"This song is not available.")];
        return;
    }
    [TNPlayer shared].shuffle = NO;
    [[TNPlayer shared] playTracks:self.tracks startingAt:(NSUInteger)indexPath.row contextURI:self.contextURI contextName:self.listTitle];
}

- (void)moreTapped:(UIButton *)sender
{
    if (sender.tag < 0 || sender.tag >= (NSInteger)self.tracks.count) return;
    TNTrack *t = self.tracks[(NSUInteger)sender.tag];
    if (self.kind == TNListOwn) {
        __weak TNTrackListViewController *weakSelf = self;
        [TNRouter showActionsForTrack:t fromView:sender inController:self removeTitle:L(@"Remove from this playlist") remove:^{
            NSUInteger row = [weakSelf.tracks indexOfObjectIdenticalTo:t];
            if (row != NSNotFound) [weakSelf removeTrackAt:row];
        }];
        return;
    }
    [TNRouter showActionsForTrack:t fromView:sender inController:self];
}

@end
