#import "TNNowPlayingViewController.h"
#import "TNPlayer.h"
#import "TNRouter.h"
#import "TNCells.h"
#import "TNTheme.h"
#import "TNModels.h"
#import "TNYTMusic.h"
#import "TNLyrics.h"
#import "TNLibrary.h"
#import "TNImageLoader.h"
#import "TNUtils.h"
#import "TNModern.h"
#import "TNCommon.h"
#import <MediaPlayer/MediaPlayer.h>

#pragma mark - Lyrics

@interface TNLyricsViewController ()
@property (nonatomic, copy) NSString *shownKey;
@property (nonatomic, strong) NSArray *lines;       // NSDictionary {ms, text}
@property (nonatomic) BOOL synced;
@property (nonatomic) NSInteger currentLine;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, strong) TNHTTPTask *task;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation TNLyricsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.tableView.contentInset = UIEdgeInsetsMake(30, 0, 80, 0);
    self.currentLine = -1;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:TNPlayerDidChangeNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}

// The song playing now (its lyrics are fetched once it is known what really plays)
- (void)refresh
{
    if (!self.isViewLoaded || self.view.hidden) return;
    if (!self.timer && self.view.window) self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    TNPlayer *player = [TNPlayer shared];
    TNTrack *t = player.currentTrack;
    NSString *videoId = player.currentVideoId ?: t.videoId;
    NSString *key = t ? [NSString stringWithFormat:@"%@|%@", [t key], videoId ?: @""] : nil;
    if ([key isEqualToString:self.shownKey]) return;
    self.shownKey = key;
    [self.task cancel];
    self.lines = @[];
    self.synced = NO;
    self.currentLine = -1;
    self.source = nil;
    self.message = t ? L(@"Loading lyrics…") : L(@"Nothing playing");
    [self.tableView reloadData];
    if (!t || (!videoId.length && [t isApple] && !t.matchFailed)) return;   // (an Apple song still being looked up)
    __weak TNLyricsViewController *weakSelf = self;
    self.task = [TNLyrics lyricsFor:t videoId:videoId durationMs:player.durationMs completion:^(TNLyricsResult *result, NSError *error) {
        TNLyricsViewController *me = weakSelf;
        if (!me || ![key isEqualToString:me.shownKey]) return;
        me.lines = result.lines ?: @[];
        me.synced = result.synced;
        me.source = result.source.length ? [NSString stringWithFormat:L(@"Lyrics: %@"), result.source] : nil;
        me.message = me.lines.count ? nil : L(@"No lyrics for this song.");
        [me.tableView reloadData];
        if (me.lines.count) [me.tableView scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:NO];
        [me tick];
    }];
}

