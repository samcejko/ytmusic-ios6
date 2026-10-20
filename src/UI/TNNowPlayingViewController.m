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
#import "TNSettings.h"
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
    // (exact row heights: iOS 11 and newer estimate them, and a line far down would land ~100 points off the middle)
    if ([self.tableView respondsToSelector:@selector(setEstimatedRowHeight:)]) [self.tableView setValue:@0 forKey:@"estimatedRowHeight"];
    self.currentLine = -1;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:TNPlayerDidChangeNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
}

// Room above the first line and below the last one, so that the line being sung can always stand a little above the
// middle (the panel is only ~180 points tall on a 3.5" iPhone)
- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat h = self.tableView.bounds.size.height;
    UIEdgeInsets inset = UIEdgeInsetsMake(floorf(h * 0.4f), 0, ceilf(h * 0.6f), 0);
    if (h > 0 && !UIEdgeInsetsEqualToEdgeInsets(inset, self.tableView.contentInset)) {
        self.tableView.contentInset = inset;
        [self scrollToCurrentAnimated:NO];
    }
}

- (void)scrollToCurrentAnimated:(BOOL)animated
{
    UITableView *t = self.tableView;
    if (self.message || self.currentLine < 0 || self.currentLine >= (NSInteger)self.lines.count) {
        [t setContentOffset:CGPointMake(0, -t.contentInset.top) animated:animated];
        return;
    }
    CGRect r = [t rectForRowAtIndexPath:[NSIndexPath indexPathForRow:self.currentLine inSection:0]];
    [t setContentOffset:CGPointMake(0, floorf(CGRectGetMidY(r) - t.bounds.size.height * 0.4f)) animated:animated];
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
        [me scrollToCurrentAnimated:NO];
        [me tick];
    }];
}

- (void)tick
{
    if (!self.synced || !self.lines.count || self.view.hidden) return;
    NSInteger ms = [TNPlayer shared].positionMs + 300;
    NSInteger line = -1;
    for (NSUInteger i = 0; i < self.lines.count; i++) {
        if ([[[self.lines objectAtIndex:i] objectForKey:@"ms"] integerValue] <= ms) line = (NSInteger)i; else break;
    }
    if (line == self.currentLine) return;
    NSInteger old = self.currentLine;
    self.currentLine = line;
    NSMutableArray *rows = [NSMutableArray array];
    if (old >= 0 && old < (NSInteger)self.lines.count) [rows addObject:[NSIndexPath indexPathForRow:old inSection:0]];
    if (line >= 0) [rows addObject:[NSIndexPath indexPathForRow:line inSection:0]];
    [self.tableView reloadRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationNone];
    if (!self.tableView.isDragging && !self.tableView.isDecelerating) [self scrollToCurrentAnimated:YES];
}

// (smaller on a 3.5" screen: more of the song fits in the little panel)
- (UIFont *)lineFont
{
    CGFloat size = TNIsPad() ? 22 : ([UIScreen mainScreen].bounds.size.height < 500 ? 16 : 18);
    return [UIFont fontWithName:@"HelveticaNeue-Bold" size:size] ?: [UIFont boldSystemFontOfSize:size];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.message ? 1 : (NSInteger)self.lines.count + (self.source.length ? 1 : 0);
}

- (NSString *)textAt:(NSIndexPath *)ip
{
    if (self.message) return self.message;
    if ((NSUInteger)ip.row < self.lines.count) return [[self.lines objectAtIndex:(NSUInteger)ip.row] objectForKey:@"text"];
    return self.source;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.message) return 80;
    NSString *text = [self textAt:indexPath];
    if (!text.length) return 18;
    BOOL source = (NSUInteger)indexPath.row >= self.lines.count;
    UIFont *font = source ? [[TNTheme shared] smallFont] : [self lineFont];
    CGSize s = [text sizeWithFont:font constrainedToSize:CGSizeMake(tableView.bounds.size.width - 40, 400) lineBreakMode:UILineBreakModeWordWrap];
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
    cell.textLabel.textAlignment = self.message ? UITextAlignmentCenter : UITextAlignmentLeft;
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
    [[TNPlayer shared] seekToMs:[[[self.lines objectAtIndex:(NSUInteger)indexPath.row] objectForKey:@"ms"] integerValue]];
}

@end

#pragma mark - Queue

enum { TNQueueNow, TNQueueUser, TNQueueNext, TNQueueSectionCount };

