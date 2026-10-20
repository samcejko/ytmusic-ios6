#import "TNSidebarViewController.h"
#import "TNRouter.h"
#import "TNAppleMusic.h"
#import "TNLibrary.h"
#import "TNSettings.h"
#import "TNModels.h"
#import "TNUtils.h"
#import "TNTheme.h"
#import "TNModern.h"
#import "TNCommon.h"

enum { TNSideMain, TNSideLibrary, TNSideApple, TNSideSectionCount };

@interface TNSidebarCell : UITableViewCell
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic) BOOL current;
@end

@implementation TNSidebarCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        TNTheme *theme = [TNTheme shared];
        self.backgroundColor = [UIColor clearColor];
        self.backgroundView = [[UIImageView alloc] initWithImage:nil];
        UIView *pressed = [[UIView alloc] init];
        pressed.backgroundColor = [theme rowHighlightColor];
        self.selectedBackgroundView = pressed;
        _icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        _icon.contentMode = UIViewContentModeCenter;
        [self.contentView addSubview:_icon];
        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.backgroundColor = [UIColor clearColor];
        _label.font = [theme boldBodyFont];
        _label.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
        _label.shadowOffset = CGSizeMake(0, -1);
        [self.contentView addSubview:_label];
    }
    return self;
}

- (void)setCurrent:(BOOL)current
{
    _current = current;
    TNTheme *theme = [TNTheme shared];
    ((UIImageView *)self.backgroundView).image = current ? [theme sidebarSelectionImage] : nil;
    self.label.textColor = current ? [UIColor whiteColor] : [theme secondaryTextColor];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGSize s = self.contentView.bounds.size;
    self.icon.frame = CGRectMake(12, 0, 26, s.height);
    self.label.frame = CGRectMake(46, 0, s.width - 54, s.height);
}

@end

@interface TNSidebarViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIImageView *logo;
@property (nonatomic, strong) UILabel *wordmark;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIView *footer;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIButton *settingsButton;
@property (nonatomic, strong) NSArray *mainRows;       // NSDictionary {title, icon, section}
@property (nonatomic, strong) NSArray *libraryRows;
@property (nonatomic, strong) NSArray *playlists;      // TNPlaylist (Apple Music)
@property (nonatomic) TNSection selected;
@property (nonatomic, copy) NSString *selectedPlaylist;
@end

@implementation TNSidebarViewController

- (instancetype)init
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _selected = (TNSection)-1;
        _playlists = @[];
        _mainRows = @[ @{ @"title": L(@"Home"), @"icon": @(TNIconHome), @"section": @(TNSectionHome) },
                       @{ @"title": L(@"Explore"), @"icon": @(TNIconExplore), @"section": @(TNSectionExplore) },
                       @{ @"title": L(@"Search"), @"icon": @(TNIconSearch), @"section": @(TNSectionSearch) } ];
        _libraryRows = @[ @{ @"title": L(@"Liked music"), @"icon": @(TNIconThumbUp), @"section": @(TNSectionLiked) },
                          @{ @"title": L(@"Playlists"), @"icon": @(TNIconPlaylist), @"section": @(TNSectionPlaylists) },
                          @{ @"title": L(@"Albums"), @"icon": @(TNIconAlbum), @"section": @(TNSectionAlbums) },
                          @{ @"title": L(@"Artists"), @"icon": @(TNIconArtist), @"section": @(TNSectionArtists) },
                          @{ @"title": L(@"Recently played"), @"icon": @(TNIconClock), @"section": @(TNSectionRecent) } ];
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    TNTheme *theme = [TNTheme shared];
    self.view.backgroundColor = [theme panelColor];

    self.logo = [[UIImageView alloc] initWithImage:[theme brandMarkWithSize:30]];
    [self.view addSubview:self.logo];
    self.wordmark = [[UILabel alloc] initWithFrame:CGRectZero];
    self.wordmark.text = @"Muzika";
    self.wordmark.font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:22] ?: [UIFont boldSystemFontOfSize:22];
    self.wordmark.textColor = [UIColor whiteColor];
    self.wordmark.backgroundColor = [UIColor clearColor];
    self.wordmark.shadowColor = [UIColor blackColor];
    self.wordmark.shadowOffset = CGSizeMake(0, -1);
    [self.view addSubview:self.wordmark];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.table.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.table.rowHeight = 40;
    self.table.scrollsToTop = NO;
    [self.view addSubview:self.table];

    self.footer = [[UIView alloc] initWithFrame:CGRectZero];
    UIImageView *footerBack = [[UIImageView alloc] initWithImage:[theme navigationBarImage]];
    footerBack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.footer addSubview:footerBack];
    UIImageView *mark = [[UIImageView alloc] initWithImage:[theme appleMarkWithSize:30]];
    mark.frame = CGRectMake(10, 11, 30, 30);
    [self.footer addSubview:mark];
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.font = [theme boldBodyFont];
    self.statusLabel.textColor = [theme primaryTextColor];
    self.statusLabel.backgroundColor = [UIColor clearColor];
    [self.footer addSubview:self.statusLabel];
    self.detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.detailLabel.font = [theme smallFont];
    self.detailLabel.textColor = [theme secondaryTextColor];
    self.detailLabel.backgroundColor = [UIColor clearColor];
    [self.footer addSubview:self.detailLabel];
    self.settingsButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.settingsButton setImage:[theme icon:TNIconSettings size:22 color:[theme secondaryTextColor]] forState:UIControlStateNormal];
    self.settingsButton.showsTouchWhenHighlighted = YES;
    self.settingsButton.accessibilityLabel = L(@"Settings");
    [self.settingsButton addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [self.footer addSubview:self.settingsButton];
    UIButton *account = [UIButton buttonWithType:UIButtonTypeCustom];
    account.tag = 7;
    account.accessibilityLabel = L(@"Apple Music");
    [account addTarget:self action:@selector(openApple) forControlEvents:UIControlEventTouchUpInside];
    [self.footer insertSubview:account aboveSubview:footerBack];
    [self.view addSubview:self.footer];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(appleChanged) name:TNAppleDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(appleChanged) name:TNSettingsDidChangeNotification object:nil];
    [self appleChanged];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGSize s = self.view.bounds.size;
    // (iOS 6 puts the view under the status bar; from iOS 7 on it lies behind it)
    CGFloat top = TNModernTopInset(self.view, 0);
    self.logo.frame = CGRectMake(14, top + 12, 30, 30);
    self.wordmark.frame = CGRectMake(52, top + 10, s.width - 60, 34);
    CGFloat footerH = 52;
    self.table.frame = CGRectMake(0, top + 54, s.width, s.height - top - 54 - footerH);
    self.footer.frame = CGRectMake(0, s.height - footerH, s.width, footerH);
    self.statusLabel.frame = CGRectMake(48, 9, s.width - 96, 18);
    self.detailLabel.frame = CGRectMake(48, 27, s.width - 96, 16);
    self.settingsButton.frame = CGRectMake(s.width - 46, 4, 44, 44);
    [self.footer viewWithTag:7].frame = CGRectMake(0, 0, s.width - 50, footerH);
}