- (void)tick
{
    if (!self.synced || !self.lines.count || self.view.hidden) return;
    NSInteger ms = [TNPlayer shared].positionMs + 300;
    NSInteger line = -1;
    for (NSUInteger i = 0; i < self.lines.count; i++) {
        if ([self.lines[i][@"ms"] integerValue] <= ms) line = (NSInteger)i; else break;
    }
    if (line == self.currentLine) return;
    NSInteger old = self.currentLine;
    self.currentLine = line;
    NSMutableArray *rows = [NSMutableArray array];
    if (old >= 0 && old < (NSInteger)self.lines.count) [rows addObject:[NSIndexPath indexPathForRow:old inSection:0]];
    if (line >= 0) [rows addObject:[NSIndexPath indexPathForRow:line inSection:0]];
    [self.tableView reloadRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationNone];
    if (line >= 0 && !self.tableView.isDragging && !self.tableView.isDecelerating) {
        [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:line inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    }
}

- (UIFont *)lineFont { return [UIFont fontWithName:@"HelveticaNeue-Bold" size:TNIsPad() ? 22 : 18] ?: [UIFont boldSystemFontOfSize:19]; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.message ? 1 : (NSInteger)self.lines.count + (self.source.length ? 1 : 0);
}

- (NSString *)textAt:(NSIndexPath *)ip
{
    if (self.message) return self.message;
    if ((NSUInteger)ip.row < self.lines.count) return self.lines[(NSUInteger)ip.row][@"text"];
    return self.source;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.message) return 80;
    NSString *text = [self textAt:indexPath];
    if (!text.length) return 18;
    BOOL source = (NSUInteger)indexPath.row >= self.lines.count;
    UIFont *font = source ? [[TNTheme shared] smallFont] : [self lineFont];
    CGSize s = [text sizeWithFont:font constrainedToSize:CGSizeMake(tableView.bounds.size.width - 40, 400) lineBreakMode:NSLineBreakByWordWrapping];
    return ceilf(s.height) + (source ? 24 : 12);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"line"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"line"];
    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.text = [self textAt:indexPath];
    BOOL source = !self.message && (NSUInteger)indexPath.row >= self.lines.count;
    cell.textLabel.font = source ? [[TNTheme shared] smallFont] : [self lineFont];
    cell.textLabel.textAlignment = self.message ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    if (self.message || source) {
        cell.textLabel.textColor = [[TNTheme shared] secondaryTextColor];
    } else {
        BOOL current = indexPath.row == self.currentLine;
        BOOL past = self.synced && indexPath.row < self.currentLine;
        cell.textLabel.textColor = current ? [UIColor whiteColor] : (past ? [UIColor colorWithWhite:1 alpha:0.55] : [UIColor colorWithWhite:1 alpha:self.synced ? 0.32 : 0.88]);
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    // (a line in time: the song jumps there)
    if (!self.synced || self.message || (NSUInteger)indexPath.row >= self.lines.count) return;
    [[TNPlayer shared] seekToMs:[self.lines[(NSUInteger)indexPath.row][@"ms"] integerValue]];
}

@end

#pragma mark - Queue

enum { TNQueueNow, TNQueueUser, TNQueueNext, TNQueueSectionCount };

@interface TNQueueViewController ()
@property (nonatomic, strong) NSArray *upcoming;
@property (nonatomic, strong) UIButton *editButton;
- (void)refresh;
@end

@implementation TNQueueViewController

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStylePlain])) self.title = L(@"Queue");
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    self.tableView.rowHeight = 56;
    [self.tableView registerClass:[TNTrackCell class] forCellReuseIdentifier:@"track"];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 40)];
    self.editButton = [[TNTheme shared] outlineButtonWithTitle:L(@"Edit")];
    self.editButton.frame = CGRectMake(320 - 96, 6, 86, 28);
    self.editButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.editButton addTarget:self action:@selector(toggleEditing) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.editButton];
    self.tableView.tableHeaderView = header;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:TNPlayerDidChangeNotification object:nil];
    [self refresh];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)toggleEditing
{
    [self.tableView setEditing:!self.tableView.editing animated:YES];
    [self.editButton setTitle:[(self.tableView.editing ? L(@"Done") : L(@"Edit")) uppercaseString] forState:UIControlStateNormal];
}