@interface TNQueueViewController ()
@property (nonatomic, strong) NSArray *upcoming;
@property (nonatomic, strong) UIButton *editButton;
@property (nonatomic, strong) TNTrack *shownTrack;        // what the rows show (see refresh)
@property (nonatomic) NSUInteger shownQueueCount;
@property (nonatomic) BOOL applyingEdit;                  // the table's own move/delete is going to the player
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
    TNTheme *theme = [TNTheme shared];
    self.editButton = [theme outlineButtonWithTitle:L(@"Done")];
    CGFloat w = [theme widthForButton:self.editButton minimum:86];   // (wide enough for both titles: Czech "HOTOVO"/"UPRAVIT")
    [self.editButton setTitle:[L(@"Edit") uppercaseString] forState:UIControlStateNormal];
    w = MAX(w, [theme widthForButton:self.editButton minimum:86]);
    self.editButton.frame = CGRectMake(320 - 10 - w, 6, w, 28);
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
    if (self.applyingEdit) return;   // (the table changes its rows itself)
    TNPlayer *p = [TNPlayer shared];
    NSArray *upcoming = [p upcomingTracks:100];
    // (while editing the rows stay as they are, unless the next song started: then the rows' indexes would no longer
    // be the player's, and a delete would take out a different song)
    if (self.tableView.editing && p.currentTrack == self.shownTrack && p.userQueue.count == self.shownQueueCount &&
        [upcoming isEqualToArray:self.upcoming ?: @[]]) return;
    self.shownTrack = p.currentTrack;
    self.shownQueueCount = p.userQueue.count;
    self.upcoming = upcoming;
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
    if (ip.section == TNQueueUser) return [p.userQueue objectAtIndex:(NSUInteger)ip.row];
    return [self.upcoming objectAtIndex:(NSUInteger)ip.row];
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
    self.applyingEdit = YES;
    if (from.section == TNQueueUser) [p moveQueueItemFrom:(NSUInteger)from.row to:(NSUInteger)to.row];
    else if (from.section == TNQueueNext) {
        [p moveUpcomingFrom:(NSUInteger)from.row to:(NSUInteger)to.row];
        NSMutableArray *u = [self.upcoming mutableCopy];
        id x = [u objectAtIndex:(NSUInteger)from.row];
        [u removeObjectAtIndex:(NSUInteger)from.row];
        [u insertObject:x atIndex:(NSUInteger)to.row];
        self.upcoming = u;
    }
    self.applyingEdit = NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    TNPlayer *p = [TNPlayer shared];
    self.applyingEdit = YES;
    if (indexPath.section == TNQueueUser) [p removeFromQueueAtIndex:(NSUInteger)indexPath.row];
    else if (indexPath.section == TNQueueNext) {
        [p removeUpcomingAtIndex:(NSUInteger)indexPath.row];
        NSMutableArray *u = [self.upcoming mutableCopy];
        [u removeObjectAtIndex:(NSUInteger)indexPath.row];
        self.upcoming = u;
    }
    self.shownQueueCount = p.userQueue.count;
    [tableView deleteRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationFade];
    self.applyingEdit = NO;
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
@property (nonatomic, strong) UIImageView *topBar;
@property (nonatomic, strong) UIImageView *bottomDock;
@property (nonatomic, strong) UIView *artContainer;
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
    l.textAlignment = UITextAlignmentCenter;
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

    self.topBar = [[UIImageView alloc] initWithImage:[theme navigationBarImage]];
    self.topBar.userInteractionEnabled = NO;
    [self.view addSubview:self.topBar];

    self.bottomDock = [[UIImageView alloc] initWithImage:[theme playerBarImage]];
    self.bottomDock.userInteractionEnabled = NO;
    [self.view addSubview:self.bottomDock];

    self.artContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.artContainer.backgroundColor = [UIColor blackColor];
    [self.view addSubview:self.artContainer];

    self.art = [[TNImageView alloc] initWithFrame:CGRectZero];
    self.art.contentMode = UIViewContentModeScaleAspectFill;
    self.art.clipsToBounds = YES;
    self.art.maxPixels = 1024;
    self.art.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.artContainer addSubview:self.art];

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
    self.elapsedLabel.textAlignment = UITextAlignmentLeft;
    self.remainingLabel = [self label:[UIFont fontWithName:@"HelveticaNeue" size:12] ?: [UIFont systemFontOfSize:12] color:[theme secondaryTextColor]];
    self.remainingLabel.textAlignment = UITextAlignmentRight;
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
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyThemeMode) name:TNSettingsDidChangeNotification object:nil];
    [self applyThemeMode];
    [self update];
}

