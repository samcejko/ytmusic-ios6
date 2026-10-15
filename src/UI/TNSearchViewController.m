#import "TNSearchViewController.h"
#import "TNCells.h"
#import "TNRouter.h"
#import "TNTheme.h"
#import "TNModels.h"
#import "TNYTMusic.h"
#import "TNAppleMusic.h"
#import "TNPlayer.h"
#import "TNSettings.h"
#import "TNUtils.h"
#import "TNCommon.h"

typedef NS_ENUM(NSInteger, TNSearchMode) { TNSearchModeIdle, TNSearchModeSuggest, TNSearchModeResults };

@interface TNSearchViewController () <UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIScrollView *chips;
@property (nonatomic, strong) NSArray *chipButtons;
@property (nonatomic) TNSearchFilter filter;
@property (nonatomic) TNSearchMode mode;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, strong) NSArray *shelves;         // TNShelf (results)
@property (nonatomic, strong) NSMutableArray *filtered; // the items of a filtered search, page after page
@property (nonatomic, copy) NSString *continuation;
@property (nonatomic, strong) TNHTTPTask *moreTask;
@property (nonatomic, strong) NSArray *suggestions;
@property (nonatomic, strong) TNHTTPTask *suggestTask;
@property (nonatomic, strong) NSTimer *debounce;
@property (nonatomic) NSUInteger generation;
@end

@implementation TNSearchViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        self.title = L(@"Search");
        self.refreshable = NO;
        _shelves = @[];
        _suggestions = @[];
        _filtered = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    TNTheme *theme = [TNTheme shared];
    [self.tableView registerClass:[TNTrackCell class] forCellReuseIdentifier:@"track"];
    [self.tableView registerClass:[TNMediaCell class] forCellReuseIdentifier:@"media"];
    CGFloat w = MAX((CGFloat)320, self.view.bounds.size.width);   // (no width yet in viewDidLoad on newer iOS; the table widens it)
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 44 + 40)];
    header.backgroundColor = [UIColor clearColor];
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.searchBar.placeholder = L(@"Songs, albums, artists or a link");
    self.searchBar.delegate = self;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    [theme applyToSearchBar:self.searchBar];
    [header addSubview:self.searchBar];
    self.chips = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 44, w, 40)];
    self.chips.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.chips.showsHorizontalScrollIndicator = NO;
    self.chips.scrollsToTop = NO;
    NSArray *titles = @[ L(@"All"), L(@"Songs"), L(@"Videos"), L(@"Albums"), L(@"Artists"), L(@"Playlists") ];
    NSMutableArray *buttons = [NSMutableArray array];
    CGFloat x = 10;
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:13] ?: [UIFont boldSystemFontOfSize:13];
        b.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
        b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        CGFloat bw = [theme widthForButton:b minimum:56];
        b.frame = CGRectMake(x, 7, bw, 27);
        x += bw + 8;
        [self.chips addSubview:b];
        [buttons addObject:b];
    }
    self.chips.contentSize = CGSizeMake(x + 4, 40);
    [header addSubview:self.chips];
    self.chipButtons = buttons;
    [self showChips];
    self.tableView.tableHeaderView = header;
}

- (void)showChips
{
    TNTheme *theme = [TNTheme shared];
    for (UIButton *b in self.chipButtons) {
        BOOL on = b.tag == self.filter;
        [b setBackgroundImage:[theme chipImageSelected:on] forState:UIControlStateNormal];
        [b setTitleColor:on ? [UIColor colorWithWhite:0.08 alpha:1] : [theme primaryTextColor] forState:UIControlStateNormal];
        [b setTitleShadowColor:on ? [UIColor colorWithWhite:1 alpha:0.6] : [UIColor colorWithWhite:0 alpha:0.6] forState:UIControlStateNormal];
        b.titleLabel.shadowOffset = CGSizeMake(0, on ? 1 : -1);
    }
}

