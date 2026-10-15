#import "TNSettingsViewController.h"
#import "TNExternalOpen.h"
#import "TNRouter.h"
#import "TNAppleMusic.h"
#import "TNMatcher.h"
#import "TNLibrary.h"
#import "TNSettings.h"
#import "TNPlayer.h"
#import "TNDownloads.h"
#import "TNTrackListViewController.h"
#import "TNImageLoader.h"
#import "TNUtils.h"
#import "TNTheme.h"
#import "TNCommon.h"

// The look of a dark grouped table on iOS 6: the rounded cells on charcoal, headers and footers drawn here
// (the system's are dark text on white shadow, made for the pinstripes)
static void TNStyleGroupedCell(UITableViewCell *cell)
{
    TNTheme *theme = [TNTheme shared];
    cell.backgroundColor = [theme panelColor];
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = [theme primaryTextColor];
    cell.textLabel.font = [theme boldBodyFont];
    cell.detailTextLabel.backgroundColor = [UIColor clearColor];
    cell.detailTextLabel.textColor = [theme secondaryTextColor];
    cell.detailTextLabel.font = [theme bodyFont];
    UIView *selected = [[UIView alloc] init];
    selected.backgroundColor = [theme rowHighlightColor];
    cell.selectedBackgroundView = selected;
}

static UIView *TNGroupedLabel(NSString *text, CGFloat width, BOOL header, CGFloat *height)
{
    TNTheme *theme = [TNTheme shared];
    UIFont *font = header ? [theme boldBodyFont] : [theme smallFont];
    CGFloat inset = TNIsPad() ? 54 : 20;
    CGSize s = [text sizeWithFont:font constrainedToSize:CGSizeMake(width - inset * 2, 400)];
    CGFloat h = ceilf(s.height) + (header ? 22 : 16);
    if (height) *height = h;
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, h)];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(inset, header ? 14 : 6, width - inset * 2, ceilf(s.height))];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    l.text = text;
    l.font = font;
    l.numberOfLines = 0;
    l.textColor = header ? [theme secondaryTextColor] : [theme tertiaryTextColor];
    l.backgroundColor = [UIColor clearColor];
    l.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
    l.shadowOffset = CGSizeMake(0, -1);
    [v addSubview:l];
    return v;
}

#pragma mark - Licences

@interface TNLicensesViewController : UIViewController
@end

@implementation TNLicensesViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = L(@"Open-source software");
    TNTheme *theme = [TNTheme shared];
    self.view.backgroundColor = [theme backgroundColor];
    UITextView *text = [[UITextView alloc] initWithFrame:self.view.bounds];
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    text.editable = NO;
    text.backgroundColor = [UIColor clearColor];
    text.textColor = [theme primaryTextColor];
    text.font = [theme bodyFont];
    text.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    text.text = [NSString stringWithFormat:@"%@\n\n"
                 "Mbed TLS (Arm Limited and contributors)\nApache License 2.0\n\n"
                 "%@",
                 L(@"Muzika is built with these, thank you:"),
                 L(@"Muzika is an unofficial app. It is not made, endorsed or supported by Google, YouTube or Apple. YouTube Music is a trademark of Google LLC, Apple Music a trademark of Apple Inc.")];
    [self.view addSubview:text];
}

@end

#pragma mark - Settings

enum { TNSetApple, TNSetPlayback, TNSetDownloads, TNSetStorage, TNSetAbout, TNSetCount };
enum { TNPlayAutoplay, TNPlayNormalize, TNPlayCrossfade, TNPlayVideos, TNPlayMatchAll, TNPlaySidePanel };

@interface TNSettingsViewController () <UIAlertViewDelegate>
@property (nonatomic, copy) NSString *cacheSize;
@end

@implementation TNSettingsViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) self.title = L(@"Settings");
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.backgroundView = nil;
    self.tableView.backgroundColor = [[TNTheme shared] backgroundColor];
    self.tableView.separatorColor = [[TNTheme shared] separatorColor];
    self.tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(reload) name:TNSettingsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(reload) name:TNAppleDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(reload) name:TNDownloadsDidChangeNotification object:nil];
}