- (void)refresh
{
    if (self.tableView.editing) return;   // (the rows stay while they are moved)
    self.upcoming = [[TNPlayer shared] upcomingTracks:100];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return TNQueueSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    TNPlayer *p = [TNPlayer shared];
    if (section == TNQueueNow) return p.currentTrack ? 1 : 0;
    if (section == TNQueueUser) return (NSInteger)p.userQueue.count;
    return (NSInteger)self.upcoming.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (![self tableView:tableView numberOfRowsInSection:section]) return nil;
    NSString *title = section == TNQueueNow ? L(@"Now playing") : section == TNQueueUser ? L(@"Next in queue") :
                      [NSString stringWithFormat:L(@"Next from: %@"), [TNPlayer shared].contextName ?: @""];
    return TNSectionHeader(title, tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return [self tableView:tableView numberOfRowsInSection:section] ? 26 : 0;
}

- (TNTrack *)trackAt:(NSIndexPath *)ip
{
    TNPlayer *p = [TNPlayer shared];
    if (ip.section == TNQueueNow) return p.currentTrack;
    if (ip.section == TNQueueUser) return p.userQueue[(NSUInteger)ip.row];
    return self.upcoming[(NSUInteger)ip.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TNTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"track" forIndexPath:indexPath];
    cell.showsArt = YES;
    [cell showTrack:[self trackAt:indexPath] number:0];
    cell.moreButton.hidden = YES;
    cell.showsReorderControl = YES;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return indexPath.section != TNQueueNow; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return indexPath.section != TNQueueNow; }

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from toProposedIndexPath:(NSIndexPath *)to
{
    // (a song moves within its own part of the queue)
    if (to.section == from.section) return to;
    NSInteger rows = [self tableView:tableView numberOfRowsInSection:from.section];
    return [NSIndexPath indexPathForRow:to.section < from.section ? 0 : MAX(0, rows - 1) inSection:from.section];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to
{
    TNPlayer *p = [TNPlayer shared];
    if (from.section == TNQueueUser) [p moveQueueItemFrom:(NSUInteger)from.row to:(NSUInteger)to.row];
    else if (from.section == TNQueueNext) {
        [p moveUpcomingFrom:(NSUInteger)from.row to:(NSUInteger)to.row];
        NSMutableArray *u = [self.upcoming mutableCopy];
        id x = u[(NSUInteger)from.row];
        [u removeObjectAtIndex:(NSUInteger)from.row];
        [u insertObject:x atIndex:(NSUInteger)to.row];
        self.upcoming = u;
    }
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    TNPlayer *p = [TNPlayer shared];
    if (indexPath.section == TNQueueUser) [p removeFromQueueAtIndex:(NSUInteger)indexPath.row];
    else if (indexPath.section == TNQueueNext) {
        [p removeUpcomingAtIndex:(NSUInteger)indexPath.row];
        NSMutableArray *u = [self.upcoming mutableCopy];
        [u removeObjectAtIndex:(NSUInteger)indexPath.row];
        self.upcoming = u;
    }
    [tableView deleteRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationFade];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath { return L(@"Remove"); }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end

#pragma mark - Now playing

@interface TNNowPlayingViewController ()
@property (nonatomic, strong) UIImageView *backdrop;
@property (nonatomic, strong) UIView *dim;
@property (nonatomic, strong) TNImageView *art;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UILabel *contextLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *artistButton;
@property (nonatomic, strong) UIButton *heartButton;
@property (nonatomic, strong) UISlider *progress;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *remainingLabel;
@property (nonatomic, strong) UILabel *formatLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *repeatButton;
@property (nonatomic, strong) UIButton *lyricsButton;
@property (nonatomic, strong) UIButton *queueButton;
@property (nonatomic, strong) UIButton *sleepButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) MPVolumeView *volume;
@property (nonatomic, strong) TNLyricsViewController *lyrics;
@property (nonatomic, strong) TNQueueViewController *queue;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL scrubbing;
@property (nonatomic) BOOL liked;
@property (nonatomic, copy) NSString *shownURI;
@property (nonatomic, copy) NSString *backdropURL;
@end

@implementation TNNowPlayingViewController

- (UIButton *)button:(TNIcon)icon size:(CGFloat)size action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setImage:[[TNTheme shared] icon:icon size:size] forState:UIControlStateNormal];
    b.showsTouchWhenHighlighted = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    return b;
}

