#import "TNLegacyCollections.h"
#import "TNLibraryViewController.h"
#import "TNCells.h"
#import "TNRouter.h"
#import "TNTheme.h"
#import "TNModels.h"
#import "TNLibrary.h"
#import "TNAppleMusic.h"
#import "TNImageLoader.h"
#import "TNSettings.h"
#import "TNDownloads.h"
#import "TNTrackListViewController.h"
#import "TNUtils.h"
#import "TNCommon.h"

@interface TNLibraryViewController ()
@property (nonatomic) BOOL switcher;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, strong) NSArray *itemTracks;       // the Apple library's albums and artists: the songs of each item
@property (nonatomic, strong) NSArray *fixedRows;        // NSDictionary {title, subtitle, icon, action} before the items
@property (nonatomic, strong) UISegmentedControl *segments;
@property (nonatomic, strong) UIView *appleHeader;
@property (nonatomic, strong) UILabel *appleStatus;
@property (nonatomic, strong) UIButton *appleMain;
@property (nonatomic, strong) UIButton *appleImport;
@end

@implementation TNLibraryViewController

- (instancetype)initWithMode:(TNLibraryMode)mode switcher:(BOOL)switcher
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _mode = mode;
        _switcher = switcher;
        _items = @[];
        _fixedRows = @[];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (NSString *)titleForMode:(TNLibraryMode)mode
{
    switch (mode) {
        case TNLibraryPlaylists: return L(@"Playlists");
        case TNLibraryAlbums: return L(@"Albums");
        case TNLibraryArtists: return L(@"Artists");
        case TNLibraryAppleAlbums: return L(@"Albums");
        case TNLibraryAppleArtists: return L(@"Artists");
        case TNLibraryAppleRecent: return L(@"Recently added");
        default: return L(@"Apple Music");
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = 68;
    [self.tableView registerClass:[TNMediaCell class] forCellReuseIdentifier:@"media"];
    if (self.switcher) {
        self.segments = [[UISegmentedControl alloc] initWithItems:@[ L(@"Playlists"), L(@"Albums"), L(@"Artists"), L(@"Apple") ]];
        self.segments.segmentedControlStyle = UISegmentedControlStyleBar;
        self.segments.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
        self.segments.selectedSegmentIndex = self.mode;
        [self.segments addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
        self.navigationItem.titleView = self.segments;
        self.title = L(@"Library");
    } else {
        self.title = [self titleForMode:self.mode];
    }
    [self buildAppleHeader];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(load) name:TNLibraryDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(appleChanged) name:TNAppleDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(downloadsChanged) name:TNDownloadsDidChangeNotification object:nil];
}

- (void)downloadsChanged
{
    if (self.mode == TNLibraryPlaylists) [self load];
}

- (void)segmentChanged
{
    self.mode = (TNLibraryMode)self.segments.selectedSegmentIndex;
    [self load];
}

- (void)setMode:(TNLibraryMode)mode
{
    _mode = mode;
    if (!self.switcher && self.isViewLoaded) self.title = [self titleForMode:mode];
}

- (void)appleChanged
{
    if (self.mode >= TNLibraryApple) [self load];
}

#pragma mark - The Apple Music header

- (void)buildAppleHeader
{
    TNTheme *theme = [TNTheme shared];
    self.appleHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 130)];
    UIImageView *mark = [[UIImageView alloc] initWithImage:[theme appleMarkWithSize:56]];
    mark.frame = CGRectMake(14, 14, 56, 56);
    [self.appleHeader addSubview:mark];
    self.appleStatus = [[UILabel alloc] initWithFrame:CGRectZero];
    self.appleStatus.font = [theme smallFont];
    self.appleStatus.textColor = [theme secondaryTextColor];
    self.appleStatus.backgroundColor = [UIColor clearColor];
    self.appleStatus.numberOfLines = 3;
    [self.appleHeader addSubview:self.appleStatus];
    self.appleMain = [theme accentButtonWithTitle:L(@"Connect")];
    [self.appleMain addTarget:self action:@selector(appleMainTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.appleHeader addSubview:self.appleMain];
    self.appleImport = [theme outlineButtonWithTitle:L(@"Import a link")];
    [self.appleImport addTarget:self action:@selector(importLink) forControlEvents:UIControlEventTouchUpInside];
    [self.appleHeader addSubview:self.appleImport];
}

