#import "TNArtistViewController.h"
#import "TNCells.h"
#import "TNRouter.h"
#import "TNTheme.h"
#import "TNModels.h"
#import "TNYTMusic.h"
#import "TNLibrary.h"
#import "TNPlayer.h"
#import "TNImageLoader.h"
#import "TNUtils.h"
#import "TNCommon.h"

@interface TNArtistViewController ()
@property (nonatomic, strong) TNArtist *artist;
@property (nonatomic, strong) TNArtistPage *page;
@property (nonatomic) BOOL showAllTop;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) UIImageView *banner;
@property (nonatomic, strong) UIImageView *bannerShade;
@property (nonatomic, strong) TNImageView *picture;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *radioButton;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, copy) NSString *bannerURL;
@end

@implementation TNArtistViewController

- (instancetype)initWithArtist:(TNArtist *)artist
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) _artist = artist;
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.artist.name;
    [self.tableView registerClass:[TNTrackCell class] forCellReuseIdentifier:@"track"];
    [self.tableView registerClass:[TNShelfCell class] forCellReuseIdentifier:@"shelf"];
    TNTheme *theme = [TNTheme shared];
    self.header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 10)];
    self.header.clipsToBounds = YES;
    self.banner = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.banner.contentMode = UIViewContentModeScaleAspectFill;
    self.banner.clipsToBounds = YES;
    self.banner.alpha = 0.45;
    [self.header addSubview:self.banner];
    self.bannerShade = [[UIImageView alloc] initWithImage:[theme shadowImageTop:NO]];
    [self.header addSubview:self.bannerShade];
    self.picture = [[TNImageView alloc] initWithFrame:CGRectZero];
    self.picture.contentMode = UIViewContentModeScaleAspectFill;
    self.picture.clipsToBounds = YES;
    self.picture.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    self.picture.layer.borderWidth = 2;
    [self.header addSubview:self.picture];
    self.nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.nameLabel.font = [theme headerFont];
    self.nameLabel.textColor = [theme primaryTextColor];
    self.nameLabel.backgroundColor = [UIColor clearColor];
    self.nameLabel.adjustsFontSizeToFitWidth = YES;
    self.nameLabel.minimumScaleFactor = 0.6;
    self.nameLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
    self.nameLabel.shadowOffset = CGSizeMake(0, 1);
    [self.header addSubview:self.nameLabel];
    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.infoLabel.font = [theme smallFont];
    self.infoLabel.textColor = [theme secondaryTextColor];
    self.infoLabel.backgroundColor = [UIColor clearColor];
    [self.header addSubview:self.infoLabel];
    self.playButton = [theme accentButtonWithTitle:L(@"Play")];
    [self.playButton addTarget:self action:@selector(playTop) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:self.playButton];
    self.radioButton = [theme outlineButtonWithTitle:L(@"Radio")];
    [self.radioButton addTarget:self action:@selector(playRadio) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:self.radioButton];
    self.saveButton = [theme outlineButtonWithTitle:L(@"Save")];
    [self.saveButton addTarget:self action:@selector(toggleSaved) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:self.saveButton];
    [self showHeader];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(showHeader) name:TNLibraryDidChangeNotification object:nil];
}