- (UILabel *)label:(UIFont *)font color:(UIColor *)color
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.font = font;
    l.textColor = color;
    l.backgroundColor = [UIColor clearColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
    l.shadowOffset = CGSizeMake(0, 1);
    [self.view addSubview:l];
    return l;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    TNTheme *theme = [TNTheme shared];
    self.view.backgroundColor = [theme plainBackgroundColor];
    self.backdrop = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backdrop.contentMode = UIViewContentModeScaleAspectFill;
    self.backdrop.clipsToBounds = YES;
    self.backdrop.alpha = 0.35;
    [self.view addSubview:self.backdrop];
    self.dim = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:self.dim];

    self.art = [[TNImageView alloc] initWithFrame:CGRectZero];
    self.art.contentMode = UIViewContentModeScaleAspectFill;
    self.art.clipsToBounds = YES;
    self.art.maxPixels = 1024;
    [self.view addSubview:self.art];

    self.lyrics = [[TNLyricsViewController alloc] initWithStyle:UITableViewStylePlain];
    [self addChildViewController:self.lyrics];
    [self.view addSubview:self.lyrics.view];
    [self.lyrics didMoveToParentViewController:self];
    self.queue = [[TNQueueViewController alloc] init];
    [self addChildViewController:self.queue];
    [self.view addSubview:self.queue.view];
    [self.queue didMoveToParentViewController:self];

    self.closeButton = [self button:TNIconChevronDown size:24 action:@selector(close)];
    self.closeButton.accessibilityLabel = L(@"Close");
    self.moreButton = [self button:TNIconMore size:22 action:@selector(more)];
    self.sleepButton = [self button:TNIconMoon size:20 action:@selector(sleepTimer)];
    self.sleepButton.accessibilityLabel = L(@"Sleep timer");
    self.contextLabel = [self label:[theme sectionFont] color:[theme secondaryTextColor]];
    self.contextLabel.numberOfLines = 2;
    self.titleLabel = [self label:[UIFont fontWithName:@"HelveticaNeue-Bold" size:TNIsPad() ? 24 : 19] ?: [UIFont boldSystemFontOfSize:20] color:[UIColor whiteColor]];
    self.artistButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.artistButton.titleLabel.font = [UIFont fontWithName:@"HelveticaNeue" size:TNIsPad() ? 17 : 15] ?: [UIFont systemFontOfSize:16];
    [self.artistButton setTitleColor:[theme secondaryTextColor] forState:UIControlStateNormal];
    [self.artistButton setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
    [self.artistButton addTarget:self action:@selector(openArtist) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.artistButton];
    self.heartButton = [self button:TNIconThumbUp size:24 action:@selector(toggleLike)];
    self.progress = [[UISlider alloc] initWithFrame:CGRectZero];
    [self.progress addTarget:self action:@selector(scrubStarted) forControlEvents:UIControlEventTouchDown];
    [self.progress addTarget:self action:@selector(scrubEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.progress addTarget:self action:@selector(scrubMoved) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.progress];
    self.elapsedLabel = [self label:[UIFont fontWithName:@"HelveticaNeue" size:12] ?: [UIFont systemFontOfSize:12] color:[theme secondaryTextColor]];
    self.elapsedLabel.textAlignment = NSTextAlignmentLeft;
    self.remainingLabel = [self label:[UIFont fontWithName:@"HelveticaNeue" size:12] ?: [UIFont systemFontOfSize:12] color:[theme secondaryTextColor]];
    self.remainingLabel.textAlignment = NSTextAlignmentRight;
    self.formatLabel = [self label:[UIFont fontWithName:@"HelveticaNeue" size:11] ?: [UIFont systemFontOfSize:11] color:[theme tertiaryTextColor]];
    self.playButton = [self button:TNIconPlay size:54 action:@selector(togglePlay)];
    self.previousButton = [self button:TNIconPrevious size:30 action:@selector(previous)];
    self.nextButton = [self button:TNIconNext size:30 action:@selector(next)];
    self.shuffleButton = [self button:TNIconShuffle size:24 action:@selector(toggleShuffle)];
    self.repeatButton = [self button:TNIconRepeat size:24 action:@selector(cycleRepeat)];
    self.lyricsButton = [self button:TNIconLyrics size:24 action:@selector(toggleLyrics)];
    self.queueButton = [self button:TNIconQueue size:24 action:@selector(toggleQueue)];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
    self.volume = [[MPVolumeView alloc] initWithFrame:CGRectZero];
    [self.volume setMinimumVolumeSliderImage:[theme sliderTrackImageFilled:YES] forState:UIControlStateNormal];
    [self.volume setMaximumVolumeSliderImage:[theme sliderTrackImageFilled:NO] forState:UIControlStateNormal];
    [self.volume setVolumeThumbImage:[theme sliderThumbImage] forState:UIControlStateNormal];
    [self.view addSubview:self.volume];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(update) name:TNPlayerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(libraryChanged) name:TNLibraryDidChangeNotification object:nil];
    [self update];
}