- (void)showAppleHeader
{
    TNAppleMusic *apple = [TNAppleMusic shared];
    TNTheme *theme = [TNTheme shared];
    BOOL connected = [apple connected];
    NSString *status;
    if (!connected) status = L(@"Connect your Apple Music library: its playlists show up here and play from YouTube Music. Or import a public playlist or album by its link.");
    else if (apple.syncing) status = apple.syncStatus ?: L(@"Syncing…");
    else {
        NSDate *last = [TNSettings appleLastSync];
        status = last ? [NSString stringWithFormat:L(@"Your library, synced %@. Pull down to sync again."), [TNUtils formatRelativeDate:last]] : L(@"Your library is connected.");
        if (apple.syncStatus.length) status = [status stringByAppendingFormat:@"\n%@", apple.syncStatus];
    }
    self.appleStatus.text = status;
    [self.appleMain setTitle:[(connected ? L(@"Sync now") : L(@"Connect")) uppercaseString] forState:UIControlStateNormal];
    self.appleMain.enabled = !apple.syncing;
    CGFloat w = self.tableView.bounds.size.width;
    self.appleStatus.frame = CGRectMake(82, 12, w - 96, 60);
    CGFloat mw = [theme widthForButton:self.appleMain minimum:100];
    self.appleMain.frame = CGRectMake(82, 80, mw, 32);
    self.appleImport.frame = CGRectMake(82 + mw + 10, 80, [theme widthForButton:self.appleImport minimum:120], 32);
    self.appleHeader.frame = CGRectMake(0, 0, w, 126);
    self.tableView.tableHeaderView = self.appleHeader;
}

- (void)appleMainTapped
{
    if (![[TNAppleMusic shared] connected]) { [TNRouter showAppleConnect]; return; }
    [[TNAppleMusic shared] syncWithCompletion:^(NSError *error) {
        if (error) [TNRouter toast:error.localizedDescription];
    }];
}

- (void)importLink { [TNRouter importLinkPrompt]; }

- (void)newPlaylist
{
    [TNRouter promptWithTitle:L(@"New playlist") message:nil text:@"" placeholder:L(@"Name") button:L(@"Create") completion:^(NSString *name) {
        if (!name.length) return;
        [TNRouter openPlaylist:[[TNLibrary shared] createPlaylistNamed:name tracks:@[]]];
    }];
}

#pragma mark - The Apple library's albums and artists (from its songs)

- (void)groupAppleSongs:(BOOL)albums
{
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];
    for (TNTrack *t in [[TNLibrary shared] appleSongs]) {
        NSString *artist = t.byline.length ? t.byline : L(@"Unknown artist");
        NSString *key = albums ? [NSString stringWithFormat:@"%@|%@", [t.album.name ?: @"" lowercaseString], [artist lowercaseString]] : [artist lowercaseString];
        if (albums && !t.album.name.length) continue;
        NSMutableArray *list = [groups objectForKey:key];
        if (!list) { list = [NSMutableArray array]; TNLegacyDictionarySet(groups, key, list); [order addObject:key]; }
        [list addObject:t];
    }
    [order sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [a localizedCaseInsensitiveCompare:b]; }];
    NSMutableArray *items = [NSMutableArray array], *tracks = [NSMutableArray array];
    for (NSString *key in order) {
        NSMutableArray *list = [groups objectForKey:key];
        TNTrack *first = list.firstObject;
        TNArtist *artist = [[TNArtist alloc] init];
        artist.name = first.byline.length ? first.byline : L(@"Unknown artist");
        NSString *art = TNAppleArtworkURL(first.appleArtwork, 300);
        if (albums) {
            [list sortUsingComparator:^NSComparisonResult(TNTrack *a, TNTrack *b) { return [@(a.trackNumber) compare:@(b.trackNumber)]; }];
            TNAlbum *album = [[TNAlbum alloc] init];
            album.name = first.album.name;
            album.artists = @[ artist ];
            if (art) album.thumbnails = @[ @{ @"url": art, @"width": @300, @"height": @300 } ];
            [items addObject:album];
        } else {
            artist.subtitle = [NSString stringWithFormat:L(@"%lu songs"), (unsigned long)list.count];
            [items addObject:artist];
        }
        [tracks addObject:list];
    }
    self.items = items;
    self.itemTracks = tracks;
}

#pragma mark - Loading

- (void)reload
{
    if (self.mode == TNLibraryApple && [[TNAppleMusic shared] connected]) {
        [[TNAppleMusic shared] syncWithCompletion:^(NSError *error) {
            [self load];
            if (error) [TNRouter toast:error.localizedDescription];
        }];
        return;
    }
    [self load];
}