- (void)reload { [self.tableView reloadData]; }

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    [[TNImageLoader shared] diskUsage:^(unsigned long long bytes) {
        self.cacheSize = [TNUtils formatFileSize:bytes];
        [self.tableView reloadData];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return TNSetCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case TNSetApple: return [[TNAppleMusic shared] connected] ? 5 : 2;
        case TNSetPlayback: return TNIsPad() ? 6 : 5;
        case TNSetDownloads: return 4;
        case TNSetStorage: return 3;
        case TNSetAbout: return 3;
    }
    return 0;
}

- (NSString *)headerFor:(NSInteger)section
{
    switch (section) {
        case TNSetApple: return L(@"Apple Music");
        case TNSetPlayback: return L(@"Playback");
        case TNSetDownloads: return L(@"Data and downloads");
        case TNSetStorage: return L(@"Storage");
        case TNSetAbout: return L(@"About");
    }
    return nil;
}

- (NSString *)footerFor:(NSInteger)section
{
    switch (section) {
        case TNSetApple: return L(@"Your Apple Music playlists play from YouTube Music: every song is looked up by its ISRC code, else by its title, artist and length. A wrong match can be fixed in the song's menu.");
        case TNSetPlayback: return L(@"Autoplay: when your music runs out, the radio of the last song keeps playing. Same loudness: every song plays as loud as the next (by YouTube's measure of each song). Crossfade blends the end of a song into the next one.");
        case TNSetDownloads: return L(@"Data saver: on mobile data songs play at 48 kbit/s (HE-AAC, about a third of the data). Downloaded songs play without the internet, in full quality.");
        case TNSetAbout: return L(@"Muzika is an unofficial app. It is not made, endorsed or supported by Google, YouTube or Apple.");
    }
    return nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    NSString *t = [self headerFor:section];
    return t ? TNGroupedLabel(t, tableView.bounds.size.width, YES, NULL) : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    NSString *t = [self headerFor:section];
    if (!t) return 14;
    CGFloat h = 0;
    TNGroupedLabel(t, tableView.bounds.size.width, YES, &h);
    return h;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section
{
    NSString *t = [self footerFor:section];
    return t ? TNGroupedLabel(t, tableView.bounds.size.width, NO, NULL) : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    NSString *t = [self footerFor:section];
    if (!t) return 6;
    CGFloat h = 0;
    TNGroupedLabel(t, tableView.bounds.size.width, NO, &h);
    return h;
}

- (UISwitch *)switchOn:(BOOL)on action:(SEL)action
{
    UISwitch *s = [[UISwitch alloc] init];
    s.on = on;
    [s addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return s;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    TNStyleGroupedCell(cell);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSInteger row = indexPath.row;
    TNAppleMusic *apple = [TNAppleMusic shared];
    switch (indexPath.section) {
        case TNSetApple:
            if (![apple connected]) {
                if (row == 0) {
                    cell.textLabel.text = L(@"Connect Apple Music");
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    cell.selectionStyle = UITableViewCellSelectionStyleGray;
                } else {
                    cell.textLabel.text = L(@"Songs found on YouTube");
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)[[TNMatcher shared] matchCount]];
                }
                break;
            }
            if (row == 0) {
                cell.textLabel.text = L(@"Library");
                cell.detailTextLabel.text = apple.syncing ? (apple.syncStatus ?: L(@"Syncing…")) :
                    [NSString stringWithFormat:L(@"%lu playlists"), (unsigned long)[[TNLibrary shared] applePlaylists].count];
            }
            if (row == 1) {
                cell.textLabel.text = L(@"Sync now");
                NSDate *last = [TNSettings appleLastSync];
                cell.detailTextLabel.text = last ? [TNUtils formatRelativeDate:last] : @"";
                cell.selectionStyle = UITableViewCellSelectionStyleGray;
            }
            if (row == 2) {
                cell.textLabel.text = L(@"Songs found on YouTube");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)[[TNMatcher shared] matchCount]];
            }
            if (row == 3) { cell.textLabel.text = L(@"Likes go to Apple Music"); cell.accessoryView = [self switchOn:[TNSettings syncAppleLikes] action:@selector(appleLikesChanged:)]; }
            if (row == 4) {
                cell.textLabel.text = L(@"Disconnect");
                cell.textLabel.textAlignment = NSTextAlignmentCenter;
                cell.textLabel.textColor = [UIColor colorWithRed:1 green:0.42 blue:0.38 alpha:1];
                cell.selectionStyle = UITableViewCellSelectionStyleGray;
            }
            break;
        case TNSetPlayback:
            if (row == TNPlayAutoplay) { cell.textLabel.text = L(@"Autoplay"); cell.accessoryView = [self switchOn:[TNSettings autoplay] action:@selector(autoplayChanged:)]; }
            if (row == TNPlayNormalize) { cell.textLabel.text = L(@"Same loudness"); cell.accessoryView = [self switchOn:[TNSettings normalize] action:@selector(normalizeChanged:)]; }
            if (row == TNPlayCrossfade) {
                cell.textLabel.text = L(@"Crossfade");
                NSInteger s = [TNSettings crossfadeSeconds];
                cell.detailTextLabel.text = s ? [NSString stringWithFormat:L(@"%ld s"), (long)s] : L(@"Off");
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleGray;
            }
            if (row == TNPlayVideos) { cell.textLabel.text = L(@"Music videos for Apple songs"); cell.accessoryView = [self switchOn:[TNSettings allowVideosForApple] action:@selector(videosChanged:)]; }
            if (row == TNPlayMatchAll) { cell.textLabel.text = L(@"Find whole playlists at once"); cell.accessoryView = [self switchOn:[TNSettings matchWholePlaylists] action:@selector(matchAllChanged:)]; }
            if (row == TNPlaySidePanel) { cell.textLabel.text = L(@"Side panel in landscape"); cell.accessoryView = [self switchOn:[TNSettings sidePanel] action:@selector(sidePanelChanged:)]; }
            break;
        case TNSetDownloads:
            if (row == 0) { cell.textLabel.text = L(@"Data saver"); cell.accessoryView = [self switchOn:[TNSettings dataSaver] action:@selector(dataSaverChanged:)]; }
            if (row == 1) { cell.textLabel.text = L(@"Download on Wi-Fi only"); cell.accessoryView = [self switchOn:[TNSettings downloadOnWiFiOnly] action:@selector(wifiOnlyChanged:)]; }
            if (row == 2) {
                TNDownloads *downloads = [TNDownloads shared];
                cell.textLabel.text = L(@"Downloaded songs");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu • %@", (unsigned long)[downloads downloadedTracks].count, [TNUtils formatFileSize:[downloads bytesUsed]]];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleGray;
            }
            if (row == 3) {
                cell.textLabel.text = L(@"Remove all downloads");
                cell.textLabel.textAlignment = NSTextAlignmentCenter;
                cell.textLabel.textColor = [UIColor colorWithRed:1 green:0.42 blue:0.38 alpha:1];
                cell.selectionStyle = UITableViewCellSelectionStyleGray;
            }
            break;
        case TNSetStorage:
            if (row == 0) {
                cell.textLabel.text = L(@"Clear image cache");
                cell.detailTextLabel.text = self.cacheSize ?: @"…";
            }
            if (row == 1) cell.textLabel.text = L(@"Clear the played songs");
            if (row == 2) cell.textLabel.text = L(@"Forget the YouTube matches");
            cell.selectionStyle = UITableViewCellSelectionStyleGray;
            break;
        case TNSetAbout:
            if (row == 0) { cell.textLabel.text = L(@"Version"); cell.detailTextLabel.text = [TNUtils appVersion]; }
            if (row == 1) {
                cell.textLabel.text = L(@"Open-source software");
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleGray;
            }
            if (row == 2) {
                cell.textLabel.text = L(@"Support the development");
                cell.detailTextLabel.text = @"ko-fi.com/samcejko";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleGray;
            }
            break;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger row = indexPath.row;
    TNAppleMusic *apple = [TNAppleMusic shared];
    switch (indexPath.section) {
        case TNSetApple:
            if (![apple connected]) { if (row == 0) [TNRouter showAppleConnect]; break; }
            if (row == 1) {
                [apple syncWithCompletion:^(NSError *error) { [TNRouter toast:error ? error.localizedDescription : L(@"Apple Music synced")]; }];
                [self.tableView reloadData];
            }
            if (row == 4) {
                UIAlertView *a = [[UIAlertView alloc] initWithTitle:L(@"Disconnect Apple Music?") message:L(@"The synced playlists leave this device. The songs found on YouTube are remembered.")
                                                           delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Disconnect"), nil];
                a.tag = 2;
                [a show];
            }
            break;
        case TNSetPlayback:
            if (row == TNPlayCrossfade) {
                TNActionSheet *sheet = [[TNActionSheet alloc] initWithTitle:L(@"Crossfade")];
                for (NSNumber *n in @[ @0, @3, @6, @9, @12 ]) {
                    NSInteger s = [n integerValue];
                    [sheet addButton:s ? [NSString stringWithFormat:L(@"%ld s"), (long)s] : L(@"Off") action:^{ [TNSettings setCrossfadeSeconds:s]; }];
                }
                [sheet showFromView:[tableView cellForRowAtIndexPath:indexPath] inController:self];
            }
            break;
        case TNSetDownloads:
            if (row == 2) [self.navigationController pushViewController:[[TNTrackListViewController alloc] initDownloads] animated:YES];
            if (row == 3 && [[TNDownloads shared] downloadedTracks].count) {
                UIAlertView *a = [[UIAlertView alloc] initWithTitle:L(@"Remove all downloads?") message:L(@"The songs leave this device; they still play over the internet.")
                                                           delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Remove"), nil];
                a.tag = 3;
                [a show];
            }
            break;
        case TNSetStorage:
            if (row == 0) {
                [[TNImageLoader shared] clearMemory];
                [[TNImageLoader shared] clearDiskWithCompletion:^{
                    self.cacheSize = [TNUtils formatFileSize:0];
                    [self.tableView reloadData];
                    [TNRouter toast:L(@"Image cache cleared")];
                }];
            } else if (row == 1) {
                [[TNLibrary shared] clearRecent];
                [TNRouter toast:L(@"Cleared")];
            } else {
                [[TNMatcher shared] forgetAll];
                [self.tableView reloadData];
                [TNRouter toast:L(@"Cleared")];
            }
            break;
        case TNSetAbout:
            if (row == 1) [self.navigationController pushViewController:[[TNLicensesViewController alloc] init] animated:YES];
            else if (row == 2) [TNExternalOpen presentOpenInForURL:[NSURL URLWithString:@"https://ko-fi.com/samcejko"] from:self anchor:[tableView cellForRowAtIndexPath:indexPath]];
            break;
    }
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex) return;
    if (alertView.tag == 2) {
        [[TNAppleMusic shared] disconnect];
        [self.tableView reloadData];
    }
    if (alertView.tag == 3) {
        [[TNDownloads shared] removeAll];
        [TNRouter toast:L(@"Downloads removed")];
    }
}

- (void)normalizeChanged:(UISwitch *)s { [TNSettings setNormalize:s.on]; }
- (void)dataSaverChanged:(UISwitch *)s { [TNSettings setDataSaver:s.on]; }
- (void)wifiOnlyChanged:(UISwitch *)s { [TNSettings setDownloadOnWiFiOnly:s.on]; }
- (void)appleLikesChanged:(UISwitch *)s { [TNSettings setSyncAppleLikes:s.on]; }
- (void)sidePanelChanged:(UISwitch *)s { [TNSettings setSidePanel:s.on]; }

- (void)autoplayChanged:(UISwitch *)s { [TNSettings setAutoplay:s.on]; }
- (void)videosChanged:(UISwitch *)s { [TNSettings setAllowVideosForApple:s.on]; }
- (void)matchAllChanged:(UISwitch *)s { [TNSettings setMatchWholePlaylists:s.on]; }

@end