- (void)applyThemeMode
{
    BOOL classic = [TNSettings classicPlayer];
    TNTheme *theme = [TNTheme shared];
    if (classic) {
        self.view.backgroundColor = [theme backgroundColor];
        self.backdrop.hidden = YES;
        self.dim.hidden = YES;
        self.topBar.hidden = NO;
        self.bottomDock.hidden = NO;

        self.artContainer.layer.shadowColor = [UIColor blackColor].CGColor;
        self.artContainer.layer.shadowOffset = CGSizeMake(0, 4);
        self.artContainer.layer.shadowOpacity = 0.75f;
        self.artContainer.layer.shadowRadius = 8.0f;
        self.artContainer.layer.borderWidth = 1.0f;
        self.artContainer.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;

        [self.closeButton setImage:nil forState:UIControlStateNormal];
        [self.closeButton setBackgroundImage:[theme darkButtonImageHighlighted:NO] forState:UIControlStateNormal];
        [self.closeButton setBackgroundImage:[theme darkButtonImageHighlighted:YES] forState:UIControlStateHighlighted];
        [self.closeButton setTitle:L(@"Done") forState:UIControlStateNormal];
        [self.closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.closeButton.titleLabel.font = [theme boldBodyFont];
        self.closeButton.titleLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.75];
        self.closeButton.titleLabel.shadowOffset = CGSizeMake(0, -1);

        [self.moreButton setBackgroundImage:[theme darkButtonImageHighlighted:NO] forState:UIControlStateNormal];
        [self.moreButton setBackgroundImage:[theme darkButtonImageHighlighted:YES] forState:UIControlStateHighlighted];
        [self.sleepButton setBackgroundImage:[theme darkButtonImageHighlighted:NO] forState:UIControlStateNormal];
        [self.sleepButton setBackgroundImage:[theme darkButtonImageHighlighted:YES] forState:UIControlStateHighlighted];

        self.contextLabel.font = [theme boldBodyFont];
        self.contextLabel.textColor = [UIColor whiteColor];
        self.contextLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.75];
        self.contextLabel.shadowOffset = CGSizeMake(0, -1);
        self.contextLabel.numberOfLines = 1;

        self.titleLabel.shadowOffset = CGSizeMake(0, -1);
    } else {
        self.view.backgroundColor = [theme plainBackgroundColor];
        self.backdrop.hidden = NO;
        self.dim.hidden = NO;
        self.topBar.hidden = YES;
        self.bottomDock.hidden = YES;

        self.artContainer.layer.shadowOpacity = 0;
        self.artContainer.layer.borderWidth = 0;

        [self.closeButton setTitle:nil forState:UIControlStateNormal];
        [self.closeButton setBackgroundImage:nil forState:UIControlStateNormal];
        [self.closeButton setBackgroundImage:nil forState:UIControlStateHighlighted];
        [self.closeButton setImage:[theme icon:TNIconChevronDown size:24] forState:UIControlStateNormal];

        [self.moreButton setBackgroundImage:nil forState:UIControlStateNormal];
        [self.moreButton setBackgroundImage:nil forState:UIControlStateHighlighted];
        [self.sleepButton setBackgroundImage:nil forState:UIControlStateNormal];
        [self.sleepButton setBackgroundImage:nil forState:UIControlStateHighlighted];

        self.contextLabel.font = [theme sectionFont];
        self.contextLabel.textColor = [theme secondaryTextColor];
        self.contextLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.7];
        self.contextLabel.shadowOffset = CGSizeMake(0, 1);
        self.contextLabel.numberOfLines = 2;

        self.titleLabel.shadowOffset = CGSizeMake(0, 1);
    }
    if (self.isViewLoaded) {
        [self.view setNeedsLayout];
    }
}

- (void)libraryChanged
{
    self.shownURI = nil;
    [self update];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self applyThemeMode];
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

    if ([TNSettings classicPlayer]) {
        [self layoutClassicInSize:s top:top landscape:landscape];
    } else {
        [self layoutModernInSize:s top:top landscape:landscape];
    }
}