- (void)libraryChanged
{
    self.shownURI = nil;
    [self update];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self showPanel];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return TNIsPad() ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskPortrait; }

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGSize s = self.view.bounds.size;
    BOOL landscape = s.width > s.height;
    // iOS 6 puts the view under the status bar; from iOS 7 on it lies behind it (hidden here), and iOS 11+ has the notch
    CGFloat top = TNModernTopInset(self.view, 0);
    if (top < 20 && TNModernIOS()) top = 20;
    self.closeButton.frame = CGRectMake(8, top + 4, 44, 44);
    self.moreButton.frame = CGRectMake(s.width - 52, top + 4, 44, 44);
    self.sleepButton.frame = CGRectMake(s.width - 96, top + 4, 44, 44);
    self.contextLabel.frame = CGRectMake(104, top + 6, s.width - 208, 36);
    CGFloat controlsH = TNIsPad() ? 250 : 210;
    if (landscape && TNIsPad()) {
        // the cover (or lyrics/queue) on the left, everything else on the right
        CGFloat side = MIN(s.height - 120, s.width / 2 - 40);
        CGRect panel = CGRectMake(40, (s.height - side) / 2 + 10, side, side);
        self.art.frame = panel;
        self.lyrics.view.frame = panel;
        self.queue.view.frame = panel;
        CGFloat x = 40 + side + 40, w = s.width - x - 40;
        [self layoutControlsInRect:CGRectMake(x, (s.height - controlsH) / 2, w, controlsH)];
    } else {
        CGFloat side = MIN(s.width - (TNIsPad() ? 140 : 40), s.height - controlsH - 110);
        CGRect panel = CGRectMake((s.width - side) / 2, top + 60, side, side);
        self.art.frame = panel;
        self.lyrics.view.frame = CGRectMake(20, top + 50, s.width - 40, side + 20);
        self.queue.view.frame = CGRectMake(0, top + 50, s.width, side + 20);
        CGFloat w = MIN(s.width - 40, 560);
        [self layoutControlsInRect:CGRectMake((s.width - w) / 2, CGRectGetMaxY(panel) + 18, w, controlsH)];
    }
}

- (void)layoutControlsInRect:(CGRect)r
{
    CGFloat x = r.origin.x, w = r.size.width, y = r.origin.y;
    self.titleLabel.frame = CGRectMake(x + 40, y, w - 80, 28);
    self.heartButton.frame = CGRectMake(x + w - 40, y - 6, 40, 40);
    self.artistButton.frame = CGRectMake(x + 40, y + 28, w - 80, 24);
    y += 64;
    self.progress.frame = CGRectMake(x, y, w, 22);
    self.elapsedLabel.frame = CGRectMake(x, y + 22, 60, 16);
    self.remainingLabel.frame = CGRectMake(x + w - 60, y + 22, 60, 16);
    self.formatLabel.frame = CGRectMake(x + 60, y + 22, w - 120, 16);
    y += 48;
    CGFloat cx = x + w / 2;
    self.playButton.frame = CGRectMake(cx - 36, y, 72, 64);
    self.spinner.center = self.playButton.center;
    self.previousButton.frame = CGRectMake(cx - 110, y + 8, 56, 48);
    self.nextButton.frame = CGRectMake(cx + 54, y + 8, 56, 48);
    self.shuffleButton.frame = CGRectMake(x, y + 10, 44, 44);
    self.repeatButton.frame = CGRectMake(x + w - 44, y + 10, 44, 44);
    y += 74;
    self.lyricsButton.frame = CGRectMake(x, y, 44, 44);
    self.queueButton.frame = CGRectMake(x + w - 44, y, 44, 44);
    self.volume.frame = CGRectMake(x + 60, y + 12, w - 120, 22);
}