- (void)showHeader
{
    TNTheme *theme = [TNTheme shared];
    self.title = self.artist.name;
    self.nameLabel.text = [TNUtils displayText:self.artist.name];
    NSMutableArray *bits = [NSMutableArray array];
    if (self.artist.subtitle.length) [bits addObject:self.artist.subtitle];
    if (self.page.subscribers.length) [bits addObject:[NSString stringWithFormat:L(@"%@ subscribers"), self.page.subscribers]];
    self.infoLabel.text = [bits componentsJoinedByString:@" • "];
    NSString *square = TNSizedImageURL(TNBestThumbnail(self.artist.thumbnails, 300), 300);
    // (the page's picture is a wide banner: the round one is cut from its middle)
    NSString *picture = square;
    if (square && [square rangeOfString:@"googleusercontent.com"].location != NSNotFound) {
        NSRange eq = [square rangeOfString:@"=" options:NSBackwardsSearch];
        if (eq.location != NSNotFound) picture = [[square substringToIndex:eq.location] stringByAppendingString:@"=w300-h300-p-l90-rj"];
    }
    [self.picture setImageURL:picture placeholder:[theme artistPlaceholderWithSize:150]];
    NSString *banner = TNBestThumbnail(self.page.bannerThumbnails, 1080);
    if (banner && ![banner isEqualToString:self.bannerURL]) {
        self.bannerURL = banner;
        __weak TNArtistViewController *weakSelf = self;
        [[TNImageLoader shared] loadImage:banner maxPixels:1080 completion:^(UIImage *image) {
            if ([weakSelf.bannerURL isEqualToString:banner]) weakSelf.banner.image = image;
        }];
    }
    BOOL saved = [[TNLibrary shared] isSavedArtist:self.artist];
    [self.saveButton setTitle:[(saved ? L(@"Saved") : L(@"Save")) uppercaseString] forState:UIControlStateNormal];
    self.radioButton.hidden = !self.page.radioVideoId.length && !self.page.radioPlaylistId.length;
    CGFloat w = self.tableView.bounds.size.width;
    BOOL wide = w > 500;
    CGFloat side = wide ? 150 : 110, pad = wide ? 24 : 14;
    CGFloat height = side + pad * 2;
    self.banner.frame = CGRectMake(0, 0, w, height);
    self.bannerShade.frame = CGRectMake(0, height / 2, w, height / 2);
    self.picture.frame = CGRectMake(pad, pad, side, side);
    self.picture.layer.cornerRadius = side / 2;
    CGFloat x = pad + side + 20;
    self.nameLabel.frame = CGRectMake(x, pad + side / 2 - 48, w - x - pad, 40);
    self.infoLabel.frame = CGRectMake(x, pad + side / 2 - 6, w - x - pad, 18);
    CGFloat pw = [theme widthForButton:self.playButton minimum:90];
    CGFloat rw = self.radioButton.hidden ? 0 : [theme widthForButton:self.radioButton minimum:90];
    self.playButton.frame = CGRectMake(x, pad + side / 2 + 20, pw, 32);
    self.radioButton.frame = CGRectMake(x + pw + 10, pad + side / 2 + 20, rw, 32);
    self.saveButton.frame = CGRectMake(x + pw + 10 + (rw ? rw + 10 : 0), pad + side / 2 + 20, [theme widthForButton:self.saveButton minimum:90], 32);
    self.header.frame = CGRectMake(0, 0, w, height);
    self.tableView.tableHeaderView = self.header;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    if (fabs(self.header.bounds.size.width - self.tableView.bounds.size.width) > 1) [self showHeader];
}

- (void)load
{
    [self startLoading];
    __weak TNArtistViewController *weakSelf = self;
    [TNYTMusic artist:self.artist.browseId completion:^(TNArtistPage *page, NSError *error) {
        TNArtistViewController *me = weakSelf;
        if (!me) return;
        if (page.artist.name.length) {
            me.page = page;
            me.artist = page.artist;
        }
        BOOL empty = !me.page.topSongs.count && !me.page.shelves.count;
        [me finishLoadingWithError:empty ? error : nil empty:empty emptyMessage:L(@"Nothing here.")];
        [me showHeader];
    }];
}

- (void)playTop
{
    if (self.page.topSongs.count) {
        [TNPlayer shared].shuffle = NO;
        [[TNPlayer shared] playTracks:self.page.topSongs startingAt:0 contextURI:[@"artist:" stringByAppendingString:self.artist.browseId ?: @""] contextName:self.artist.name];
    }
}

- (void)playRadio
{
    NSString *videoId = self.page.radioVideoId, *playlistId = self.page.radioPlaylistId;
    NSString *name = [NSString stringWithFormat:L(@"%@ Radio"), self.artist.name ?: @""];
    [TNRouter toast:L(@"Starting radio…")];
    [TNYTMusic radioFor:videoId playlistId:playlistId completion:^(TNWatchQueue *queue, NSError *error) {
        if (!queue.tracks.count) { [TNRouter toast:error.localizedDescription ?: L(@"No radio for this.")]; return; }
        [TNPlayer shared].shuffle = NO;
        [[TNPlayer shared] playTracks:queue.tracks startingAt:0 contextURI:[@"radio:" stringByAppendingString:videoId ?: playlistId ?: @""] contextName:name];
    }];
}