- (void)chipTapped:(UIButton *)sender
{
    if (sender.tag == self.filter) return;
    self.filter = (TNSearchFilter)sender.tag;
    [self showChips];
    if (self.query.length) [self runSearch];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    if (scrollView == self.tableView) [self.searchBar resignFirstResponder];
}

- (void)focusSearchField { [self.searchBar becomeFirstResponder]; }

- (void)searchFor:(NSString *)query
{
    self.searchBar.text = query;
    self.query = query;
    [self runSearch];
}

#pragma mark - Loading

- (void)load
{
    if (self.mode == TNSearchModeResults && self.query.length) { [self runSearch]; return; }
    [self finishLoadingWithError:nil empty:NO emptyMessage:nil];
}

- (void)runSearch
{
    NSString *q = [self.query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return;
    if ([TNRouter openURL:q]) { [self.searchBar resignFirstResponder]; return; }
    [TNSettings addRecentSearch:q];
    self.mode = TNSearchModeResults;
    self.shelves = @[];
    [self.filtered removeAllObjects];
    self.continuation = nil;
    [self.moreTask cancel];
    self.moreTask = nil;
    [self.tableView reloadData];
    [self startLoading];
    NSUInteger generation = ++self.generation;
    TNSearchFilter filter = self.filter;
    __weak TNSearchViewController *weakSelf = self;
    [TNYTMusic search:q filter:filter completion:^(TNSearchResults *results, NSError *error) {
        TNSearchViewController *me = weakSelf;
        if (!me || generation != me.generation) return;
        if (filter == TNSearchAll) {
            me.shelves = results.shelves ?: @[];
        } else {
            for (TNShelf *s in results.shelves) [me.filtered addObjectsFromArray:s.items ?: @[]];
            me.continuation = results.continuation;
        }
        BOOL empty = filter == TNSearchAll ? !results || [results empty] : !me.filtered.count;
        [me finishLoadingWithError:empty ? error : nil empty:empty emptyMessage:[NSString stringWithFormat:L(@"Nothing found for \"%@\"."), q]];
    }];
}

- (void)loadMoreIfNeeded
{
    if (self.filter == TNSearchAll || !self.continuation.length || self.moreTask) return;
    NSUInteger generation = self.generation;
    __weak TNSearchViewController *weakSelf = self;
    self.moreTask = [TNYTMusic searchMore:self.continuation completion:^(NSArray *items, NSString *continuation, NSError *error) {
        TNSearchViewController *me = weakSelf;
        if (!me || generation != me.generation) return;
        me.moreTask = nil;
        me.continuation = items.count ? continuation : nil;
        if (items.count) {
            [me.filtered addObjectsFromArray:items];
            [me.tableView reloadData];
        }
    }];
}

- (void)loadSuggestions
{
    NSString *q = self.searchBar.text ?: @"";
    [self.suggestTask cancel];
    if (!q.length) { self.suggestions = @[]; [self.tableView reloadData]; return; }
    __weak TNSearchViewController *weakSelf = self;
    self.suggestTask = [TNYTMusic suggestions:q completion:^(NSArray *texts, NSError *error) {
        TNSearchViewController *me = weakSelf;
        if (!me || me.mode != TNSearchModeSuggest) return;
        me.suggestions = texts ?: @[];
        [me.tableView reloadData];
    }];
}

#pragma mark - Search bar

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    [self.debounce invalidate];
    if (!searchText.length) {
        self.mode = TNSearchModeIdle;
        self.query = nil;
        [self finishLoadingWithError:nil empty:NO emptyMessage:nil];
        return;
    }
    self.mode = TNSearchModeSuggest;
    [self finishLoadingWithError:nil empty:NO emptyMessage:nil];
    self.debounce = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(loadSuggestions) userInfo:nil repeats:NO];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
    [self.debounce invalidate];
    self.query = searchBar.text;
    [self runSearch];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    if (self.mode == TNSearchModeResults) return self.filter == TNSearchAll ? (NSInteger)self.shelves.count : 1;
    return 1;
}