- (void)showPanel
{
    self.art.hidden = self.panel != TNNowPlayingArt;
    self.lyrics.view.hidden = self.panel != TNNowPlayingLyrics;
    self.queue.view.hidden = self.panel != TNNowPlayingQueue;
    TNTheme *theme = [TNTheme shared];
    [self.lyricsButton setImage:[theme icon:TNIconLyrics size:24 color:self.panel == TNNowPlayingLyrics ? [theme accentColor] : [UIColor whiteColor]] forState:UIControlStateNormal];
    [self.queueButton setImage:[theme icon:TNIconQueue size:24 color:self.panel == TNNowPlayingQueue ? [theme accentColor] : [UIColor whiteColor]] forState:UIControlStateNormal];
    if (self.panel == TNNowPlayingLyrics) [self.lyrics refresh];
    if (self.panel == TNNowPlayingQueue) [self.queue refresh];
}

- (void)setPanel:(TNNowPlayingPanel)panel
{
    _panel = panel;
    if (self.isViewLoaded) [self showPanel];
}

#pragma mark - State

- (void)update
{
    TNPlayer *player = [TNPlayer shared];
    TNTheme *theme = [TNTheme shared];
    TNTrack *t = player.currentTrack;
    if (!t) { [self close]; return; }
    self.titleLabel.text = [TNUtils displayText:t.name];
    [self.artistButton setTitle:[TNUtils displayText:[t artistNames]] forState:UIControlStateNormal];
    NSString *context = player.contextName.length ? player.contextName : t.album.name;
    self.contextLabel.text = context.length ? [NSString stringWithFormat:@"%@\n%@", [L(@"Playing from") uppercaseString], context] : @"";
    NSString *url = [t imageURLForSize:640];
    [self.art setImageURL:url placeholder:[theme artPlaceholderWithSize:300]];
    if (url && ![url isEqualToString:self.backdropURL]) {
        self.backdropURL = url;
        __weak TNNowPlayingViewController *weakSelf = self;
        [[TNImageLoader shared] loadImage:url maxPixels:200 completion:^(UIImage *image) {
            if ([weakSelf.backdropURL isEqualToString:url]) weakSelf.backdrop.image = image;
        }];
    }
    [self.playButton setImage:[theme icon:player.playing ? TNIconPause : TNIconPlay size:54] forState:UIControlStateNormal];
    UIColor *on = [theme accentColor], *off = [UIColor whiteColor];
    [self.shuffleButton setImage:[theme icon:TNIconShuffle size:24 color:player.shuffle ? on : off] forState:UIControlStateNormal];
    [self.repeatButton setImage:[theme icon:player.repeat == TNRepeatOne ? TNIconRepeatOne : TNIconRepeat size:24 color:player.repeat != TNRepeatOff ? on : off] forState:UIControlStateNormal];
    self.shownURI = [t key];
    self.liked = [[TNLibrary shared] isLiked:t];
    [self showLiked];
    [self tick];
}

- (void)showLiked
{
    TNTheme *theme = [TNTheme shared];
    [self.heartButton setImage:[theme icon:self.liked ? TNIconThumbUpFilled : TNIconThumbUp size:24 color:self.liked ? [theme accentTextColor] : [UIColor whiteColor]] forState:UIControlStateNormal];
}