- (void)toggleSaved
{
    TNLibrary *library = [TNLibrary shared];
    BOOL saved = ![library isSavedArtist:self.artist];
    [library setSaved:saved artist:self.artist];
    [TNRouter toast:saved ? L(@"Added to your artists") : L(@"Removed from your artists")];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1 + (NSInteger)self.page.shelves.count; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) {
        NSInteger n = (NSInteger)self.page.topSongs.count;
        if (!n) return 0;
        BOOL more = self.page.allSongsBrowseId.length > 0;
        return n + (more ? 1 : 0);
    }
    return 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) return indexPath.row < (NSInteger)self.page.topSongs.count ? 56 : 44;
    return [TNShelfCell heightForCardWidth:TNIsPad() ? 140 : 110];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (![self tableView:tableView numberOfRowsInSection:section]) return nil;
    if (section == 0) return TNSectionHeader(L(@"Top songs"), tableView.bounds.size.width);
    TNShelf *shelf = [self.page.shelves objectAtIndex:(NSUInteger)section - 1];
    if (shelf.moreBrowseId.length) return TNSectionHeaderWithMore(shelf.title ?: @"", tableView.bounds.size.width, self, @selector(moreTapped:), section - 1);
    return TNSectionHeader(shelf.title ?: @"", tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return [self tableView:tableView numberOfRowsInSection:section] ? 26 : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TNTheme *theme = [TNTheme shared];
    if (indexPath.section == 0) {
        if (indexPath.row >= (NSInteger)self.page.topSongs.count) {
            UITableViewCell *more = [tableView dequeueReusableCellWithIdentifier:@"more"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"more"];
            [theme styleCell:more];
            more.textLabel.text = L(@"All songs");
            more.textLabel.font = [theme boldBodyFont];
            more.textLabel.textColor = [theme secondaryTextColor];
            more.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return more;
        }
        TNTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
        cell.showsArt = YES;
        [cell showTrack:[self.page.topSongs objectAtIndex:(NSUInteger)indexPath.row] number:indexPath.row + 1];
        [cell.moreButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.moreButton addTarget:self action:@selector(trackMoreTapped:) forControlEvents:UIControlEventTouchUpInside];
        cell.moreButton.tag = indexPath.row;
        return cell;
    }
    TNShelfCell *cell = [tableView dequeueReusableCellWithIdentifier:@"shelf" forIndexPath:indexPath];
    [cell showItems:[[self.page.shelves objectAtIndex:(NSUInteger)indexPath.section - 1] items] cardWidth:TNIsPad() ? 140 : 110];
    cell.onSelect = ^(id item) { [TNRouter openItem:item]; };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;
    if (indexPath.row >= (NSInteger)self.page.topSongs.count) {
        TNPlaylist *p = [[TNPlaylist alloc] init];
        p.browseId = self.page.allSongsBrowseId;
        p.playlistId = [TNYTMusic playlistIdFromBrowseId:p.browseId];
        p.name = [NSString stringWithFormat:L(@"%@: all songs"), self.artist.name ?: @""];
        [TNRouter openPlaylist:p];
        return;
    }
    TNTrack *t = [self.page.topSongs objectAtIndex:(NSUInteger)indexPath.row];
    if ([[TNPlayer shared] isCurrent:t]) { [TNRouter showNowPlaying]; return; }
    [TNPlayer shared].shuffle = NO;
    [[TNPlayer shared] playTracks:self.page.topSongs startingAt:(NSUInteger)indexPath.row contextURI:[@"artist:" stringByAppendingString:self.artist.browseId ?: @""] contextName:self.artist.name];
}

- (void)moreTapped:(UIButton *)sender
{
    if (sender.tag < 0 || sender.tag >= (NSInteger)self.page.shelves.count) return;
    TNShelf *shelf = [self.page.shelves objectAtIndex:(NSUInteger)sender.tag];
    [TNRouter openBrowseId:shelf.moreBrowseId params:shelf.moreParams title:shelf.title];
}

- (void)trackMoreTapped:(UIButton *)sender
{
    if (sender.tag < (NSInteger)self.page.topSongs.count) [TNRouter showActionsForTrack:[self.page.topSongs objectAtIndex:(NSUInteger)sender.tag] fromView:sender inController:self];
}

@end
