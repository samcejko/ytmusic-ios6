#import "TNMatchPickerViewController.h"
#import "TNCells.h"
#import "TNRouter.h"
#import "TNTheme.h"
#import "TNModels.h"
#import "TNYTMusic.h"
#import "TNMatcher.h"
#import "TNPlayer.h"
#import "TNCommon.h"

@interface TNMatchPickerViewController () <UISearchBarDelegate>
@property (nonatomic, strong) TNTrack *track;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray *songs;
@property (nonatomic, strong) NSArray *videos;
@property (nonatomic) NSUInteger generation;
@end

@implementation TNMatchPickerViewController

- (instancetype)initWithTrack:(TNTrack *)track
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _track = track;
        _songs = @[];
        _videos = @[];
        self.refreshable = NO;
        self.title = L(@"YouTube version");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    TNTheme *theme = [TNTheme shared];
    self.tableView.rowHeight = 56;
    [self.tableView registerClass:[TNTrackCell class] forCellReuseIdentifier:@"track"];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(close)];
    CGFloat w = MAX((CGFloat)320, self.view.bounds.size.width);   // (no width yet in viewDidLoad on newer iOS; the table widens it)
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 44 + 54)];
    UILabel *info = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, w - 24, 40)];
    info.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    info.numberOfLines = 2;
    info.font = [theme smallFont];
    info.textColor = [theme secondaryTextColor];
    info.backgroundColor = [UIColor clearColor];
    info.text = [NSString stringWithFormat:L(@"Apple Music: %@ - %@ (%@). Pick what should play for it."),
                 self.track.name ?: @"", [self.track artistNames] ?: @"", TNFormatDurationMs(self.track.durationMs)];
    [header addSubview:info];
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 54, w, 44)];
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.searchBar.delegate = self;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.text = [NSString stringWithFormat:@"%@ %@", self.track.name ?: @"", [self.track artistNames] ?: @""];
    [theme applyToSearchBar:self.searchBar];
    [header addSubview:self.searchBar];
    self.tableView.tableHeaderView = header;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
    [self load];
}

- (void)load
{
    NSString *q = self.searchBar.text;
    if (!q.length) return;
    [self startLoading];
    NSUInteger generation = ++self.generation;
    __weak TNMatchPickerViewController *weakSelf = self;
    __block NSUInteger waiting = 2;
    __block NSError *lastError = nil;
    void (^done)(void) = ^{
        TNMatchPickerViewController *me = weakSelf;
        if (!me || generation != me.generation || --waiting > 0) return;
        BOOL empty = !me.songs.count && !me.videos.count;
        [me finishLoadingWithError:empty ? lastError : nil empty:empty emptyMessage:L(@"Nothing found.")];
    };
    [TNYTMusic search:q filter:TNSearchSongs completion:^(TNSearchResults *results, NSError *error) {
        NSMutableArray *items = [NSMutableArray array];
        for (TNShelf *s in results.shelves) for (id i in s.items) if ([i isKindOfClass:[TNTrack class]]) [items addObject:i];
        weakSelf.songs = items;
        if (error) lastError = error;
        done();
    }];
    [TNYTMusic search:q filter:TNSearchVideos completion:^(TNSearchResults *results, NSError *error) {
        NSMutableArray *items = [NSMutableArray array];
        for (TNShelf *s in results.shelves) for (id i in s.items) if ([i isKindOfClass:[TNTrack class]]) [items addObject:i];
        weakSelf.videos = items;
        if (error) lastError = error;
        done();
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSArray *)itemsIn:(NSInteger)section { return section == 0 ? self.songs : self.videos; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)MIN((NSUInteger)10, [self itemsIn:section].count); }

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (![self itemsIn:section].count) return nil;
    return TNSectionHeader(section == 0 ? L(@"Songs") : L(@"Videos"), tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return [self itemsIn:section].count ? 26 : 0; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TNTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
    TNTrack *t = [[self itemsIn:indexPath.section] objectAtIndex:(NSUInteger)indexPath.row];
    cell.showsArt = YES;
    [cell showTrack:t number:0];
    cell.moreButton.hidden = YES;
    BOOL chosen = [t.videoId isEqualToString:self.track.videoId];
    cell.accessoryView = chosen ? [[UIImageView alloc] initWithImage:[[TNTheme shared] icon:TNIconCheck size:20 color:[[TNTheme shared] accentTextColor]]] : nil;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    TNTrack *t = [[self itemsIn:indexPath.section] objectAtIndex:(NSUInteger)indexPath.row];
    BOOL wasPlaying = [[TNPlayer shared] isCurrent:self.track];
    [[TNMatcher shared] setVideoId:t.videoId forTrack:self.track];
    [TNRouter toast:L(@"This version plays from now on")];
    [self close];
    if (wasPlaying) {
        // (the song starts again in its new version)
        TNPlayer *player = [TNPlayer shared];
        [player playTracks:player.contextTracks.count ? player.contextTracks : @[ self.track ]
                startingAt:player.contextIndex >= 0 ? (NSUInteger)player.contextIndex : 0
                contextURI:player.contextURI contextName:player.contextName];
    }
}

@end
