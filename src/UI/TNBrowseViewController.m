#import "TNBrowseViewController.h"
#import "TNCells.h"
#import "TNRouter.h"
#import "TNTheme.h"
#import "TNModels.h"
#import "TNYTMusic.h"
#import "TNPlayer.h"
#import "TNAppleChartsViewController.h"
#import "TNCommon.h"

@interface TNBrowseViewController ()
@property (nonatomic, copy, readwrite) NSString *browseId;
@property (nonatomic, copy) NSString *params;
@property (nonatomic) NSUInteger generation;
@end

@implementation TNBrowseViewController

- (instancetype)initWithBrowseId:(NSString *)browseId params:(NSString *)params title:(NSString *)title
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _browseId = [browseId copy];
        _params = [params copy];
        _shelves = @[];
        self.title = title;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[TNShelfCell class] forCellReuseIdentifier:@"shelf"];
    [self.tableView registerClass:[TNSongGridCell class] forCellReuseIdentifier:@"songs"];
    [self.tableView registerClass:[TNTileRowCell class] forCellReuseIdentifier:@"tiles"];
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation
{
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];
    [self.tableView reloadData];   // (another number of tiles per row, wider song columns)
}

- (NSArray *)shelvesForLoaded:(NSArray *)loaded
{
    if (![self.browseId isEqualToString:@"FEmusic_explore"] || !loaded.count) return loaded ?: @[];
    // Explore: Apple Music's charts first
    TNCategory *charts = [[TNCategory alloc] init];
    charts.title = L(@"Apple Music charts");
    charts.browseId = TNAppleChartsBrowseId;
    charts.colorHex = @"#FA233B";
    TNShelf *shelf = [[TNShelf alloc] init];
    shelf.items = @[ charts ];
    return [@[ shelf ] arrayByAddingObjectsFromArray:loaded];
}

- (void)load
{
    if (!self.browseId.length) {
        self.shelves = [self shelvesForLoaded:@[]];
        [self finishLoadingWithError:nil empty:!self.shelves.count emptyMessage:L(@"Nothing here.")];
        return;
    }
    [self startLoading];
    NSUInteger generation = ++self.generation;
    __weak TNBrowseViewController *weakSelf = self;
    [TNYTMusic browsePage:self.browseId params:self.params completion:^(NSString *title, NSArray *shelves, NSError *error) {
        TNBrowseViewController *me = weakSelf;
        if (!me || generation != me.generation) return;
        if (!me.title.length && title.length) me.title = title;
        me.shelves = [me shelvesForLoaded:shelves];
        [me finishLoadingWithError:me.shelves.count ? nil : error empty:!me.shelves.count emptyMessage:L(@"Nothing here.")];
    }];
}

#pragma mark - Layout of a shelf

- (CGFloat)cardWidth { return TNIsPad() ? 150 : 124; }
- (NSInteger)columns { return MAX(2, (NSInteger)((self.tableView.bounds.size.width - 10) / (TNIsPad() ? 190 : 150))); }
- (CGFloat)songColumnWidth { return MIN(floorf(self.tableView.bounds.size.width * 0.86f), 380); }

- (BOOL)isTiles:(TNShelf *)shelf
{
    if (!shelf.items.count) return NO;
    for (id i in shelf.items) if (![i isKindOfClass:[TNCategory class]]) return NO;
    return YES;
}

- (NSUInteger)songRows:(TNShelf *)shelf { return MIN((NSUInteger)4, MAX((NSUInteger)1, shelf.items.count)); }

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)self.shelves.count; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    TNShelf *shelf = [self.shelves objectAtIndex:(NSUInteger)section];
    if ([self isTiles:shelf]) {
        NSInteger columns = [self columns];
        return ((NSInteger)shelf.items.count + columns - 1) / columns;
    }
    return 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TNShelf *shelf = [self.shelves objectAtIndex:(NSUInteger)indexPath.section];
    if ([self isTiles:shelf]) return [TNTileRowCell heightForWidth:tableView.bounds.size.width columns:[self columns]];
    if (shelf.songs) return [TNSongGridCell heightForRows:[self songRows:shelf]];
    return [TNShelfCell heightForCardWidth:[self cardWidth]];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    TNShelf *shelf = [self.shelves objectAtIndex:(NSUInteger)section];
    if (!shelf.title.length) return nil;
    if (shelf.moreBrowseId.length) return TNSectionHeaderWithMore(shelf.title, tableView.bounds.size.width, self, @selector(moreTapped:), section);
    return TNSectionHeader(shelf.title, tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return [[[self.shelves objectAtIndex:(NSUInteger)section] title] length] ? 26 : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TNShelf *shelf = [self.shelves objectAtIndex:(NSUInteger)indexPath.section];
    if ([self isTiles:shelf]) {
        TNTileRowCell *cell = [tableView dequeueReusableCellWithIdentifier:@"tiles" forIndexPath:indexPath];
        NSInteger columns = [self columns], start = indexPath.row * columns;
        NSRange range = NSMakeRange((NSUInteger)start, (NSUInteger)MIN(columns, (NSInteger)shelf.items.count - start));
        [cell showTiles:[shelf.items subarrayWithRange:range] columns:columns];
        cell.onSelect = ^(id item) { [TNRouter openItem:item]; };
        return cell;
    }
    if (shelf.songs) {
        TNSongGridCell *cell = [tableView dequeueReusableCellWithIdentifier:@"songs" forIndexPath:indexPath];
        [cell showTracks:shelf.items rows:[self songRows:shelf] columnWidth:[self songColumnWidth]];
        __weak TNBrowseViewController *weakSelf = self;
        NSArray *tracks = shelf.items;
        NSString *name = shelf.title;
        cell.onSelect = ^(TNTrack *track, NSUInteger index) {
            if ([[TNPlayer shared] isCurrent:track]) { [TNRouter showNowPlaying]; return; }
            [TNPlayer shared].shuffle = NO;
            [[TNPlayer shared] playTracks:tracks startingAt:index contextURI:nil contextName:name];
        };
        cell.onMore = ^(TNTrack *track, UIView *anchor) { [TNRouter showActionsForTrack:track fromView:anchor inController:weakSelf]; };
        return cell;
    }
    TNShelfCell *cell = [tableView dequeueReusableCellWithIdentifier:@"shelf" forIndexPath:indexPath];
    [cell showItems:shelf.items cardWidth:[self cardWidth]];
    cell.onSelect = ^(id item) { [TNRouter openItem:item]; };
    return cell;
}

- (void)moreTapped:(UIButton *)sender
{
    if (sender.tag < 0 || sender.tag >= (NSInteger)self.shelves.count) return;
    TNShelf *shelf = [self.shelves objectAtIndex:(NSUInteger)sender.tag];
    [TNRouter openBrowseId:shelf.moreBrowseId params:shelf.moreParams title:shelf.title];
}

@end