- (NSArray *)itemsIn:(NSInteger)section
{
    if (self.mode != TNSearchModeResults) return @[];
    if (self.filter != TNSearchAll) return self.filtered;
    return [self.shelves[(NSUInteger)section] items] ?: @[];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (self.mode == TNSearchModeIdle) return (NSInteger)MIN((NSUInteger)10, [TNSettings recentSearches].count);
    if (self.mode == TNSearchModeSuggest) return (NSInteger)self.suggestions.count;
    NSInteger n = (NSInteger)[self itemsIn:section].count;
    if (self.filter != TNSearchAll) return n;
    TNShelf *shelf = self.shelves[(NSUInteger)section];
    return shelf.songs ? MIN(n, 8) : MIN(n, 6);
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (![self tableView:tableView numberOfRowsInSection:section]) return nil;
    if (self.mode == TNSearchModeIdle) return TNSectionHeader(L(@"Recent searches"), tableView.bounds.size.width);
    if (self.mode == TNSearchModeSuggest) return nil;
    if (self.filter != TNSearchAll) return nil;
    return TNSectionHeader([self.shelves[(NSUInteger)section] title], tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return [self tableView:tableView viewForHeaderInSection:section] ? 26 : 0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.mode != TNSearchModeResults) return 44;
    id item = [self itemsIn:indexPath.section][(NSUInteger)indexPath.row];
    return [item isKindOfClass:[TNTrack class]] ? 56 : 68;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TNTheme *theme = [TNTheme shared];
    if (self.mode != TNSearchModeResults) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"text"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"text"];
        [theme styleCell:cell];
        BOOL recent = self.mode == TNSearchModeIdle;
        cell.textLabel.text = recent ? [TNSettings recentSearches][(NSUInteger)indexPath.row] : self.suggestions[(NSUInteger)indexPath.row];
        cell.textLabel.font = [theme bodyFont];
        cell.imageView.image = [theme icon:recent ? TNIconClock : TNIconSearch size:18 color:[theme secondaryTextColor]];
        return cell;
    }
    NSArray *items = [self itemsIn:indexPath.section];
    id item = items[(NSUInteger)indexPath.row];
    if (self.filter != TNSearchAll && indexPath.row >= (NSInteger)items.count - 6) [self loadMoreIfNeeded];
    if ([item isKindOfClass:[TNTrack class]]) {
        TNTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
        cell.showsArt = YES;
        [cell showTrack:item number:0];
        [cell.moreButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.moreButton addTarget:self action:@selector(moreTapped:) forControlEvents:UIControlEventTouchUpInside];
        cell.moreButton.tag = indexPath.section * 10000 + indexPath.row;
        return cell;
    }
    TNMediaCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media" forIndexPath:indexPath];
    [cell showItem:item];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.mode == TNSearchModeIdle) { [self searchFor:[TNSettings recentSearches][(NSUInteger)indexPath.row]]; [self.searchBar resignFirstResponder]; return; }
    if (self.mode == TNSearchModeSuggest) { [self searchFor:self.suggestions[(NSUInteger)indexPath.row]]; [self.searchBar resignFirstResponder]; return; }
    NSArray *items = [self itemsIn:indexPath.section];
    id item = items[(NSUInteger)indexPath.row];
    if ([item isKindOfClass:[TNTrack class]]) {
        TNTrack *t = item;
        if ([[TNPlayer shared] isCurrent:t]) { [TNRouter showNowPlaying]; return; }
        [TNRouter openItem:t];   // (the song and its radio, as YouTube Music plays a search result)
        return;
    }
    [TNRouter openItem:item];
}

- (void)moreTapped:(UIButton *)sender
{
    NSArray *items = [self itemsIn:sender.tag / 10000];
    NSInteger row = sender.tag % 10000;
    if (row < (NSInteger)items.count && [items[(NSUInteger)row] isKindOfClass:[TNTrack class]])
        [TNRouter showActionsForTrack:items[(NSUInteger)row] fromView:sender inController:self];
}

@end