- (void)load
{
    if (!self.isViewLoaded) return;
    TNLibrary *library = [TNLibrary shared];
    NSMutableArray *fixed = [NSMutableArray array];
    NSArray *items = @[];
    NSString *empty = nil;
    switch (self.mode) {
        case TNLibraryPlaylists: {
            [fixed addObject:@{ @"title": L(@"Liked music"), @"subtitle": [NSString stringWithFormat:L(@"%lu songs"), (unsigned long)[library likedSongs].count], @"icon": @(TNIconThumbUpFilled), @"action": @"liked" }];
            [fixed addObject:@{ @"title": L(@"Recently played"), @"subtitle": [NSString stringWithFormat:L(@"%lu songs"), (unsigned long)[library recentTracks].count], @"icon": @(TNIconClock), @"action": @"recent" }];
            TNDownloads *downloads = [TNDownloads shared];
            NSString *got = [NSString stringWithFormat:L(@"%lu songs"), (unsigned long)[downloads downloadedTracks].count];
            if (downloads.waitingCount) got = [NSString stringWithFormat:@"%@ • %@", got, downloads.state ?: @""];
            [fixed addObject:@{ @"title": L(@"Downloads"), @"subtitle": got, @"icon": @(TNIconDownload), @"action": @"downloads" }];
            if (self.switcher && [[TNAppleMusic shared] connected]) {
                [fixed addObject:@{ @"title": L(@"Apple Music"), @"subtitle": [NSString stringWithFormat:L(@"%lu playlists"), (unsigned long)[library applePlaylists].count], @"icon": @(TNIconCloud), @"action": @"apple" }];
            }
            [fixed addObject:@{ @"title": L(@"New playlist"), @"subtitle": L(@"Your own, of any songs"), @"icon": @(TNIconPlus), @"action": @"new" }];
            [fixed addObject:@{ @"title": L(@"Import a link"), @"subtitle": L(@"A playlist from Apple Music, Spotify or YouTube"), @"icon": @(TNIconLink), @"action": @"import" }];
            items = [library savedPlaylists];
            break;
        }
        case TNLibraryAlbums:
            items = [library savedAlbums];
            empty = L(@"Albums you save show up here.");
            break;
        case TNLibraryArtists:
            items = [library savedArtists];
            empty = L(@"Artists you save show up here.");
            break;
        case TNLibraryAppleAlbums:
        case TNLibraryAppleArtists:
            [self groupAppleSongs:self.mode == TNLibraryAppleAlbums];
            items = self.items;
            empty = L(@"Sync your Apple Music library first.");
            break;
        case TNLibraryAppleRecent:
            items = [library appleRecentlyAdded];
            empty = L(@"Sync your Apple Music library first.");
            break;
        case TNLibraryApple: {
            NSMutableArray *all = [NSMutableArray array];
            if ([[TNAppleMusic shared] connected]) {
                NSUInteger songs = [library appleSongs].count;
                if (songs) {
                    [fixed addObject:@{ @"title": L(@"Songs"), @"subtitle": [NSString stringWithFormat:L(@"%lu songs"), (unsigned long)songs], @"icon": @(TNIconPlaylist), @"action": @"amsongs" }];
                    [fixed addObject:@{ @"title": L(@"Albums"), @"subtitle": L(@"Your library's albums"), @"icon": @(TNIconAlbum), @"action": @"amalbums" }];
                    [fixed addObject:@{ @"title": L(@"Artists"), @"subtitle": L(@"Your library's artists"), @"icon": @(TNIconArtist), @"action": @"amartists" }];
                }
                if ([library appleRecentlyAdded].count) {
                    [fixed addObject:@{ @"title": L(@"Recently added"), @"subtitle": L(@"Albums and playlists"), @"icon": @(TNIconClock), @"action": @"amrecent" }];
                }
                [all addObjectsFromArray:[library applePlaylists]];
            }
            for (TNPlaylist *p in [library savedPlaylists]) if (p.source == TNSourceApple) [all addObject:p];
            items = all;
            break;
        }
    }
    if (self.mode != TNLibraryAppleAlbums && self.mode != TNLibraryAppleArtists) self.itemTracks = nil;
    self.fixedRows = fixed;
    self.items = items;
    if (self.mode == TNLibraryApple) [self showAppleHeader];
    else self.tableView.tableHeaderView = nil;
    [self finishLoadingWithError:nil empty:!items.count && !fixed.count && empty != nil emptyMessage:empty];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)(self.fixedRows.count + self.items.count);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TNMediaCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media" forIndexPath:indexPath];
    TNTheme *theme = [TNTheme shared];
    NSUInteger row = (NSUInteger)indexPath.row;
    if (row < self.fixedRows.count) {
        NSDictionary *d = [self.fixedRows objectAtIndex:row];
        cell.round = NO;
        [cell showTitle:[d objectForKey:@"title"] subtitle:[d objectForKey:@"subtitle"] imageURL:nil];
        TNIcon icon = (TNIcon)[[d objectForKey:@"icon"] integerValue];
        cell.art.image = icon == TNIconCloud ? [theme appleMarkWithSize:52] : [theme icon:icon size:28 color:[theme accentTextColor]];
        cell.art.contentMode = UIViewContentModeCenter;
        cell.art.backgroundColor = icon == TNIconCloud ? [UIColor clearColor] : [theme rowHighlightColor];
        return cell;
    }
    cell.art.backgroundColor = [UIColor clearColor];
    [cell showItem:[self.items objectAtIndex:row - self.fixedRows.count]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSUInteger row = (NSUInteger)indexPath.row;
    if (row < self.fixedRows.count) {
        NSString *action = [[self.fixedRows objectAtIndex:row] objectForKey:@"action"];
        if ([action isEqualToString:@"liked"]) [TNRouter openLikedSongs];
        else if ([action isEqualToString:@"recent"]) [TNRouter openRecent];
        else if ([action isEqualToString:@"apple"]) [TNRouter push:[[TNLibraryViewController alloc] initWithMode:TNLibraryApple switcher:NO]];
        else if ([action isEqualToString:@"downloads"]) [TNRouter push:[[TNTrackListViewController alloc] initDownloads]];
        else if ([action isEqualToString:@"new"]) [self newPlaylist];
        else if ([action isEqualToString:@"import"]) [self importLink];
        else if ([action isEqualToString:@"amalbums"]) [TNRouter push:[[TNLibraryViewController alloc] initWithMode:TNLibraryAppleAlbums switcher:NO]];
        else if ([action isEqualToString:@"amartists"]) [TNRouter push:[[TNLibraryViewController alloc] initWithMode:TNLibraryAppleArtists switcher:NO]];
        else if ([action isEqualToString:@"amrecent"]) [TNRouter push:[[TNLibraryViewController alloc] initWithMode:TNLibraryAppleRecent switcher:NO]];
        else if ([action isEqualToString:@"amsongs"]) {
            NSArray *songs = [[[TNLibrary shared] appleSongs] sortedArrayUsingComparator:^NSComparisonResult(TNTrack *a, TNTrack *b) {
                return [a.name ?: @"" localizedCaseInsensitiveCompare:b.name ?: @""];
            }];
            [TNRouter push:[[TNTrackListViewController alloc] initWithTracks:songs title:L(@"Songs") contextURI:@"am:library-songs"]];
        }
        return;
    }
    NSUInteger index = row - self.fixedRows.count;
    if (self.itemTracks && index < self.itemTracks.count) {
        id item = [self.items objectAtIndex:index];
        NSString *title = [item isKindOfClass:[TNAlbum class]] ? ((TNAlbum *)item).name : ((TNArtist *)item).name;
        [TNRouter push:[[TNTrackListViewController alloc] initWithTracks:[self.itemTracks objectAtIndex:index] title:title contextURI:[@"am:group:" stringByAppendingString:title ?: @""]]];
        return;
    }
    [TNRouter openItem:[self.items objectAtIndex:index]];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSUInteger row = (NSUInteger)indexPath.row;
    if (row < self.fixedRows.count || self.mode >= TNLibraryAppleAlbums) return NO;
    id item = [self.items objectAtIndex:row - self.fixedRows.count];
    return !([item isKindOfClass:[TNPlaylist class]] && ((TNPlaylist *)item).fromLibrary);
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath { return L(@"Remove"); }

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSUInteger row = (NSUInteger)indexPath.row;
    if (row < self.fixedRows.count) return;
    id item = [self.items objectAtIndex:row - self.fixedRows.count];
    TNLibrary *library = [TNLibrary shared];
    if ([item isKindOfClass:[TNPlaylist class]]) [library setSaved:NO playlist:item];
    else if ([item isKindOfClass:[TNAlbum class]]) [library setSaved:NO album:item];
    else if ([item isKindOfClass:[TNArtist class]]) [library setSaved:NO artist:item];
}

@end