#pragma mark - Data

- (void)appleChanged
{
    TNAppleMusic *apple = [TNAppleMusic shared];
    BOOL connected = [apple connected];
    self.statusLabel.text = L(@"Apple Music");
    if (!connected) self.detailLabel.text = L(@"Not connected");
    else if (apple.syncing) self.detailLabel.text = apple.syncStatus ?: L(@"Syncing…");
    else {
        NSDate *last = [TNSettings appleLastSync];
        self.detailLabel.text = last ? [NSString stringWithFormat:L(@"Synced %@"), [TNUtils formatRelativeDate:last]] : L(@"Connected");
    }
    self.playlists = connected ? [[TNLibrary shared] applePlaylists] : @[];
    [self.table reloadData];
}

#pragma mark - Selection

- (void)selectSection:(TNSection)section
{
    self.selected = section;
    self.selectedPlaylist = nil;
    [self.table reloadData];
}

- (void)selectPlaylist:(NSString *)playlistKey
{
    self.selected = (TNSection)-1;
    self.selectedPlaylist = playlistKey;
    [self.table reloadData];
}

- (void)openSettings
{
    if (self.onSection) self.onSection(TNSectionSettings);
}

- (void)openApple
{
    if (![[TNAppleMusic shared] connected]) { [TNRouter showAppleConnect]; return; }
    if (self.onSection) self.onSection(TNSectionApple);
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return TNSideSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == TNSideMain) return (NSInteger)self.mainRows.count;
    if (section == TNSideLibrary) return (NSInteger)self.libraryRows.count;
    return 1 + (NSInteger)self.playlists.count;   // "Apple Music" (or "Connect") and the playlists
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return section == TNSideMain ? 4 : 34;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 34)];
    v.backgroundColor = [[TNTheme shared] panelColor];
    if (section == TNSideMain) return v;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, v.bounds.size.width - 28, 18)];
    l.text = [section == TNSideLibrary ? L(@"Library") : L(@"Apple Music") uppercaseString];
    l.font = [[TNTheme shared] sectionFont];
    l.textColor = [[TNTheme shared] tertiaryTextColor];
    l.backgroundColor = [UIColor clearColor];
    l.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    l.shadowOffset = CGSizeMake(0, -1);
    [v addSubview:l];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TNSidebarCell *cell = [tableView dequeueReusableCellWithIdentifier:@"side"] ?: [[TNSidebarCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"side"];
    TNTheme *theme = [TNTheme shared];
    BOOL current;
    TNIcon icon;
    if (indexPath.section == TNSideApple) {
        if (indexPath.row == 0) {
            BOOL connected = [[TNAppleMusic shared] connected];
            cell.label.text = connected ? L(@"All Apple playlists") : L(@"Connect Apple Music");
            icon = connected ? TNIconCloud : TNIconPlus;
            current = !self.selectedPlaylist && self.selected == TNSectionApple;
        } else {
            TNPlaylist *p = [self.playlists objectAtIndex:(NSUInteger)indexPath.row - 1];
            cell.label.text = [TNUtils displayText:p.name];
            icon = TNIconPlaylist;
            current = [[p key] isEqualToString:self.selectedPlaylist];
        }
    } else {
        NSDictionary *row = [(indexPath.section == TNSideMain ? self.mainRows : self.libraryRows) objectAtIndex:(NSUInteger)indexPath.row];
        cell.label.text = [row objectForKey:@"title"];
        icon = (TNIcon)[[row objectForKey:@"icon"] integerValue];
        current = !self.selectedPlaylist && [[row objectForKey:@"section"] integerValue] == self.selected;
    }
    cell.current = current;
    cell.icon.image = [theme icon:icon size:20 color:current ? [theme accentTextColor] : [theme secondaryTextColor]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == TNSideApple) {
        if (indexPath.row == 0) { [self openApple]; return; }
        if (self.onPlaylist) self.onPlaylist([self.playlists objectAtIndex:(NSUInteger)indexPath.row - 1]);
        return;
    }
    NSDictionary *row = [(indexPath.section == TNSideMain ? self.mainRows : self.libraryRows) objectAtIndex:(NSUInteger)indexPath.row];
    if (self.onSection) self.onSection((TNSection)[[row objectForKey:@"section"] integerValue]);
}

@end