- (void)tick
{
    TNPlayer *player = [TNPlayer shared];
    NSInteger duration = player.durationMs, position = player.positionMs;
    if (!self.scrubbing) {
        self.progress.value = duration > 0 ? (float)position / (float)duration : 0;
        self.elapsedLabel.text = TNFormatDurationMs(position);
        self.remainingLabel.text = duration > 0 ? [@"-" stringByAppendingString:TNFormatDurationMs(MAX(0, duration - position))] : @"";
    }
    NSString *format = player.formatName ?: @"";
    NSString *sleep = nil;
    if (player.sleepAtEndOfSong) sleep = L(@"Sleep: end of song");
    else if (player.sleepAt) sleep = [NSString stringWithFormat:L(@"Sleep: %@"), TNFormatDurationMs((NSInteger)MAX(0, [player.sleepAt timeIntervalSinceNow] * 1000))];
    self.formatLabel.text = sleep ? (format.length ? [NSString stringWithFormat:@"%@ • %@", format, sleep] : sleep) : format;
    BOOL sleeping = sleep != nil;
    if (sleeping != self.sleepButton.selected) {
        self.sleepButton.selected = sleeping;
        TNTheme *theme = [TNTheme shared];
        [self.sleepButton setImage:[theme icon:TNIconMoon size:20 color:sleeping ? [theme accentColor] : [UIColor whiteColor]] forState:UIControlStateNormal];
        [self.sleepButton setImage:[theme icon:TNIconMoon size:20 color:sleeping ? [theme accentColor] : [UIColor whiteColor]] forState:UIControlStateSelected];
    }
    if (player.buffering && player.playing) { [self.spinner startAnimating]; self.playButton.alpha = 0.15; }
    else { [self.spinner stopAnimating]; self.playButton.alpha = 1; }
    if (self.panel == TNNowPlayingLyrics) [self.lyrics tick];
}

#pragma mark - Actions

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)togglePlay { [[TNPlayer shared] togglePlay]; }
- (void)next { [[TNPlayer shared] next]; }
- (void)previous { [[TNPlayer shared] previous]; }
- (void)toggleShuffle { TNPlayer *p = [TNPlayer shared]; p.shuffle = !p.shuffle; }

- (void)cycleRepeat
{
    TNPlayer *p = [TNPlayer shared];
    p.repeat = p.repeat == TNRepeatOff ? TNRepeatAll : p.repeat == TNRepeatAll ? TNRepeatOne : TNRepeatOff;
}

- (void)toggleLyrics { self.panel = self.panel == TNNowPlayingLyrics ? TNNowPlayingArt : TNNowPlayingLyrics; }
- (void)toggleQueue { self.panel = self.panel == TNNowPlayingQueue ? TNNowPlayingArt : TNNowPlayingQueue; }

- (void)toggleLike
{
    TNTrack *t = [TNPlayer shared].currentTrack;
    if (t) [TNRouter toggleLike:t];
}

- (void)openArtist
{
    TNArtist *a = nil;
    for (TNArtist *x in [TNPlayer shared].currentTrack.artists) if (x.browseId.length) { a = x; break; }
    if (!a) return;
    [self dismissViewControllerAnimated:YES completion:^{ [TNRouter openArtist:a]; }];
}

- (void)more
{
    TNTrack *t = [TNPlayer shared].currentTrack;
    if (t) [TNRouter showActionsForTrack:t fromView:self.moreButton inController:self];
}

- (void)sleepTimer { [TNRouter showSleepTimerFromView:self.sleepButton inController:self]; }

- (void)scrubStarted { self.scrubbing = YES; }

- (void)scrubMoved
{
    NSInteger duration = [TNPlayer shared].durationMs;
    NSInteger at = (NSInteger)(self.progress.value * duration);
    self.elapsedLabel.text = TNFormatDurationMs(at);
    self.remainingLabel.text = [@"-" stringByAppendingString:TNFormatDurationMs(MAX(0, duration - at))];
}

- (void)scrubEnded
{
    NSInteger duration = [TNPlayer shared].durationMs;
    if (duration > 0) [[TNPlayer shared] seekToMs:(NSInteger)(self.progress.value * duration)];
    self.scrubbing = NO;
}

@end
