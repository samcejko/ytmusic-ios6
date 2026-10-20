#import "TNPlaylistPickerViewController.h"
#import "TNCells.h"
#import "TNImageLoader.h"
#import "TNRouter.h"
#import "TNTheme.h"
#import "TNModels.h"
#import "TNLibrary.h"
#import "TNAppleMusic.h"
#import "TNCommon.h"

enum { TNPickOwn, TNPickApple, TNPickSectionCount };

@interface TNPlaylistPickerViewController ()
@property (nonatomic, copy) NSArray *tracks;
@property (nonatomic, strong) NSArray *own;
@property (nonatomic, strong) NSArray *apple;
@property (nonatomic) BOOL busy;
@end

@implementation TNPlaylistPickerViewController

- (instancetype)initWithTracks:(NSArray *)tracks
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _tracks = [tracks copy];
        self.refreshable = NO;
        self.title = L(@"Add to playlist");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = 60;
    [self.tableView registerClass:[TNMediaCell class] forCellReuseIdentifier:@"media"];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(close)];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)load
{
    self.own = [[TNLibrary shared] ownPlaylists];
    self.apple = [[TNAppleMusic shared] connected] ? [[TNAppleMusic shared] editablePlaylists] : nil;
    [self finishLoadingWithError:nil empty:NO emptyMessage:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.apple ? TNPickSectionCount : 1; }

// the first row of each part makes a new playlist
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return 1 + (NSInteger)(section == TNPickOwn ? self.own.count : self.apple.count);
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    return TNSectionHeader(section == TNPickOwn ? L(@"Muzika") : L(@"Apple Music"), tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return 26; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TNMediaCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media" forIndexPath:indexPath];
    TNTheme *theme = [TNTheme shared];
    cell.round = NO;
    if (indexPath.row == 0) {
        [cell showTitle:indexPath.section == TNPickOwn ? L(@"New playlist…") : L(@"New Apple Music playlist…") subtitle:nil imageURL:nil];
        cell.art.image = [theme icon:TNIconPlus size:26 color:[theme accentTextColor]];
        cell.art.contentMode = UIViewContentModeCenter;
        cell.art.backgroundColor = [theme rowHighlightColor];
        return cell;
    }
    cell.art.backgroundColor = [UIColor clearColor];
    NSArray *list = indexPath.section == TNPickOwn ? self.own : self.apple;
    [cell showItem:[list objectAtIndex:(NSUInteger)indexPath.row - 1]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy) return;
    BOOL apple = indexPath.section == TNPickApple;
    NSArray *tracks = self.tracks;
    if (indexPath.row == 0) {
        TNTrack *first = tracks.firstObject;
        NSString *suggestion = tracks.count == 1 ? [NSString stringWithFormat:@"%@", first.name ?: @""] : @"";
        __weak TNPlaylistPickerViewController *weakSelf = self;
        [TNRouter promptWithTitle:apple ? L(@"New Apple Music playlist") : L(@"New playlist") message:nil text:suggestion
                      placeholder:L(@"Name") button:L(@"Create") completion:^(NSString *name) {
            if (!name.length) return;
            if (!apple) {
                [[TNLibrary shared] createPlaylistNamed:name tracks:tracks];
                [TNRouter toast:[NSString stringWithFormat:L(@"Added to %@"), name]];
                [weakSelf close];
                return;
            }
            weakSelf.busy = YES;
            [TNRouter toast:L(@"Making the playlist in Apple Music…")];
            [[TNAppleMusic shared] createPlaylistNamed:name tracks:tracks completion:^(TNPlaylist *playlist, NSError *error) {
                weakSelf.busy = NO;
                [TNRouter toast:playlist ? [NSString stringWithFormat:L(@"Added to %@"), name] : error.localizedDescription];
                if (playlist) [weakSelf close];
            }];
        }];
        return;
    }
    TNPlaylist *p = [(apple ? self.apple : self.own) objectAtIndex:(NSUInteger)indexPath.row - 1];
    if (!apple) {
        NSUInteger added = [[TNLibrary shared] addTracks:tracks toPlaylist:p];
        [TNRouter toast:added ? [NSString stringWithFormat:L(@"Added to %@"), p.name ?: @""] : L(@"Already in this playlist")];
        [self close];
        return;
    }
    self.busy = YES;
    [TNRouter toast:L(@"Adding in Apple Music…")];
    __weak TNPlaylistPickerViewController *weakSelf = self;
    [[TNAppleMusic shared] addTracks:tracks toPlaylist:p completion:^(NSUInteger added, NSError *error) {
        weakSelf.busy = NO;
        [TNRouter toast:added ? [NSString stringWithFormat:L(@"Added to %@"), p.name ?: @""] : error.localizedDescription];
        if (added) [weakSelf close];
    }];
}

@end