- (void)layoutModernInSize:(CGSize)s top:(CGFloat)top landscape:(BOOL)landscape
{
    self.topBar.hidden = YES;
    self.bottomDock.hidden = YES;
    self.closeButton.frame = CGRectMake(8, top + 4, 44, 44);
    self.moreButton.frame = CGRectMake(s.width - 52, top + 4, 44, 44);
    self.sleepButton.frame = CGRectMake(s.width - 96, top + 4, 44, 44);
    self.contextLabel.frame = CGRectMake(104, top + 6, s.width - 208, 36);
    CGFloat controlsH = TNIsPad() ? 250 : 210;
    if (landscape && TNIsPad()) {
        // the cover (or lyrics/queue) on the left, everything else on the right
        CGFloat side = MIN(s.height - 120, s.width / 2 - 40);
        CGRect panel = CGRectMake(40, (s.height - side) / 2 + 10, side, side);
        self.artContainer.frame = panel;
        self.lyrics.view.frame = panel;
        self.queue.view.frame = panel;
        CGFloat x = 40 + side + 40, w = s.width - x - 40;
        [self layoutControlsInRect:CGRectMake(x, (s.height - controlsH) / 2, w, controlsH)];
    } else {
        CGFloat side = MIN(s.width - (TNIsPad() ? 140 : 40), s.height - controlsH - 110);
        CGRect panel = CGRectMake((s.width - side) / 2, top + 60, side, side);
        self.artContainer.frame = panel;
        self.lyrics.view.frame = CGRectMake(20, top + 50, s.width - 40, side + 20);
        self.queue.view.frame = CGRectMake(0, top + 50, s.width, side + 20);
        CGFloat w = MIN(s.width - 40, 560);
        [self layoutControlsInRect:CGRectMake((s.width - w) / 2, CGRectGetMaxY(panel) + 18, w, controlsH)];
    }
}

- (void)layoutClassicInSize:(CGSize)s top:(CGFloat)top landscape:(BOOL)landscape
{
    self.topBar.hidden = NO;
    self.bottomDock.hidden = NO;
    CGFloat bottom = TNSafeAreaInsets(self.view).bottom;
    CGFloat barH = 44.0f;
    self.topBar.frame = CGRectMake(0, 0, s.width, top + barH);

    CGFloat doneW = MAX(56.0f, [self.closeButton.titleLabel.text sizeWithFont:[[TNTheme shared] boldBodyFont]].width + 20.0f);
    self.closeButton.frame = CGRectMake(8, top + 7, doneW, 30);
    self.moreButton.frame = CGRectMake(s.width - 40, top + 7, 32, 30);
    self.sleepButton.frame = CGRectMake(s.width - 78, top + 7, 32, 30);
    CGFloat titleLeft = CGRectGetMaxX(self.closeButton.frame) + 8;
    CGFloat titleRight = self.sleepButton.frame.origin.x - 8;
    self.contextLabel.frame = CGRectMake(titleLeft, top + 7, MAX(0, titleRight - titleLeft), 30);

    if (landscape && TNIsPad()) {
        CGFloat availY = top + barH;
        CGFloat availH = s.height - availY - bottom;
        CGFloat side = MIN(availH - 40, s.width / 2 - 60);
        CGRect panel = CGRectMake(50, availY + (availH - side) / 2, side, side);
        self.artContainer.frame = panel;
        self.lyrics.view.frame = panel;
        self.queue.view.frame = panel;

        CGFloat rx = 50 + side + 40;
        CGFloat rw = s.width - rx - 50;
        CGFloat rightCenterY = availY + availH / 2;
        CGFloat infoY = rightCenterY - 130;
        self.titleLabel.frame = CGRectMake(rx + 36, infoY, rw - 72, 28);
        self.heartButton.frame = CGRectMake(rx + rw - 36, infoY - 6, 36, 36);
        self.artistButton.frame = CGRectMake(rx + 36, infoY + 28, rw - 72, 22);

        self.progress.frame = CGRectMake(rx, infoY + 58, rw, 22);
        self.elapsedLabel.frame = CGRectMake(rx, infoY + 80, 60, 16);
        self.remainingLabel.frame = CGRectMake(rx + rw - 60, infoY + 80, 60, 16);
        self.formatLabel.frame = CGRectMake(rx + 60, infoY + 80, rw - 120, 16);

        CGFloat dockY = infoY + 104;
        CGFloat dockH = 114;
        self.bottomDock.frame = CGRectMake(rx, dockY, rw, dockH);
        self.bottomDock.layer.cornerRadius = 6;
        self.bottomDock.clipsToBounds = YES;

        CGFloat cx = rx + rw / 2;
        self.playButton.frame = CGRectMake(cx - 30, dockY + 6, 60, 48);
        self.spinner.center = self.playButton.center;
        self.previousButton.frame = CGRectMake(cx - 96, dockY + 10, 48, 40);
        self.nextButton.frame = CGRectMake(cx + 48, dockY + 10, 48, 40);
        self.shuffleButton.frame = CGRectMake(rx + 10, dockY + 12, 36, 36);
        self.repeatButton.frame = CGRectMake(rx + rw - 46, dockY + 12, 36, 36);

        CGFloat r2Y = dockY + 60;
        self.lyricsButton.frame = CGRectMake(rx + 10, r2Y - 2, 36, 36);
        self.queueButton.frame = CGRectMake(rx + rw - 46, r2Y - 2, 36, 36);
        self.volume.frame = CGRectMake(rx + 56, r2Y + 4, rw - 112, 22);
    } else {
        self.bottomDock.layer.cornerRadius = 0;
        self.bottomDock.clipsToBounds = NO;
        CGFloat dockContentH = (s.height < 500) ? 94.0f : 106.0f;
        CGFloat dockH = dockContentH + bottom;
        self.bottomDock.frame = CGRectMake(0, s.height - dockH, s.width, dockH);

        CGFloat startY = top + barH;
        CGFloat availableH = (s.height - dockH) - startY;
        CGFloat infoH = (s.height < 500) ? 72.0f : 86.0f;
        CGFloat maxSideH = availableH - infoH - ((s.height < 500) ? 14.0f : 24.0f);
        CGFloat side = MIN(s.width - (TNIsPad() ? 140 : 40), maxSideH);
        if (side < 120) side = 120;
        CGFloat panelY = startY + (availableH - infoH - side) / 2;
        if (panelY < startY + 6) panelY = startY + 6;

        self.artContainer.frame = CGRectMake((s.width - side) / 2, panelY, side, side);
        self.lyrics.view.frame = CGRectMake(20, panelY - 4, s.width - 40, side + 8);
        self.queue.view.frame = CGRectMake(0, panelY - 4, s.width, side + 8);

        CGFloat infoY = CGRectGetMaxY(self.artContainer.frame) + ((s.height < 500) ? 6.0f : 12.0f);
        CGFloat infoW = MIN(s.width - 32, 540);
        CGFloat infoX = (s.width - infoW) / 2;

        CGFloat titleH = (s.height < 500) ? 22.0f : 26.0f;
        CGFloat artistH = (s.height < 500) ? 18.0f : 20.0f;
        self.titleLabel.frame = CGRectMake(infoX + 36, infoY, infoW - 72, titleH);
        self.heartButton.frame = CGRectMake(infoX + infoW - 36, infoY - 4, 36, 36);
        self.artistButton.frame = CGRectMake(infoX + 36, infoY + titleH, infoW - 72, artistH);

        CGFloat progY = infoY + titleH + artistH + ((s.height < 500) ? 2.0f : 6.0f);
        self.progress.frame = CGRectMake(infoX, progY, infoW, 20);
        self.elapsedLabel.frame = CGRectMake(infoX, progY + 18, 56, 14);
        self.remainingLabel.frame = CGRectMake(infoX + infoW - 56, progY + 18, 56, 14);
        self.formatLabel.frame = CGRectMake(infoX + 56, progY + 18, infoW - 112, 14);

        CGFloat dockY = self.bottomDock.frame.origin.y;
        CGFloat dockW = MIN(s.width - 20, 540);
        CGFloat dockX = (s.width - dockW) / 2;
        CGFloat cx = s.width / 2;

        CGFloat btnY = dockY + ((s.height < 500) ? 4.0f : 8.0f);
        CGFloat playBtnH = (s.height < 500) ? 44.0f : 50.0f;
        self.playButton.frame = CGRectMake(cx - 30, btnY, 60, playBtnH);
        self.spinner.center = self.playButton.center;
        self.previousButton.frame = CGRectMake(cx - 96, btnY + 2, 48, 40);
        self.nextButton.frame = CGRectMake(cx + 48, btnY + 2, 48, 40);
        self.shuffleButton.frame = CGRectMake(dockX + 6, btnY + 4, 36, 36);
        self.repeatButton.frame = CGRectMake(dockX + dockW - 42, btnY + 4, 36, 36);

        CGFloat r2Y = btnY + playBtnH + ((s.height < 500) ? 2.0f : 6.0f);
        self.lyricsButton.frame = CGRectMake(dockX + 6, r2Y - 2, 36, 36);
        self.queueButton.frame = CGRectMake(dockX + dockW - 42, r2Y - 2, 36, 36);
        self.volume.frame = CGRectMake(dockX + 50, r2Y + 4, dockW - 100, 22);
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
    self.artContainer.hidden = self.panel != TNNowPlayingArt;
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
    if ([TNSettings classicPlayer]) {
        self.contextLabel.text = context.length ? context : L(@"Now playing");
    } else {
        self.contextLabel.text = context.length ? [NSString stringWithFormat:@"%@\n%@", [L(@"Playing from") uppercaseString], context] : @"";
    }
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
